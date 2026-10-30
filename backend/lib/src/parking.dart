// Bãi xe: số chỗ trống, lượt gửi, lịch sử + doanh thu, mở cổng, cho xe ra khi mất thẻ, thẻ, cài đặt.
import 'db.dart';
import 'deps.dart';
import 'guards.dart' show guardNames;
import 'http.dart';
import 'jwt.dart';
import 'lot.dart';
import 'rules.dart';

final dateRe = RegExp(r'^\d{4}-\d{2}-\d{2}$');
final _timeRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');
final uidRe = RegExp(r'^[0-9A-F]{8,20}$');
const _maxRows = 1000;

/// "2026-10-30" -> [00:00, 24:00) giờ địa phương.
(DateTime, DateTime) dayRange(String date) {
  if (!dateRe.hasMatch(date)) throw HttpError(400, 'Ngày dạng YYYY-MM-DD');
  final [y, m, d] = date.split('-').map(int.parse).toList();
  return (DateTime(y, m, d), DateTime(y, m, d + 1));
}

String today() => ymd(DateTime.now());

Future<Map<String, dynamic>> getSettings() async => row(await Settings.findById(1))!;

/// Sức chứa / đang gửi / còn trống. Đã vẽ sơ đồ thì sức chứa = số ô đang dùng, kèm chỗ trống theo loại xe.
Future<Map<String, dynamic>> parkingStatus() async {
  final (s, occupied, slots) =
      await (getSettings(), Session.count({'parked': true}), Slot.count({'active': true})).wait;
  final capacity = slots != 0 ? slots : (s['capacity'] as num).toInt();
  return {
    'capacity': capacity, 'occupied': occupied, 'free': capacity - occupied > 0 ? capacity - occupied : 0,
    if (slots != 0) 'byType': await freeByType(),
  };
}

/// Giá áp cho lượt gửi (theo loại xe của lượt).
Future<Map<String, dynamic>> sessionPrice(Map session) async =>
    priceOf(await getSettings(), await vehicleTypes(), session['vehicle_type']);

/// Doanh thu theo ngày ra (giờ địa phương) của các lượt ra trong [from, to).
Future<List<Map<String, dynamic>>> revenueByDay(DateTime from, DateTime to) async {
  final by = <String, Map<String, dynamic>>{};
  for (final s in await Session.find({'time_out': {r'$gte': from, r'$lt': to}}, null, {'time_out': 1, 'fee': 1})) {
    final day = ymd(s['time_out']);
    final r = by.putIfAbsent(day, () => {'day': day, 'sessions': 0, 'revenue': 0});
    r['sessions'] += 1;
    r['revenue'] += (s['fee'] as num?) ?? 0;
  }
  return by.values.toList()..sort((a, b) => (a['day'] as String).compareTo(b['day']));
}

const _cardCols = {'kind': 'card_kind', 'owner': 'card_owner', 'valid_until': 'card_valid_until', 'lost_at': 'card_lost_at'};

/// Gắn thông tin thẻ (card_kind, card_owner...) và tên bảo vệ mở tay (override_name) vào từng lượt gửi.
Future<List<Map<String, dynamic>>> withJoins(List<Doc> sessions,
    [List<String> cardCols = const ['kind', 'owner'], bool overrideName = true]) async {
  final (cards, names) = await (
    Card.find({'uid': {r'$in': {for (final s in sessions) s['card_uid']}.toList()}}),
    overrideName ? guardNames(sessions.map((s) => s['override_by'])) : Future.value(<Object, String>{}),
  ).wait;
  final byUid = {for (final c in cards) c['uid']: c};
  return [
    for (final s in sessions)
      {
        ...row(s)!,
        for (final k in cardCols) _cardCols[k]!: byUid[s['card_uid']]?[k],
        if (overrideName) 'override_name': names[s['override_by']],
      }
  ];
}

/// Phí nếu cho lượt gửi này ra vào thời điểm now.
Future<int> feeNow(Map session, [DateTime? now]) async {
  final at = now ?? DateTime.now();
  final card = await Card.findOne({'uid': session['card_uid']});
  return calcFee(session['time_in'], at, await sessionPrice(session), monthlyValid(card, at));
}

/// Thêm phí nếu cho ra bây giờ vào mỗi lượt đang gửi (rows có card_kind, card_valid_until).
Future<List<Map<String, dynamic>>> _withFee(List<Map<String, dynamic>> rows, String? plate) async {
  final (settings, types) = await (getSettings(), vehicleTypes()).wait;
  final now = DateTime.now();
  return [
    for (final s in rows)
      {
        ...s,
        'exact': plate == null || normPlate(s['plate_in']) == plate,
        'feeNow': calcFee(s['time_in'], now, priceOf(settings, types, s['vehicle_type']),
            monthlyValid({'kind': s['card_kind'], 'valid_until': s['card_valid_until']}, now)),
      }
  ];
}

