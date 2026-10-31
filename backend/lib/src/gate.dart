// API cho điện thoại camera ở cổng (đăng nhập tài khoản quản lý). ĐT camera chỉ nhận sự kiện ESP32, chụp + đọc
// biển rồi gọi API; mọi kiểm tra và ghi dữ liệu (lượt gửi, nhật ký, chấm công) nằm ở đây. Kết quả trả về có sẵn
// 2 dòng chữ cho OLED (ASCII không dấu, tối đa 21 ký tự) để ĐT gửi thẳng cho ESP32.
import 'package:mongo_dart/mongo_dart.dart' show BsonBinary;

import 'db.dart';
import 'guards.dart' show findGuard;
import 'http.dart';
import 'lot.dart';
import 'parking.dart';
import 'plates.dart' show imgPathRe;
import 'rules.dart';

const _maxImage = 2 * 1024 * 1024;
const _commandTtl = Duration(seconds: 30); // lệnh mở cổng cũ hơn 30 giây thì bỏ (ĐT cổng ra mất mạng lúc đó)

Future<Map<String, dynamic>> _log(Map<String, dynamic> data) =>
    GateEvent.insert({'gate': 'out', 'status': 'done', ...data});

int? _num(Object? v) => v is num && v.isFinite ? v.round() : null;

typedef _Read = ({String? plate, num score, List<String> candidates, String? img, String? vehicle});

_Read _plateRead(Object? body) {
  final b = body is Map ? body : const {};
  final plate = normPlate(b['plate']), img = str(b['img']), vehicle = str(b['vehicle']);
  return (
    plate: plate.isEmpty ? null : plate,
    score: b['score'] is num ? b['score'] as num : 0,
    candidates: b['candidates'] is List ? [for (final c in b['candidates']) normPlate(c)].where((c) => c.isNotEmpty).toList() : <String>[],
    img: imgPathRe.hasMatch(img) ? img : null,
    vehicle: vehicleFromOcr(vehicle) ?? (vehicle.isEmpty ? null : vehicle), // 'Motorcycle'/'Sedan'... hoặc code sẵn
  );
}

// Tên ngắn không dấu cho OLED khi hết chỗ
const _short = {'motorbike': 'xe may', 'car': 'o to', 'bicycle': 'xe dap'};

/// Xe vào: kiểm tra, chọn ô (cư dân về ô riêng; khách vãng lai vào ô trống gần cổng nhất, đúng loại xe), mở lượt gửi.
/// Trùng index (2 lượt quẹt cùng lúc) thì coi như xe đã trong bãi.
Future<Map<String, dynamic>> _enter(String uid, _Read read, DateTime now) async {
  final (card, open, status, parked) = await (
    Card.findOne({'uid': uid}),
    Session.exists({'card_uid': uid, 'parked': true}),
    parkingStatus(),
    Session.find({'parked': true, 'plate_in': {r'$type': 'string'}}, null, {'plate_in': 1}),
  ).wait;
  final d = decideEntry(card: card, hasOpenSession: open, free: status['free'], plate: read.plate, score: read.score,
      candidates: read.candidates, parkedPlates: [for (final s in parked) s['plate_in']], now: now);
  if (d['ok'] != true) return d;
  final types = await vehicleTypes();
  final String vehicleType = card!['kind'] == 'monthly' && truthy(card['vehicle_type'])
      ? card['vehicle_type']
      : types.containsKey(read.vehicle) ? read.vehicle! : 'motorbike'; // shortcut: OCR không nhận ra loại xe thì coi là xe máy
  final slot = await assignSlot(card, vehicleType);
  if (slot?['full'] == true) {
    return {'ok': false, 'open': false, 'message': 'Het cho ${_short[vehicleType] ?? vehicleType}', 'vehicleType': vehicleType};
  }
  try {
    await Session.insert({'card_uid': uid, 'plate_in': read.plate, 'img_in': read.img, 'time_in': now,
      'vehicle_type': vehicleType, 'slot_code': slot?['code']});
  } catch (err) {
    if (!isDuplicateKey(err)) rethrow;
    return {'ok': false, 'open': false, 'message': 'Xe da o trong bai'};
  }
  if (slot == null) return {...d, 'vehicleType': vehicleType};
  // Đường từ cổng vào tới ô: ĐT cổng vẽ cho khách xem, lời chỉ dẫn hiện trên màn hình.
  return {...d, 'message': 'Moi vao o ${slot['code']}', 'slot': slot['code'], 'vehicleType': vehicleType,
    'route': await slotRoute(slot['code'])};
}

