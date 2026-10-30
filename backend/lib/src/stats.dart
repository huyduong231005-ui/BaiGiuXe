// Thống kê: doanh thu theo ngày / tháng (vé lượt + vé tháng, theo loại xe) và tốc độ / độ chính xác nhận diện biển.
import 'db.dart';
import 'http.dart';
import 'lot.dart';
import 'parking.dart';
import 'rules.dart';

const _maxDays = 366;
const _maxMonths = 36;
const _defaultDays = 30;
const _defaultMonths = 12;
const _ocrDays = 30;
final _monthRe = RegExp(r'^\d{4}-\d{2}$');

String _ym(DateTime d) => ymd(d).substring(0, 7);

/// Khoảng thời gian + danh sách kỳ (ngày hoặc tháng) để biểu đồ không bị thủng ở kỳ không có tiền.
({DateTime start, DateTime end, List<String> keys, String Function(DateTime) key}) _periods(
    String group, String fromQ, String toQ) {
  final keys = <String>[];
  if (group == 'month') {
    final now = DateTime.now();
    final to = toQ.isNotEmpty ? toQ : _ym(now);
    final from = fromQ.isNotEmpty ? fromQ : _ym(DateTime(now.year, now.month - _defaultMonths + 1));
    if (!_monthRe.hasMatch(from) || !_monthRe.hasMatch(to)) throw HttpError(400, 'Tháng dạng YYYY-MM');
    final [fy, fm] = from.split('-').map(int.parse).toList();
    final [ty, tm] = to.split('-').map(int.parse).toList();
    final start = DateTime(fy, fm), end = DateTime(ty, tm + 1);
    for (var d = start; d.isBefore(end) && keys.length <= _maxMonths; d = DateTime(d.year, d.month + 1)) {
      keys.add(_ym(d));
    }
    if (keys.isEmpty || keys.length > _maxMonths) throw HttpError(400, 'Khoảng tháng không hợp lệ (tối đa $_maxMonths)');
    return (start: start, end: end, keys: keys, key: _ym);
  }
  final (_, end) = dayRange(toQ.isNotEmpty ? toQ : today());
  var (start, _) = dayRange(fromQ.isNotEmpty ? fromQ : today());
  if (fromQ.isEmpty) start = DateTime(start.year, start.month, start.day - _defaultDays + 1);
  for (var d = start; d.isBefore(end) && keys.length <= _maxDays; d = DateTime(d.year, d.month, d.day + 1)) {
    keys.add(ymd(d));
  }
  if (keys.isEmpty || keys.length > _maxDays) throw HttpError(400, 'Khoảng ngày không hợp lệ (tối đa $_maxDays ngày)');
  return (start: start, end: end, keys: keys, key: ymd);
}

/// Doanh thu theo kỳ: vé lượt (phí lúc xe ra) + vé tháng (khoản thu khi duyệt đơn), kèm tổng theo loại xe.
Future<Map<String, dynamic>> revenue([String group = 'day', String from = '', String to = '']) async {
  final p = _periods(group, from, to);
  final (sessions, payments, types) = await (
    Session.find({'time_out': {r'$gte': p.start, r'$lt': p.end}}, null, {'time_out': 1, 'fee': 1, 'vehicle_type': 1}),
    Payment.find({'created_at': {r'$gte': p.start, r'$lt': p.end}}),
    vehicleTypes(),
  ).wait;
  final rows = {for (final k in p.keys) k: <String, dynamic>{'period': k, 'sessions': 0, 'visitor': 0, 'monthly': 0, 'total': 0}};
  final byType = <String, Map<String, dynamic>>{};
  Map<String, dynamic> typeRow(String code) => byType.putIfAbsent(code,
      () => {'vehicle_type': code, 'name': types[code]?['name'] ?? code, 'sessions': 0, 'visitor': 0, 'monthly': 0});
  for (final s in sessions) {
    final fee = (s['fee'] as num?) ?? 0;
    final r = rows[p.key(s['time_out'])]!;
    r['sessions'] += 1;
    r['visitor'] += fee;
    final t = typeRow(s['vehicle_type'] ?? 'motorbike');
    t['sessions'] += 1;
    t['visitor'] += fee;
  }
  for (final pay in payments) {
    rows[p.key(pay['created_at'])]!['monthly'] += pay['amount'] as num;
    typeRow(pay['vehicle_type'] ?? 'motorbike')['monthly'] += pay['amount'] as num;
  }
  final list = [for (final r in rows.values) {...r, 'total': r['visitor'] + r['monthly']}];
  num sum(String k) => list.fold<num>(0, (a, r) => a + r[k]);
  return {
    'group': group, 'total': sum('total'), 'visitor': sum('visitor'), 'monthly': sum('monthly'),
    'sessions': sum('sessions'), 'rows': list, 'byType': byType.values.toList(),
  };
}

