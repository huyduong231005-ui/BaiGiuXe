// Quy tắc nghiệp vụ thuần, cùng cách tính với app/lib/logic.dart để API và app tính giống nhau.
// Giờ địa phương lấy theo múi giờ của tiến trình (render.yaml đặt TZ=Asia/Ho_Chi_Minh).
import 'http.dart' show toDate;

String normPlate(Object? s) => (s ?? '').toString().toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

/// OCR hay nhầm đúng 1 ký tự nên cho lệch tối đa 1 (giống maxPlateDiff trong app).
const maxPlateDiff = 1;
const minPlateScore = 0.8;

int plateDistance(String a, String b) {
  var prev = List.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = [i];
    for (var j = 1; j <= b.length; j++) {
      final sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      final del = prev[j] + 1, ins = cur[j - 1] + 1;
      cur.add(sub < del ? (sub < ins ? sub : ins) : (del < ins ? del : ins));
    }
    prev = cur;
  }
  return prev[b.length];
}

bool samePlate(Object? a, Object? b) => plateDistance(normPlate(a), normPlate(b)) <= maxPlateDiff;

/// "22:00" hoặc "22:00:00" -> số phút từ 00:00.
int minutesOf(Object? hhmm) {
  final p = '$hhmm'.split(':').map(int.parse).toList();
  return p[0] * 60 + p[1];
}

/// Số lần mốc đêm (giờ địa phương) rơi vào khoảng [inT, outT).
int nightsCrossed(DateTime inT, DateTime outT, int markMinutes) {
  final a = inT.toLocal();
  var mark = DateTime(a.year, a.month, a.day, 0, markMinutes);
  if (mark.isBefore(inT)) mark = DateTime(mark.year, mark.month, mark.day + 1, 0, markMinutes);
  var n = 0;
  while (mark.isBefore(outT)) {
    n++;
    mark = DateTime(mark.year, mark.month, mark.day + 1, 0, markMinutes);
  }
  return n;
}

/// Phí: không qua mốc đêm thì 1 giá ngày, mỗi lần qua mốc đêm 1 giá đêm; vé tháng miễn phí.
/// settings: night_mark, price_day, price_night.
int calcFee(Object? inT, Object? outT, Map settings, [bool monthly = false]) {
  if (monthly) return 0;
  final n = nightsCrossed(toDate(inT)!, toDate(outT)!, minutesOf(settings['night_mark']));
  return (n == 0 ? settings['price_day'] as num : n * (settings['price_night'] as num)).toInt();
}

Map<String, dynamic> _deny(String message) => {'ok': false, 'open': false, 'message': message};

/// "2026-10-30" -> ngày kế tiếp 00:00 giờ địa phương (vé dùng tới hết ngày đó).
DateTime _endOfDay(Object ymd) {
  final s = '$ymd';
  final p = s.substring(0, s.length < 10 ? s.length : 10).split('-').map(int.parse).toList();
  return DateTime(p[0], p[1], p[2] + 1);
}

/// Vé tháng còn hạn tại thời điểm now (valid_until null = không giới hạn). Giống monthlyValid trong app.
bool monthlyValid(Map? card, [DateTime? now]) {
  if (card?['kind'] != 'monthly') return false;
  return card!['valid_until'] == null || (now ?? DateTime.now()).isBefore(_endOfDay(card['valid_until']));
}

String _pad(int n) => n.toString().padLeft(2, '0');

/// Ngày YYYY-MM-DD theo giờ địa phương.
String ymd(DateTime t) {
  final d = t.toLocal();
  return '${d.year}-${_pad(d.month)}-${_pad(d.day)}';
}

/// Hạn mới khi duyệt đơn vé tháng: vé còn hạn thì cộng nối tiếp từ hạn cũ, hết hạn / chưa có thì tính từ hôm nay.
/// VD hôm nay 30/10, mua 1 tháng -> dùng tới hết 29/11.
String extendUntil(String? currentUntil, int months, [DateTime? now]) {
  final n = (now ?? DateTime.now()).toLocal();
  final current = currentUntil == null || currentUntil.isEmpty ? null : currentUntil;
  final from = current != null && (current.length > 10 ? current.substring(0, 10) : current).compareTo(ymd(n)) >= 0
      ? _endOfDay(current)
      : DateTime(n.year, n.month, n.day);
  return ymd(DateTime(from.year, from.month + months, from.day - 1));
}

/// Quyết định cho xe vào (cùng thứ tự kiểm tra với decideEntry trong app).
Map<String, dynamic> decideEntry({
  required Map? card,
  required bool hasOpenSession,
  required num free,
  required Object? plate,
  num score = 1,
  List candidates = const [],
  List parkedPlates = const [],
  DateTime? now,
}) {
  if (card == null) return _deny('The chua dang ky');
  if (card['lost_at'] != null) return _deny('The da bao mat');
  if (card['active'] != true) return _deny('The bi khoa');
  if (card['kind'] == 'monthly' && !monthlyValid(card, now)) return _deny('Ve thang het han');
  if (hasOpenSession) return _deny('The dang gui xe');
  if (free <= 0) return _deny('Bai da day');
  if (normPlate(plate).isEmpty) return _deny('Khong doc duoc bien');
  if (score < minPlateScore) return _deny('Bien mo, quet lai');
  if (parkedPlates.any((p) => samePlate(p, plate))) return _deny('Xe da o trong bai');
  final matches = samePlate(card['plate'], plate) || candidates.any((c) => samePlate(card['plate'], c));
  if (card['kind'] == 'monthly' && !matches) return _deny('Sai xe ve thang');
  return {'ok': true, 'open': false, 'message': 'Moi vao'};
}

