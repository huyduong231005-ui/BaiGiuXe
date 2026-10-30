// Khách hàng = chủ vé tháng: thẻ của tôi, báo mất thẻ, mã QR vé, lịch sử ra vào kèm ảnh, đơn đăng ký / gia hạn vé tháng.
// Quản lý: duyệt / từ chối đơn, gán thẻ RFID cho khách.
import 'db.dart';
import 'deps.dart';
import 'http.dart';
import 'jwt.dart';
import 'lot.dart';
import 'parking.dart';
import 'plates.dart' show imageUrl, imgPathRe;
import 'rules.dart';

final _plateRe = RegExp(r'^[A-Z0-9]{5,12}$');
const _ticketTtl = Duration(minutes: 10);
const _maxPending = 3; // chống gửi đơn tràn lan
const _maxHistory = 100;
const _maxApartment = 20;

Future<Doc?> _myCard(Object? uid, Object? userId) => Card.findOne({'uid': '$uid'.toUpperCase(), 'user_id': userId});

Future<List<Object?>> _myUids(Object? userId) async =>
    [for (final c in await Card.find({'user_id': userId}, null, {'uid': 1})) c['uid']];

Future<Map<String, dynamic>> _requestInput(Req req) async {
  final plate = normPlate(req.b('plate'));
  final ownerName = str(req.b('ownerName'));
  final months = asInt(req.b('months'));
  final vt = str(req.b('vehicleType'));
  final vehicleType = vt.isNotEmpty ? vt : 'motorbike';
  final apartment = cut(str(req.b('apartment')).toUpperCase(), _maxApartment);
  if (!_plateRe.hasMatch(plate)) throw HttpError(400, 'Biển số 5-12 ký tự chữ và số');
  if (ownerName.isEmpty) throw HttpError(400, 'Cần nhập tên chủ xe');
  if (months == null || months < 1 || months > 12) throw HttpError(400, 'Số tháng từ 1 đến 12');
  if (!(await vehicleTypes()).containsKey(vehicleType)) throw HttpError(400, 'Loại xe không hợp lệ');
  if (apartment.isEmpty) throw HttpError(400, 'Cần nhập căn hộ (VD: A1-12.05)');
  final note = cut(str(req.b('note')), 300);
  return {'plate': plate, 'owner_name': ownerName, 'months': months, 'vehicle_type': vehicleType,
    'apartment': apartment, 'note': note.isEmpty ? null : note};
}