/// Đóng lượt đang gửi (chỉ khi chưa ai đóng), trả về dòng mới hoặc null.
Future<Map<String, dynamic>?> closeSession(Object? id, Map<String, dynamic> changes) async => row(await Session
    .findOneAndUpdate({'_id': id, 'parked': true}, {...changes, 'time_out': DateTime.now(), 'parked': false}));

const ticketAudience = 'bgx-ticket';

Future<Map<String, dynamic>> _openGate(String message) =>
    GateEvent.insert({'gate': 'out', 'kind': 'open_cmd', 'message': message});

String _nightMark(Map s) => cut('${s['night_mark']}', 5);

/// Các API công khai: trang chủ hiển thị số chỗ trống, máy tính phí.
void publicRoutes(Router router) {
  router.get('/status', (_) async => json(await parkingStatus()));

  // Thông tin bãi cho khách: tên, địa chỉ, toạ độ (bản đồ, chỉ đường), bảng giá, chỗ trống.
  router.get('/lot', (_) async {
    final s = await getSettings();
    final prices = [
      for (final t in (await vehicleTypes()).values)
        {'code': t['code'], 'name': t['name'], 'priceDay': t['price_day'], 'priceNight': t['price_night'],
          'priceMonth': t['price_month']}
    ];
    return json({
      'name': s['lot_name'], 'address': s['address'], 'lat': s['lat'], 'lng': s['lng'], 'prices': prices,
      'nightMark': _nightMark(s), ...await parkingStatus(),
    });
  });

  router.post('/fees/quote', (req) async {
    final timeIn = toDate(req.b('timeIn'));
    final timeOut = truthy(req.b('timeOut')) ? toDate(req.b('timeOut')) : DateTime.now();
    if (timeIn == null || timeOut == null || timeOut.isBefore(timeIn)) {
      throw HttpError(400, 'timeIn / timeOut phải là thời điểm ISO 8601, giờ ra sau giờ vào');
    }
    final vt = str(req.b('vehicleType'));
    final settings = priceOf(await getSettings(), await vehicleTypes(), vt.isNotEmpty ? vt : 'motorbike');
    final monthly = req.b('kind') == 'monthly';
    return json({
      'fee': calcFee(timeIn, timeOut, settings, monthly),
      'nights': nightsCrossed(timeIn, timeOut, minutesOf(settings['night_mark'])),
      'monthly': monthly,
      'priceDay': settings['price_day'],
      'priceNight': settings['price_night'],
      'nightMark': _nightMark(settings),
    });
  });
}