/// Xe ra: biển ra phải khớp biển lúc vào, đóng lượt kèm phí.
Future<Map<String, dynamic>> _leave(String uid, _Read read, DateTime now) async {
  final (card, session) =
      await (Card.findOne({'uid': uid}), Session.findOne({'card_uid': uid, 'parked': true})).wait;
  final settings = session != null ? await sessionPrice(session) : null;
  final d = decideExit(card: card, session: session, plate: read.plate, candidates: read.candidates, now: now,
      settings: settings);
  if (d['ok'] != true) return d;
  final closed = await closeSession(session!['_id'], {'plate_out': read.plate, 'img_out': read.img, 'fee': d['fee']});
  return closed != null
      ? {...d, 'slot': session['slot_code'], 'vehicleType': session['vehicle_type']}
      : {'ok': false, 'open': false, 'message': 'Luot gui da dong'};
}

final _tokRe = RegExp(r'^[0-9A-F]{32}$');

/// Mã xoay vòng chống sao chép thẻ: mỗi lần quẹt, ESP32 đọc mã cũ trong thẻ (sector 1) rồi ghi mã ngẫu nhiên mới,
/// gửi cả hai. Mã cũ phải khớp mã API đang lưu; lệch = thẻ thật và thẻ chép đã dùng chéo nhau -> khoá thẻ, quản lý
/// kiểm tra rồi bật lại (thẻ nhận mã mới ở lần quẹt sau). Thẻ chưa có mã (mới cấp / vừa bật lại) thì nhận mã đầu.
/// Trả lý do từ chối, hoặc null nếu cho qua / không kiểm tra (thẻ không ghi được, quẹt thử, thẻ lạ).
/// ponytail: lượt quẹt mà ĐT không gửi được lên API sau khi ESP32 đã ghi mã mới làm thẻ thật bị báo nhầm; hiếm,
/// quản lý bật lại thẻ là xong. Muốn hết hẳn thì đưa tok/ntok vào hàng chờ offline.
Future<Map<String, dynamic>?> checkRollingToken(String uid, Object? tokRaw, Object? ntokRaw) async {
  final tok = str(tokRaw).toUpperCase(), ntok = str(ntokRaw).toUpperCase();
  if (!_tokRe.hasMatch(ntok)) return null;
  final card = await Card.findOne({'uid': uid});
  if (card == null) return null;
  if (card['tok'] != null && card['tok'] != tok) {
    await Card.updateOne({'uid': uid}, {'active': false, 'tok': null, 'clone_at': DateTime.now()});
    return {'ok': false, 'open': false, 'message': 'The nghi sao chep'};
  }
  await Card.updateOne({'uid': uid}, {'tok': ntok});
  return null;
}

const _maxOfflineEvents = 500;
const _maxWhitelist = 300; // ESP32 lưu trong flash (NVS), ~30 byte mỗi thẻ

/// Giờ ESP32 (DS3231 chạy giờ địa phương, gửi dạng epoch "giả UTC") -> DateTime thật.
DateTime? _fromEspTime(Object? raw) {
  final ts = raw is num ? raw : num.tryParse('$raw');
  if (ts == null || !ts.isFinite || ts.abs() > 8e12) return null;
  return DateTime.fromMillisecondsSinceEpoch(((ts - DateTime.now().timeZoneOffset.inSeconds) * 1000).round());
}

