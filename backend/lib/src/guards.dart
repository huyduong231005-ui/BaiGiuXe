// Bảo vệ (PIN băm bcrypt), ca trực, bảng công.
import 'auth.dart' show checkPassword, hashPassword;
import 'db.dart';
import 'http.dart';
import 'rules.dart';

final _pinRe = RegExp(r'^\d{4,8}$');
final _timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final _monthRe = RegExp(r'^\d{4}-\d{2}$');
const _maxFingerId = 300;

const inUse = 'Dữ liệu đang được dùng ở nơi khác (đã có lịch sử), không xoá được';

/// "2026-10" -> [đầu tháng, đầu tháng sau) giờ địa phương; mặc định tháng hiện tại.
({String month, DateTime from, DateTime to}) monthRange(Object? month) {
  final now = DateTime.now();
  final m = str(month).isNotEmpty ? str(month) : '${now.year}-${now.month.toString().padLeft(2, '0')}';
  if (!_monthRe.hasMatch(m)) throw HttpError(400, 'Tháng dạng YYYY-MM');
  final [y, mo] = m.split('-').map(int.parse).toList();
  return (month: m, from: DateTime(y, mo), to: DateTime(y, mo + 1));
}

/// Lượt chấm công trong [from, to) kèm guard_name, mới nhất trước (sort = -1) hoặc cũ nhất trước (1).
Future<List<Map<String, dynamic>>> attendanceRows(DateTime from, DateTime to, [Object? guardId, int sort = -1]) async {
  final list = await Attendance.find({
    'time_in': {r'$gte': from, r'$lt': to},
    'guard_id': ?guardId,
  }, {'time_in': sort});
  final names = await guardNames(list.map((a) => a['guard_id']));
  return [
    for (final a in list)
      if (names.containsKey(a['guard_id'])) {...row(a)!, 'guard_name': names[a['guard_id']]}
  ];
}

/// id bảo vệ -> tên (bỏ qua id null).
Future<Map<Object, String>> guardNames(Iterable<Object?> ids) async {
  final wanted = {...ids.whereType<Object>()}.toList();
  final guards = wanted.isEmpty ? <Doc>[] : await Guard.find({'_id': {r'$in': wanted}}, null, {'name': 1});
  return {for (final g in guards) g['_id']: g['name'] as String};
}

/// Bảng công một tháng; truyền guardId để chỉ lấy của một bảo vệ.
Future<Map<String, dynamic>> _attendanceReport(Object? month, [Object? guardId]) async {
  final range = monthRange(month);
  final rows = await attendanceRows(range.from, range.to, guardId);
  return {
    'month': range.month,
    'summary': summarize(rows),
    'records': [for (final r in rows) {...r, ...attStat(r)}],
  };
}

Future<Map<String, dynamic>> meAttendance(Req req) async {
  if (!truthy(req.user['guard_id'])) throw HttpError(404, 'Tài khoản chưa được gắn với hồ sơ bảo vệ');
  return _attendanceReport(req.query['month'], req.user['guard_id']);
}

/// Bảo vệ theo id vân tay trên AS608 hoặc PIN; null nếu không khớp.
Future<Map<String, dynamic>?> findGuard(Object? pin, Object? finger) async {
  if (asInt(finger) != null) return row(await Guard.findOne({'finger_id': asInt(finger)}));
  if (pin is! String || pin.isEmpty) return null;
  // shortcut: so bcrypt lần lượt từng bảo vệ, đủ nhanh với vài chục người; khoá sai PIN nằm ở ESP32.
  for (final g in await Guard.find({'pin_hash': {r'$type': 'string'}})) {
    if (await checkPassword(pin, g['pin_hash'])) return row(g);
  }
  return null;
}

({String name, String pin, int? finger}) _guardInput(Req req, bool isNew) {
  final name = str(req.b('name'));
  final pin = req.b('pin') is String ? req.b('pin') as String : '';
  if (isNew && name.isEmpty) throw HttpError(400, 'Cần nhập tên bảo vệ');
  // Không có PIN thì không mở cổng bằng phím A và không đăng ký vân tay được (phím B cần PIN).
  if ((isNew || pin.isNotEmpty) && !_pinRe.hasMatch(pin)) throw HttpError(400, 'PIN phải gồm 4-8 chữ số');
  final finger = req.b('fingerId');
  final f = asInt(finger);
  if (finger != null && !(f != null && f >= 1 && f <= _maxFingerId)) {
    throw HttpError(400, 'ID vân tay là số 1-$_maxFingerId');
  }
  return (name: name, pin: pin, finger: f);
}