/// Các API /me/... của khách hàng (đã kiểm vai trò customer ở app.dart).
void customerRoutes(Router router, Deps deps) {
  // Thẻ của tôi, kèm xe đang gửi (nếu có) và phí nếu ra bây giờ.
  router.get('/me/cards', (req) async {
    final cards = await Card.find({'user_id': req.user['id']}, {'created_at': 1});
    final uids = [for (final c in cards) c['uid']];
    final (parked, slots, settings, types) = await (
      Session.find({'card_uid': {r'$in': uids}, 'parked': true}), Slot.find({'card_uid': {r'$in': uids}}),
      getSettings(), vehicleTypes(),
    ).wait;
    final byUid = {for (final s in parked) s['card_uid']: s};
    final slotOf = {for (final s in slots) s['card_uid']: s['code']};
    final now = DateTime.now();
    return json([
      for (final c in cards)
        {
          ...row(c)!,
          'session_id': byUid[c['uid']]?['_id'], 'parked_plate': byUid[c['uid']]?['plate_in'],
          'parked_since': byUid[c['uid']]?['time_in'], 'parked_img': byUid[c['uid']]?['img_in'],
          'slot_code': slotOf[c['uid']], 'parked_slot': byUid[c['uid']]?['slot_code'],
          'valid': c['kind'] != 'monthly' || monthlyValid(c, now),
          'fee_now': byUid[c['uid']] == null
              ? null
              : calcFee(byUid[c['uid']]!['time_in'], now, priceOf(settings, types, byUid[c['uid']]!['vehicle_type']),
                  monthlyValid(c, now)),
        }
    ]);
  });

  // Báo mất thẻ: khoá ngay, cổng từ chối cả lúc vào lẫn lúc ra (người nhặt được không lấy được xe).
  router.post('/me/cards/:uid/lost', (req) async {
    final filter = {'uid': req.params['uid']!.toUpperCase(), 'user_id': req.user['id']};
    final card = await Card.findOne(filter);
    if (card == null) throw HttpError(404, 'Không có thẻ này trong tài khoản của bạn');
    return json(row(await Card.findOneAndUpdate(filter, {'lost_at': card['lost_at'] ?? DateTime.now(), 'active': false})));
  });

  // Mã QR vé xe: ký bằng JWT, hết hạn sau 10 phút, không lộ UID thẻ (UID lộ ra thì sao chép được thẻ RFID).
  router.get('/me/cards/:uid/qr', (req) async {
    final card = await _myCard(req.params['uid'], req.user['id']);
    if (card == null) throw HttpError(404, 'Không có thẻ này trong tài khoản của bạn');
    return json({
      'qr': jwtSign({'uid': card['uid']}, deps.jwtSecret, expiresIn: _ticketTtl, audience: ticketAudience),
      'expiresInSec': 600,
    });
  });

  router.get('/me/sessions', (req) async {
    final sessions =
        await Session.find({'card_uid': {r'$in': await _myUids(req.user['id'])}}, {'time_in': -1}, null, _maxHistory);
    return json(await withJoins(sessions, []));
  });

  // Ảnh xe của chính mình (lúc vào / ra) để đối chiếu khi nghi bị lấy xe.
  router.get('/me/plates/url', (req) async {
    final path = str(req.query['path']);
    if (!imgPathRe.hasMatch(path)) throw HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    final mine = await Session.exists({
      'card_uid': {r'$in': await _myUids(req.user['id'])},
      r'$or': [{'img_in': path}, {'img_out': path}],
    });
    if (!mine) throw HttpError(403, 'Ảnh này không thuộc xe của bạn');
    return json({'url': imageUrl(req, path, deps.jwtSecret)});
  });

  router.get('/me/requests', (req) async =>
      json([for (final r in await TicketRequest.find({'user_id': req.user['id']}, {'created_at': -1})) row(r)]));

  router.post('/me/requests', (req) async {
    final r = await _requestInput(req);
    final cardUid = truthy(req.b('cardUid')) ? '${req.b('cardUid')}'.toUpperCase() : null;
    if (cardUid != null && await _myCard(cardUid, req.user['id']) == null) {
      throw HttpError(400, 'Chỉ gia hạn được thẻ của chính bạn');
    }
    final n = await TicketRequest.count({'user_id': req.user['id'], 'status': 'pending'});
    if (n >= _maxPending) throw HttpError(429, 'Đã có $n đơn đang chờ duyệt, hãy đợi quản lý xử lý');
    return json(await TicketRequest.insert({'user_id': req.user['id'], 'card_uid': cardUid, ...r}), 201);
  });

  router.patch('/me/requests/:id', (req) async {
    final r = await _requestInput(req);
    final saved = await TicketRequest.findOneAndUpdate(
        {'_id': pathId(req.params['id']!), 'user_id': req.user['id'], 'status': 'pending'}, r);
    if (saved == null) throw HttpError(409, 'Chỉ sửa được đơn đang chờ duyệt của bạn');
    return json(row(saved));
  });

  router.delete('/me/requests/:id', (req) async {
    final deleted = await TicketRequest.deleteOne(
        {'_id': pathId(req.params['id']!), 'user_id': req.user['id'], 'status': 'pending'});
    if (deleted == 0) throw HttpError(409, 'Chỉ huỷ được đơn đang chờ duyệt của bạn');
    return noContent();
  });
}