/// Một lượt ghi bù từ ESP32 lúc mất mạng: mở / đóng lượt gửi của thẻ tháng, ghi nhật ký. Trả true nếu ghi mới.
Future<bool> _applyOffline(Object? raw) async {
  if (raw is! Map) return false;
  final ev = raw;
  final at = _fromEspTime(ev['ts']);
  if (at == null || at.isAfter(DateTime.now().add(const Duration(minutes: 1)))) return false;
  final uid = str(ev['uid']).isEmpty ? null : str(ev['uid']).toUpperCase();
  final key = '${ev['t']}:${uid ?? ev['by'] ?? '-'}:${ev['ts']}';
  if (await GateEvent.exists({'offline_key': key})) return false;
  final gate = ev['t'] == 'in' ? 'in' : 'out';
  var message = 'Offline: ';
  if (uid != null) {
    final card = await Card.findOne({'uid': uid});
    final open = await Session.findOne({'card_uid': uid, 'parked': true});
    if (ev['t'] == 'in' && card != null && open == null) {
      final slot = await Slot.findOne({'card_uid': uid});
      try {
        await Session.insert({'card_uid': uid, 'plate_in': card['plate'], 'time_in': at,
          'vehicle_type': card['vehicle_type'] ?? 'motorbike', 'slot_code': slot?['code'], 'offline': true});
      } catch (_) {
        // trùng biển đang gửi thì bỏ qua lượt mở
      }
      message += 'vao bang the thang $uid';
    } else if (ev['t'] == 'out' && open != null && !at.isBefore(open['time_in'])) {
      final fee = calcFee(open['time_in'], at, await sessionPrice(open), monthlyValid(card, at));
      await Session.updateOne({'_id': open['_id'], 'parked': true},
          {'time_out': at, 'fee': fee, 'plate_out': card?['plate'], 'parked': false, 'offline': true});
      message += 'ra bang the $uid, phi ${fee}d';
    } else {
      message += '${ev['t'] == 'in' ? 'vao' : 'ra'} the $uid (khong co luot de ghi)';
    }
  } else {
    message += ev['by'] == 'emg' ? 'mo bang nut khan cap' : 'bao ve mo bang van tay #${ev['guard'] ?? '?'}';
  }
  try {
    await GateEvent.insert({'gate': gate, 'kind': uid != null ? 'scan' : ev['by'] == 'emg' ? 'emergency' : 'override',
      'uid': uid, 'status': 'done', 'message': message, 'open': gate == 'out', 'guard_id': asInt(ev['guard']),
      'offline_key': key, 'created_at': at});
  } catch (err) {
    if (!isDuplicateKey(err)) rethrow;
  }
  return true;
}