/// Xem lượt gửi, lịch sử, doanh thu, thẻ, cài đặt (quản lý + admin, kiểm ở app.dart).
void viewRoutes(Router router, Deps deps) {
  router.get('/sessions', (req) async {
    final filter = <String, dynamic>{};
    if (req.query['open'] == 'true') {
      filter['parked'] = true;
    } else {
      final date = str(req.query['date']);
      final (from, to) = dayRange(date.isNotEmpty ? date : today());
      filter['time_in'] = {r'$gte': from, r'$lt': to};
    }
    final plate = normPlate(req.query['plate']);
    if (plate.isNotEmpty) {
      filter[r'$or'] = [{'plate_in': containsText(plate)}, {'plate_out': containsText(plate)}];
    }
    final rows = await withJoins(await Session.find(filter, {'time_in': -1}, null, _maxRows));
    return json({
      'count': rows.length,
      'revenue': rows.fold<num>(0, (a, s) => a + ((s['fee'] as num?) ?? 0)),
      'sessions': rows,
    });
  });

  // Tra cứu xe đang trong bãi theo biển (quản lý chụp biển bằng điện thoại hoặc gõ tay).
  // So khớp như ở cổng: lệch tối đa 1 ký tự, xét cả các phương án đọc khác (candidates=a,b,c) của OCR.
  router.get('/sessions/lookup', (req) async {
    final reads = [req.query['plate'], ...str(req.query['candidates']).split(',')]
        .map(normPlate)
        .where((p) => p.isNotEmpty)
        .toList();
    if (reads.isEmpty) throw HttpError(400, 'Cần biển số cần tra');
    final parked = await Session.find({'parked': true}, {'time_in': -1});
    final hits = parked.where((s) => reads.any((p) => samePlate(s['plate_in'], p))).toList();
    final rows = await withJoins(hits, ['kind', 'owner', 'valid_until', 'lost_at'], false);
    return json({'plate': reads[0], 'matches': await _withFee(rows, reads[0])});
  });

  // Quét mã QR vé xe trên app của khách (mã ký, hết hạn sau 10 phút): ra lượt đang gửi của thẻ đó.
  router.get('/sessions/by-ticket', (req) async {
    Object? uid;
    try {
      uid = jwtVerify(str(req.query['qr']), deps.jwtSecret, audience: ticketAudience)['uid'];
    } catch (_) {
      throw HttpError(400, 'Mã QR vé không hợp lệ hoặc đã hết hạn, nhờ khách mở lại mã');
    }
    final card = uid == null ? null : await Card.findOne({'uid': uid});
    if (card == null) throw HttpError(404, 'Thẻ của mã QR không còn trong hệ thống');
    final parked = await withJoins(
        await Session.find({'card_uid': uid, 'parked': true}), ['kind', 'owner', 'valid_until', 'lost_at'], false);
    return json({
      'cardUid': uid, 'owner': card['owner'], 'validUntil': card['valid_until'], 'lost': card['lost_at'] != null,
      'matches': await _withFee(parked, null),
    });
  });

  router.get('/sessions/:id/fee', (req) async {
    final s = await Session.findById(pathId(req.params['id']!));
    if (s == null) throw HttpError(404, 'Không có lượt gửi này');
    if (s['time_out'] != null) return json({'fee': s['fee'], 'closed': true});
    return json({'fee': await feeNow(s), 'closed': false});
  });

  router.get('/events', (req) async {
    final limit = numOr(req.query['limit'], 20).clamp(1, 200).toInt();
    final events = await GateEvent.find({}, {'_id': -1}, null, limit);
    final names = await guardNames(events.map((e) => e['guard_id']));
    return json([for (final e in events) {...row(e)!, 'guard_name': names[e['guard_id']]}]);
  });

  // Màn thêm thẻ hỏi định kỳ: thẻ vừa quẹt ở cổng bất kỳ sau mốc since.
  router.get('/scans/latest', (req) async {
    final q = str(req.query['since']);
    final since = q.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : toDate(q);
    if (since == null) throw HttpError(400, 'since phải là thời điểm ISO 8601');
    final e = await GateEvent.findOne({
      'kind': 'scan', 'uid': {r'$type': 'string'}, 'created_at': {r'$gt': since},
    }, sort: {'_id': -1});
    return json(e == null
        ? null
        : {'uid': e['uid'], 'gate': e['gate'], 'created_at': e['created_at'],
            'registered': await Card.exists({'uid': e['uid']})});
  });

  router.get('/cards', (req) async {
    final q = containsText(str(req.query['q']));
    final cards = await Card.find({
      r'$or': [{'uid': q}, {'plate': q}, {'owner': q}]
    }, {'created_at': -1});
    final users = await User.find({
      '_id': {r'$in': [for (final c in cards) if (truthy(c['user_id'])) c['user_id']]}
    }, null, {'username': 1});
    final names = {for (final u in users) u['_id']: u['username']};
    final slots = {
      for (final sl in await Slot.find({'card_uid': {r'$in': [for (final c in cards) c['uid']]}})) sl['card_uid']: sl['code']
    };
    return json([
      for (final c in cards) {...row(c)!, 'user_name': names[c['user_id']], 'slot_code': slots[c['uid']]}
    ]);
  });

  router.get('/settings', (_) async => json(await getSettings()));
}

/// Dữ liệu thẻ từ body. Nhận cả tên cột (valid_until) lẫn tên API (validUntil).
Map<String, dynamic> _cardInput(Map body, String uid, Map<String, Map> types) {
  final kind = body['kind'] ?? 'guest';
  final rawType = body.containsKey('vehicleType') ? body['vehicleType'] : body['vehicle_type'];
  final vehicleType = truthy(rawType) ? rawType : (kind == 'monthly' ? 'motorbike' : null);
  if (vehicleType != null && !types.containsKey(vehicleType)) throw HttpError(400, 'Loại xe không hợp lệ');
  if (kind != 'guest' && kind != 'monthly') throw HttpError(400, 'Loại vé là guest hoặc monthly');
  final plate = normPlate(body['plate']);
  if (kind == 'monthly' && plate.isEmpty) throw HttpError(400, 'Vé tháng cần biển số');
  if (!uidRe.hasMatch(uid)) throw HttpError(400, 'UID phải là 8-20 ký tự hex (0-9, A-F)');
  final until = body.containsKey('validUntil') ? body['validUntil'] : body['valid_until'];
  if (until != null && !dateRe.hasMatch(cut('$until', 10))) throw HttpError(400, 'Hạn vé dạng YYYY-MM-DD');
  final owner = str(body['owner']), apartment = str(body['apartment']).toUpperCase();
  return {
    'uid': uid, 'kind': kind, 'plate': plate.isEmpty ? null : plate, 'owner': owner.isEmpty ? null : owner,
    'active': body['active'] != false,
    'valid_until': kind == 'monthly' && truthy(until) ? cut('$until', 10) : null,
    'vehicle_type': kind == 'monthly' ? vehicleType : null, 'apartment': apartment.isEmpty ? null : apartment,
  };
}