/// Quyết định cho xe ra: biển ra phải khớp biển lúc vào, kèm phí.
Map<String, dynamic> decideExit({
  required Map? card,
  required Map? session,
  required Object? plate,
  List candidates = const [],
  required DateTime now,
  required Map? settings,
}) {
  if (session == null) return _deny('Khong co luot gui');
  if (card?['lost_at'] != null) return _deny('The da bao mat');
  if (normPlate(plate).isEmpty) return _deny('Khong doc duoc bien');
  final plateIn = session['plate_in'];
  if (plateIn == null || plateIn == '') return _deny('Thieu bien luc vao');
  // Ra phải đúng y biển lúc vào (không cho lệch 1 ký tự như lúc vào / tra cứu): chặn xe biển gần giống lấy nhầm.
  // Một trong các cách đọc khác của OCR (candidates) khớp đúng từng ký tự thì vẫn cho ra.
  final want = normPlate(plateIn);
  final ok = normPlate(plate) == want || candidates.any((c) => normPlate(c) == want);
  if (!ok) return _deny('Sai bien so');
  final fee = calcFee(session['time_in'], now, settings!, monthlyValid(card, now));
  return {'ok': true, 'open': true, 'message': 'Phi: ${fee}d', 'fee': fee};
}

// ---------- Chấm công ----------

/// Thống kê một lượt chấm công (giống attStat trong app). Quên chấm ra không tính giờ làm, không tính về sớm.
Map<String, dynamic> attStat(Map r) {
  final inT = toDate(r['time_in']), outT = toDate(r['time_out']);
  final start = toDate(r['shift_start']), end = toDate(r['shift_end']);
  final missingOut = r['method_out'] == 'auto';
  final counted = outT != null && !missingOut;
  int pos(Duration d) => d.inMilliseconds > 0 ? d.inMilliseconds ~/ 60000 : 0;
  return {
    'lateMin': start != null && inT != null ? pos(inT.difference(start)) : 0,
    'earlyMin': counted && end != null ? pos(end.difference(outT)) : 0,
    'workedMin': counted && inT != null ? pos(outT.difference(inT)) : 0,
    'open': outT == null,
    'missingOut': missingOut,
  };
}

/// Gộp các lượt chấm công thành bảng công theo bảo vệ.
List<Map<String, dynamic>> summarize(List<Map> rows) {
  final by = <Object?, Map<String, dynamic>>{};
  for (final r in rows) {
    final s = attStat(r);
    final g = by.putIfAbsent(r['guard_id'], () => {
          'guardId': r['guard_id'], 'name': r['guard_name'], 'shifts': 0, 'workedMin': 0,
          'lateCount': 0, 'lateMin': 0, 'earlyCount': 0, 'earlyMin': 0, 'missingOut': 0,
        });
    g['shifts'] += 1;
    g['workedMin'] += s['workedMin'];
    if (s['lateMin'] != 0) {
      g['lateCount'] += 1;
      g['lateMin'] += s['lateMin'];
    }
    if (s['earlyMin'] != 0) {
      g['earlyCount'] += 1;
      g['earlyMin'] += s['earlyMin'];
    }
    if (s['missingOut'] == true) g['missingOut'] += 1;
  }
  return by.values.toList();
}

// ---------- Ca trực ----------

/// Quá lâu chưa chấm ra (quên) thì lần chấm sau tính là vào ca mới.
const maxShift = Duration(hours: 16);

/// Ca có giờ bắt đầu gần t nhất, xét cả hôm trước và hôm sau (vào sớm trước nửa đêm cho ca 00:00, hay chấm
/// ca đêm lúc 22:00). defs là các dòng shift_defs; null nếu chưa khai báo ca nào.
({Map def, DateTime start, DateTime end})? nearestShift(List<Map> defs, DateTime t) {
  ({Map def, DateTime start, DateTime end})? best;
  final lt = t.toLocal();
  for (final def in defs) {
    final s = minutesOf(def['start_time']), e = minutesOf(def['end_time']);
    final len = (e - s) % 1440 == 0 ? 1440 : (e - s) % 1440;
    for (final day in const [-1, 0, 1]) {
      final start = DateTime(lt.year, lt.month, lt.day + day, 0, s);
      if (best == null || t.difference(start).abs() < t.difference(best.start).abs()) {
        best = (def: def, start: start, end: start.add(Duration(minutes: len)));
      }
    }
  }
  return best;
}

String hm(DateTime t) {
  final d = t.toLocal();
  return '${_pad(d.hour)}:${_pad(d.minute)}';
}

const _accents = {
  'a': 'àáạảãâầấậẩẫăằắặẳẵ', 'e': 'èéẹẻẽêềếệểễ', 'i': 'ìíịỉĩ', 'o': 'òóọỏõôồốộổỗơờớợởỡ',
  'u': 'ùúụủũưừứựửữ', 'y': 'ỳýỵỷỹ', 'd': 'đ',
};
final _plain = {
  for (final MapEntry(:key, :value) in _accents.entries) ...{
    for (final ch in value.split('')) ch: key,
    for (final ch in value.toUpperCase().split('')) ch: key.toUpperCase(),
  },
};

/// Tên gọi ngắn không dấu cho OLED (font chỉ có ASCII): "Nguyễn Văn Tuấn" -> "Tuan".
String oledName(String full) =>
    full.trim().split(RegExp(r'\s+')).last.split('').map((ch) => _plain[ch] ?? ch).join()
        .replaceAll(RegExp('[̀-ͯ]'), ''); // dấu rời (chuỗi dạng NFD)