void gateRoutes(Router router) {
  // Một lượt quẹt thẻ: {gate: in|out, uid, plate, score, candidates, img} -> quyết định + 2 dòng OLED + chỗ trống.
  // Màn Thêm thẻ nhận thẻ thẳng từ ESP32 (không qua /gate/scan) nhưng ESP32 vẫn đã ghi mã mới vào thẻ: lưu theo.
  router.post('/cards/:uid/token', (req) async {
    final d = await checkRollingToken(req.params['uid']!.toUpperCase(), req.b('tok'), req.b('ntok'));
    return json({'ok': d == null, 'message': d?['message']});
  });

  router.post('/gate/scan', (req) async {
    final gate = req.b('gate');
    if (gate != 'in' && gate != 'out') throw HttpError(400, 'gate là in hoặc out');
    final uid = str(req.b('uid')).toUpperCase();
    if (uid.isEmpty) throw HttpError(400, 'Thiếu UID thẻ');
    final read = _plateRead(req.body);
    final now = DateTime.now();
    final d = await checkRollingToken(uid, req.b('tok'), req.b('ntok')) ?? await (gate == 'in' ? _enter : _leave)(uid, read, now);
    await GateEvent.insert({'gate': gate, 'kind': 'scan', 'uid': uid, 'status': d['ok'] == true ? 'ok' : 'denied',
      'plate': read.plate, 'img': read.img, 'message': d['message'], 'open': d['open'], 'ocr_ms': _num(req.b('ocrMs')),
      'total_ms': _num(req.b('totalMs')), 'shots': _num(req.b('shots')), 'score': read.plate != null ? read.score : null,
      'vehicle_type': d['vehicleType'] ?? read.vehicle, 'slot_code': d['slot']});
    return json({...d, 'l1': read.plate ?? (d['ok'] == true ? 'OK' : 'TU CHOI'), 'l2': d['message'],
      'status': await parkingStatus()});
  });

  // Bảo vệ ở cổng ra: PIN (phím A) hoặc vân tay. enroll = phím B (PIN đúng thì ESP32 đăng ký vân tay vào ô = ID).
  // denied = lượt bị từ chối gần đây (ĐT giữ 60 giây): mở tay thì đóng lượt gửi đó, ghi tên bảo vệ.
  router.post('/gate/auth', (req) async {
    final (pin, finger, enroll, denied) = (req.b('pin'), req.b('finger'), req.b('enroll'), req.b('denied'));
    final guard = await findGuard(pin, finger);
    if (pin != null && guard == null) {
      await _log({'kind': 'override', 'status': 'denied', 'message': truthy(enroll) ? 'Sai PIN (dang ky van tay)' : 'Sai PIN'});
      return json({'ok': false, 'guardId': null, 'message': 'Sai PIN bao ve'});
    }
    if (truthy(enroll)) {
      return json({'ok': true, 'guardId': guard?['id'], 'message': 'Bao ve #${guard?['id']} dang ky van tay'});
    }
    var message = pin != null ? 'PIN bao ve #${guard!['id']}' : 'Van tay #$finger${guard != null ? '' : ' (chua gan bao ve)'}';
    final uid = str(denied is Map ? denied['uid'] : null).toUpperCase();
    final s = uid.isEmpty ? null : await Session.findOne({'card_uid': uid, 'parked': true});
    if (s != null) {
      final fee = await feeNow(s);
      final read = _plateRead(denied);
      if (await closeSession(s['_id'], {'plate_out': read.plate, 'img_out': read.img, 'fee': fee,
            'override_by': guard?['id']}) != null) {
        message += ' | the $uid | Phi: ${fee}d';
      }
    }
    await _log({'kind': 'override', 'guard_id': guard?['id'], 'message': message});
    return json({'ok': true, 'guardId': guard?['id'], 'message': message});
  });

  // ESP32 vừa lưu vân tay vào ô id (= ID bảo vệ): gán cho bảo vệ đó, gỡ khỏi bảo vệ khác đang giữ số này.
  router.post('/gate/enrolled', (req) async {
    final id = pathId('${req.b('id') ?? ''}');
    if (!(await Guard.exists({'_id': id}))) throw HttpError(404, 'Không có bảo vệ này');
    await Guard.updateMany({'finger_id': id, '_id': {r'$ne': id}}, {'finger_id': null});
    await Guard.updateOne({'_id': id}, {'finger_id': id});
    await _log({'kind': 'override', 'guard_id': id, 'message': 'Dang ky van tay #$id'});
    return json({'ok': true, 'message': 'Da dang ky van tay cho bao ve #$id'});
  });

  // Chấm công (phím C): chưa trong ca -> vào ca gần nhất theo lịch; đang trong ca -> ra ca.
  // Ca mở quá 16 giờ coi như quên chấm ra: đóng ở giờ hết ca (method_out = auto) rồi mở ca mới.
  router.post('/gate/punch', (req) async {
    final (pin, finger) = (req.b('pin'), req.b('finger'));
    final guard = await findGuard(pin, finger);
    if (guard == null) {
      if (pin != null) await _log({'kind': 'override', 'status': 'denied', 'message': 'Sai PIN (cham cong)'});
      return json({'ok': false, 'pinWrong': pin != null, 'l1': 'KHONG RO',
        'l2': pin != null ? 'Sai PIN' : 'Van tay #$finger chua gan'});
    }
    final now = DateTime.now();
    final method = pin != null ? 'pin' : 'finger';
    final name = oledName(guard['name']);
    final open = await Attendance.findOne({'guard_id': guard['id'], 'on_duty': true});
    String l1, l2, message;
    int minutes(DateTime a, DateTime b) => (a.difference(b).inMilliseconds / 60000).floor();
    if (open != null && now.difference(open['time_in']) < maxShift) {
      await Attendance.updateOne({'_id': open['_id']}, {'time_out': now, 'method_out': method, 'on_duty': false});
      final early = open['shift_end'] != null ? minutes(open['shift_end'], now) : 0;
      (l1, l2) = ('RA CA', '$name ${hm(now)}${early > 0 ? ' som ${early}p' : ''}');
      message = 'Ra ca: ${open['shift_name'] ?? '-'}${early > 0 ? ' (ve som ${early}p)' : ''}';
    } else {
      if (open != null) {
        await Attendance.updateOne({'_id': open['_id']},
            {'time_out': open['shift_end'] ?? open['time_in'], 'method_out': 'auto', 'on_duty': false});
      }
      final s = nearestShift(await ShiftDef.find(), now);
      await Attendance.insert({'guard_id': guard['id'], 'shift_id': s?.def['_id'], 'shift_name': s?.def['name'],
        'shift_start': s?.start, 'shift_end': s?.end, 'time_in': now, 'method_in': method});
      final late = s != null ? minutes(now, s.start) : 0;
      (l1, l2) = ('VAO CA', '$name ${hm(now)}${late > 0 ? ' tre ${late}p' : ''}');
      message = 'Vao ca: ${s?.def['name'] ?? '-'}${late > 0 ? ' (tre ${late}p)' : ''}';
    }
    await _log({'kind': 'override', 'guard_id': guard['id'], 'message': message});
    return json({'ok': true, 'l1': l1, 'l2': l2, 'message': '${guard['name']} | $message'});
  });

  router.post('/gate/emergency', (req) async =>
      json(await _log({'kind': 'emergency', 'message': req.b('on') == true ? 'Bat khan cap' : 'Tat khan cap'}), 201));

  // Lệnh "Mở cổng ra" từ app quản lý: ĐT cổng ra hỏi định kỳ.
  router.get('/gate/commands', (_) async {
    final list = await GateEvent.find({
      'kind': 'open_cmd', 'status': 'pending', 'created_at': {r'$gt': DateTime.now().subtract(_commandTtl)},
    }, {'_id': 1});
    return json(list.map(row).toList());
  });

  router.post('/gate/commands/:id/done', (req) async {
    final e = await GateEvent.findOneAndUpdate(
        {'_id': pathId(req.params['id']!), 'kind': 'open_cmd'}, {'status': 'done'});
    if (e == null) throw HttpError(404, 'Không có lệnh này');
    return json(row(e));
  });

  // Thẻ tháng còn hiệu lực để ESP32 lưu sẵn: mất mạng / mất ĐT camera thì cư dân vẫn ra vào được.
  // d = hạn dùng YYYYMMDD (0 = không hạn), ESP32 tự so với giờ DS3231.
  router.get('/gate/whitelist', (_) async {
    final cards = await Card.find({
      'kind': 'monthly', 'active': true, 'lost_at': null,
      r'$or': [{'valid_until': null}, {'valid_until': {r'$gte': today()}}],
    }, {'uid': 1}, {'uid': 1, 'valid_until': 1}, _maxWhitelist);
    return json([
      for (final c in cards)
        {'u': c['uid'], 'd': truthy(c['valid_until']) ? int.parse((c['valid_until'] as String).replaceAll('-', '')) : 0}
    ]);
  });

  // ESP32 gửi bù các lượt ghi lúc mất mạng (qua ĐT camera khi có mạng lại). Gửi lại nhiều lần không bị ghi trùng.
  router.post('/gate/offline', (req) async {
    final raw = req.b('events');
    if (raw is! List) throw HttpError(400, 'Cần mảng events');
    final events = raw.take(_maxOfflineEvents).toList();
    num ts(Object? e) => e is Map && e['ts'] is num ? e['ts'] : 0;
    var applied = 0;
    for (final ev in sortedStable(events, (a, b) => ts(a).compareTo(ts(b)))) {
      if (await _applyOffline(ev)) applied++;
    }
    return json({'received': events.length, 'applied': applied});
  });

  // Ảnh lượt quẹt (đã thu nhỏ), tải lên sau khi cổng đã có kết quả.
  router.put('/gate/images', (req) async {
    final image = await req.image(_maxImage);
    final path = str(req.query['path']);
    if (!imgPathRe.hasMatch(path)) throw HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    if (image.isEmpty) throw HttpError(400, 'Gửi ảnh JPEG với Content-Type: image/jpeg');
    await PlateImage.updateOne({'path': path}, {'data': BsonBinary.from(image), 'created_at': DateTime.now()}, upsert: true);
    return noContent();
  });
}