int? _avg(List<num> xs) => xs.isEmpty ? null : (xs.fold<num>(0, (a, b) => a + b) / xs.length).round();
num? _pct(List<num> xs, int p) {
  if (xs.isEmpty) return null;
  final s = [...xs]..sort();
  final i = (p / 100 * s.length).ceil() - 1;
  return s[i < s.length - 1 ? i : s.length - 1];
}

num? _rate(int n, int d) => d == 0 ? null : (n / d * 1000).round() / 10; // phần trăm, 1 chữ số thập phân

/// Nhận diện biển trong N ngày gần nhất, từ nhật ký quẹt thẻ:
/// - Tốc độ: thời gian chụp + OCR, thời gian từ lúc quẹt tới lúc ESP32 có kết quả (trung bình, trung vị, p95).
/// - Độ chính xác: đọc được ngay lần chụp đầu, độ tin cậy trung bình, tỉ lệ biển lúc ra khớp biển lúc vào.
Future<Map<String, dynamic>> ocrStats([int days = _ocrDays]) async {
  final since = DateTime.now().subtract(Duration(days: days));
  final scans = await GateEvent.find({'kind': 'scan', 'created_at': {r'$gte': since}}, {'_id': -1});
  final measured = scans.where((e) => e['ocr_ms'] != null).toList();
  final read = scans.where((e) => truthy(e['plate'])).toList();
  final firstShot = measured
      .where((e) => e['shots'] == 1 && truthy(e['plate']) && e['score'] != null && e['score'] >= minPlateScore)
      .toList();
  final exits = scans.where((e) => e['gate'] == 'out' && truthy(e['plate']) && e['message'] != 'Khong co luot gui').toList();
  final mismatched = exits.where((e) => e['message'] == 'Sai bien so').length;
  List<num> ms(String k) => [for (final e in measured) if (e[k] != null) e[k] as num];
  final reasons = <String, int>{};
  for (final e in scans.where((e) => e['status'] == 'denied')) {
    reasons['${e['message']}'] = (reasons['${e['message']}'] ?? 0) + 1;
  }
  return {
    'days': days,
    'scans': scans.length,
    'readRate': _rate(read.length, scans.length),
    'firstShotRate': _rate(firstShot.length, measured.length),
    'avgScore': read.isEmpty
        ? null
        : (read.fold<num>(0, (a, e) => a + ((e['score'] as num?) ?? 0)) / read.length * 1000).round() / 1000,
    'ocrMs': {'avg': _avg(ms('ocr_ms')), 'p50': _pct(ms('ocr_ms'), 50), 'p95': _pct(ms('ocr_ms'), 95)},
    'totalMs': {'avg': _avg(ms('total_ms')), 'p50': _pct(ms('total_ms'), 50), 'p95': _pct(ms('total_ms'), 95)},
    'exits': exits.length,
    'exitMatchRate': _rate(exits.length - mismatched, exits.length),
    'reasons': sortedStable([for (final e in reasons.entries) {'message': e.key, 'count': e.value}],
        (a, b) => (b['count'] as int) - (a['count'] as int)),
    'recent': [
      for (final e in measured.take(20))
        {'at': e['created_at'], 'gate': e['gate'], 'plate': e['plate'], 'score': e['score'], 'shots': e['shots'],
          'ocr_ms': e['ocr_ms'], 'total_ms': e['total_ms'], 'vehicle_type': e['vehicle_type'], 'message': e['message']}
    ],
  };
}

void statsRoutes(Router router) {
  router.get('/stats/revenue', (req) async {
    final group = str(req.query['group']).isEmpty ? 'day' : str(req.query['group']);
    if (group != 'day' && group != 'month') throw HttpError(400, 'group là day hoặc month');
    return json(await revenue(group, str(req.query['from']), str(req.query['to'])));
  });
  router.get('/stats/ocr', (req) async =>
      json(await ocrStats(numOr(req.query['days'], _ocrDays).clamp(1, 365).toInt())));
}