void manageRoutes(Router router) {
  // Mất thẻ / xử lý tay: tính phí tới bây giờ, đóng lượt gửi, ra lệnh mở barrier cổng ra.
  router.post('/sessions/:id/release', (req) async {
    final s = await Session.findById(pathId(req.params['id']!));
    if (s == null) throw HttpError(404, 'Không có lượt gửi này');
    if (s['time_out'] != null) throw HttpError(409, 'Lượt gửi đã kết thúc');
    final fee = await feeNow(s);
    final session = await closeSession(s['_id'], {'fee': fee});
    if (session == null) throw HttpError(409, 'Lượt gửi vừa được đóng ở nơi khác');
    await _openGate('Cho ra thu cong boi ${req.user['username']}');
    return json({'session': session, 'fee': fee});
  });

  // ĐT camera cổng ra hỏi định kỳ GET /gate/commands rồi gửi lệnh mở barrier cho ESP32.
  router.post('/gate/open', (req) async => json(await _openGate('Lenh tu API boi ${req.user['username']}'), 201));

  router.post('/cards', (req) async =>
      json(await Card.create(_cardInput(req.map, str(req.b('uid')).toUpperCase(), await vehicleTypes())), 201));

  // Mở lại thẻ đã báo mất (khách tìm lại được thẻ): gửi {lost: false}.
  router.patch('/cards/:uid', (req) async {
    final uid = req.params['uid']!.toUpperCase();
    final old = await Card.findOne({'uid': uid});
    if (old == null) throw HttpError(404, 'Không có thẻ này');
    final changes = {
      ..._cardInput({...old, ...req.map}, uid, await vehicleTypes()),
      if (req.b('lost') == false) 'lost_at': null,
    };
    // Thẻ thôi là vé tháng hoặc đổi loại xe thì trả ô riêng về cho khách vãng lai.
    if (changes['kind'] != 'monthly' || changes['vehicle_type'] != old['vehicle_type']) {
      await Slot.updateMany({'card_uid': uid}, {'card_uid': null});
    }
    return json(row(await Card.findOneAndUpdate({'uid': uid}, changes)));
  });

  // Xoá thẻ bất cứ lúc nào, trừ khi xe của thẻ đang trong bãi. Lịch sử ra vào cũ vẫn giữ (lượt gửi lưu UID thẻ).
  router.delete('/cards/:uid', (req) async {
    final uid = req.params['uid']!.toUpperCase();
    if (!(await Card.exists({'uid': uid}))) throw HttpError(404, 'Không có thẻ này');
    if (await Session.exists({'card_uid': uid, 'parked': true})) {
      throw HttpError(409, 'Xe của thẻ này đang trong bãi: cho xe ra (Tổng quan → chạm vào xe) rồi mới xoá thẻ');
    }
    await Card.deleteOne({'uid': uid});
    await TicketRequest.updateMany({'card_uid': uid}, {'card_uid': null});
    await Slot.updateMany({'card_uid': uid}, {'card_uid': null});
    return noContent();
  });

  router.put('/settings', (req) async {
    // Giá theo loại xe sửa ở /vehicle-types; ở đây là sức chứa (khi chưa vẽ sơ đồ), mốc đêm, thông tin bãi.
    final capacity = asInt(req.b('capacity'));
    final nightMark = str(req.b('nightMark'));
    if (capacity == null || capacity <= 0) throw HttpError(400, 'Sức chứa là số nguyên > 0');
    if (!_timeRe.hasMatch(nightMark)) throw HttpError(400, 'Mốc đêm dạng HH:MM');
    // Vị trí bãi (không bắt buộc): gửi kèm thì phải đủ cặp toạ độ hợp lệ.
    final old = await getSettings();
    final lat = req.has('lat') ? req.b('lat') : old['lat'], lng = req.has('lng') ? req.b('lng') : old['lng'];
    if ((lat == null) != (lng == null) ||
        (lat != null && (lat is! num || lng is! num || lat.abs() > 90 || lng.abs() > 180))) {
      throw HttpError(400, 'Toạ độ bãi không hợp lệ');
    }
    final lotName = str(req.b('lotName')), address = str(req.b('address'));
    return json(row(await Settings.findByIdAndUpdate(1, {
      'capacity': capacity, 'night_mark': '$nightMark:00',
      'lot_name': lotName.isNotEmpty ? lotName : old['lot_name'],
      'address': req.has('address') ? (address.isEmpty ? null : address) : old['address'], 'lat': lat, 'lng': lng,
    })));
  });
}