void requestRoutes(Router router) {
  // Đơn đang chờ lên đầu, rồi mới nhất trước.
  router.get('/requests', (req) async {
    final status = str(req.query['status']);
    final all = await TicketRequest.find({if (status.isNotEmpty) 'status': status}, {'created_at': -1});
    final list = [...all.where((r) => r['status'] == 'pending'), ...all.where((r) => r['status'] != 'pending')];
    final (users, cards) = await (
      User.find({'_id': {r'$in': [for (final r in list) r['user_id']]}}, null, {'username': 1, 'email': 1}),
      Card.find({'uid': {r'$in': [for (final r in list) if (r['card_uid'] != null) r['card_uid']]}}, null,
          {'uid': 1, 'valid_until': 1}),
    ).wait;
    final byUser = {for (final u in users) u['_id']: u};
    final until = {for (final c in cards) c['uid']: c['valid_until']};
    return json([
      for (final r in list.where((r) => byUser.containsKey(r['user_id'])).take(200))
        {
          ...row(r)!, 'username': byUser[r['user_id']]!['username'], 'email': byUser[r['user_id']]!['email'],
          'card_valid_until': until[r['card_uid']],
        }
    ]);
  });

  Future<Map<String, dynamic>> pending(String id) async {
    final r = await TicketRequest.findById(pathId(id));
    if (r == null) throw HttpError(404, 'Không có đơn này');
    if (r['status'] != 'pending') throw HttpError(409, 'Đơn đã được xử lý');
    return row(r)!;
  }

  // Duyệt: gia hạn thẻ cũ, hoặc gán thẻ RFID mới (cardUid quẹt / NFC / gõ) thành vé tháng của khách.
  router.post('/requests/:id/approve', (req) async {
    final r = await pending(req.params['id']!);
    final uid = (r['card_uid'] ?? '${req.b('cardUid') ?? ''}'.toUpperCase()) as String;
    if (!uidRe.hasMatch(uid)) throw HttpError(400, 'Cần UID thẻ RFID để cấp vé tháng mới');
    final card = await Card.findOne({'uid': uid});
    if (truthy(card?['user_id']) && card!['user_id'] != r['user_id']) throw HttpError(409, 'Thẻ này đang thuộc khách khác');
    final until = extendUntil(card?['kind'] == 'monthly' ? card!['valid_until'] : null, r['months']);
    final saved = await Card.findOneAndUpdate({'uid': uid}, {
      'kind': 'monthly', 'plate': r['plate'], 'owner': r['owner_name'], 'active': true, 'user_id': r['user_id'],
      'valid_until': until, 'lost_at': null, 'vehicle_type': r['vehicle_type'], 'apartment': r['apartment'],
    }, upsert: true);
    // Ghi khoản thu vé tháng (doanh thu theo tháng). Ô đậu riêng do quản lý gán trên sơ đồ bãi.
    final price = ((await vehicleTypes())[r['vehicle_type']]?['price_month'] as num?) ?? 0;
    await Payment.insert({'kind': 'monthly', 'amount': price * r['months'], 'card_uid': uid, 'user_id': r['user_id'],
      'request_id': r['id'], 'months': r['months'], 'vehicle_type': r['vehicle_type']});
    final reply = str(req.b('reply'));
    final done = await TicketRequest.findByIdAndUpdate(r['id'], {
      'status': 'approved', 'card_uid': uid, 'reply': reply.isEmpty ? null : reply, 'handled_by': req.user['id'],
      'handled_at': DateTime.now(),
    });
    return json({'request': row(done), 'card': row(saved)});
  });

  router.post('/requests/:id/reject', (req) async {
    final r = await pending(req.params['id']!);
    final reply = str(req.b('reply'));
    if (reply.isEmpty) throw HttpError(400, 'Cần ghi lý do từ chối để khách biết');
    return json(row(await TicketRequest.findByIdAndUpdate(r['id'],
        {'status': 'rejected', 'reply': reply, 'handled_by': req.user['id'], 'handled_at': DateTime.now()})));
  });
}