Map<String, dynamic> _publicGuard(Map<String, dynamic> g) =>
    {...g, 'has_pin': g['pin_hash'] != null && g['pin_hash'] != ''}..remove('pin_hash');

void guardRoutes(Router router) {
  router.get('/guards', (_) async {
    final (guards, onDuty) = await (Guard.find({}, {'_id': 1}), Attendance.find({'on_duty': true})).wait;
    final duty = {for (final a in onDuty) a['guard_id']: a};
    return json([
      for (final g in guards)
        _publicGuard({
          ...row(g)!, 'on_duty_shift': duty[g['_id']]?['shift_name'], 'on_duty_since': duty[g['_id']]?['time_in'],
        })
    ]);
  });

  router.post('/guards', (req) async {
    final input = _guardInput(req, true);
    final guard = await Guard.insert(
        {'name': input.name, 'finger_id': input.finger, 'pin_hash': await hashPassword(input.pin)});
    return json(_publicGuard(guard), 201);
  });

  router.patch('/guards/:id', (req) async {
    final input = _guardInput(req, false);
    final changes = {
      if (input.name.isNotEmpty) 'name': input.name,
      if (req.has('fingerId')) 'finger_id': input.finger,
      if (input.pin.isNotEmpty) 'pin_hash': await hashPassword(input.pin),
    };
    final guard = row(await Guard.findByIdAndUpdate(pathId(req.params['id']!), changes));
    if (guard == null) throw HttpError(404, 'Không có bảo vệ này');
    return json(_publicGuard(guard));
  });

  // Còn lịch sử (lượt mở tay, chấm công, nhật ký cổng) thì không xoá được, như khoá ngoại cũ.
  router.delete('/guards/:id', (req) async {
    final id = pathId(req.params['id']!);
    if (!(await Guard.exists({'_id': id}))) throw HttpError(404, 'Không có bảo vệ này');
    final used = await [
      Session.exists({'override_by': id}), Attendance.exists({'guard_id': id}), GateEvent.exists({'guard_id': id}),
    ].wait;
    if (used.any((u) => u)) throw HttpError(409, inUse);
    await Guard.deleteOne({'_id': id});
    await User.updateMany({'guard_id': id}, {'guard_id': null});
    return noContent();
  });

  // Ca trực: end_time <= start_time là ca qua đêm. Giờ lưu dạng HH:MM:SS như cột time của Postgres trước đây.
  router.get('/shifts', (_) async => json([for (final s in await ShiftDef.find({}, {'start_time': 1})) row(s)]));

  Map<String, dynamic> shiftInput(Req req) {
    final (name, start, end) = (str(req.b('name')), str(req.b('startTime')), str(req.b('endTime')));
    if (name.isEmpty) throw HttpError(400, 'Cần nhập tên ca');
    if (!_timeRe.hasMatch(start) || !_timeRe.hasMatch(end)) throw HttpError(400, 'Giờ bắt đầu / kết thúc dạng HH:MM');
    return {'name': name, 'start_time': '$start:00', 'end_time': '$end:00'};
  }

  router.post('/shifts', (req) async => json(await ShiftDef.insert(shiftInput(req)), 201));

  router.put('/shifts/:id', (req) async {
    final shift = row(await ShiftDef.findByIdAndUpdate(pathId(req.params['id']!), shiftInput(req)));
    if (shift == null) throw HttpError(404, 'Không có ca này');
    return json(shift);
  });

  router.delete('/shifts/:id', (req) async {
    // Bảng công cũ vẫn giữ tên ca đã chép (shift_name), shift_id về null.
    final id = pathId(req.params['id']!);
    if (await ShiftDef.deleteOne({'_id': id}) == 0) throw HttpError(404, 'Không có ca này');
    await Attendance.updateMany({'shift_id': id}, {'shift_id': null});
    return noContent();
  });

  router.get('/attendance', (req) async => json(await _attendanceReport(req.query['month'])));
}
