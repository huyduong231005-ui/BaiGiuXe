// Sơ đồ bãi chung cư: loại xe + bảng giá, khu, mặt bằng (lối vào, lối ra, đường đi, ô đậu), chỉ đường.
// Cư dân thuê vé tháng có ô riêng (slot.card_uid); khách vãng lai được API chỉ ô trống gần lối vào nhất theo
// quãng đường xe chạy, đúng loại xe, không đụng ô của cư dân, kèm đường đi từ cổng tới ô.
import 'db.dart';
import 'guards.dart' show inUse;
import 'http.dart';
import 'layout.dart';

final _codeRe = RegExp(r'^[a-z][a-z0-9_]{1,19}$');

/// Loại xe theo code: {motorbike: {...}, car: {...}}.
Future<Map<String, Map<String, dynamic>>> vehicleTypes() async =>
    {for (final t in await VehicleType.find({}, {'_id': 1})) t['code'] as String: row(t)!};

/// Giá áp cho một loại xe (dạng settings mà calcFee dùng). Loại lạ thì lấy giá xe máy.
Map<String, dynamic> priceOf(Map settings, Map<String, Map> types, Object? code) {
  final t = types[code] ?? types['motorbike'] ?? (types.isEmpty ? const {} : types.values.first);
  return {'night_mark': settings['night_mark'], 'price_day': t['price_day'] ?? 0, 'price_night': t['price_night'] ?? 0};
}

/// Plate Recognizer trả loại phương tiện (Motorcycle, Sedan, SUV, Van...) -> code loại xe của bãi.
String? vehicleFromOcr(String? type) {
  if (type == null || type.isEmpty || RegExp('unknown', caseSensitive: false).hasMatch(type)) return null;
  return RegExp('motor', caseSensitive: false).hasMatch(type) ? 'motorbike' : 'car';
}

Future<List<String>> _getLayout() async =>
    [...?((await Settings.findById(1, ))?['layout'] as List?)?.cast<String>()];

/// Ô đang có xe: code -> lượt gửi đang mở.
Future<Map<String, Doc>> _occupiedSlots() async {
  final parked = await Session.find({'parked': true, 'slot_code': {r'$type': 'string'}}, null,
      {'slot_code': 1, 'plate_in': 1, 'card_uid': 1, 'time_in': 1});
  return {for (final s in parked) s['slot_code'] as String: s};
}

/// Chọn ô cho xe vào. Thẻ tháng có ô riêng -> ô đó. Còn lại: ô trống gần lối vào nhất theo quãng đường xe chạy,
/// đúng loại xe, không phải ô riêng của cư dân, không tạm khoá. Trả {code} | {full: true} | null (bãi chưa vẽ).
Future<Map<String, dynamic>?> assignSlot(Map card, String vehicleType) async {
  if (!(await Slot.exists({}))) return null;
  if (card['kind'] == 'monthly') {
    final own = await Slot.findOne({'card_uid': card['uid']});
    if (own != null) return {'code': own['code']};
  }
  final (busy, layout, slots) = await (
    _occupiedSlots(), _getLayout(), Slot.find({'vehicle_type': vehicleType, 'card_uid': null, 'active': true}),
  ).wait;
  final dist = slotDistances(layout);
  Cell pos(Doc s) => ((s['row'] as num).toInt(), (s['col'] as num).toInt());
  final free = slots.where((s) => !busy.containsKey(s['code']) && dist.containsKey(pos(s))).toList()
    ..sort((a, b) => dist[pos(a)]! != dist[pos(b)]!
        ? dist[pos(a)]! - dist[pos(b)]!
        : (a['code'] as String).compareTo(b['code'] as String));
  return free.isNotEmpty ? {'code': free.first['code']} : {'full': true};
}

/// Đường từ lối vào tới ô (và từ ô ra lối ra) + lời chỉ dẫn. null nếu ô không có trên mặt bằng.
Future<Map<String, dynamic>?> slotRoute(String code) async {
  final slot = await Slot.findOne({'code': code});
  if (slot == null) return null;
  final r = route(await _getLayout(), (slot['row'] as num).toInt(), (slot['col'] as num).toInt(), slot['code']);
  return r == null ? null : {'slot': slot['code'], ...r};
}

/// Đồng bộ ô đậu theo mặt bằng mới. Ô giữ nguyên mã nếu vẫn ở đúng vị trí và cùng khu (không làm lệch ô của cư dân);
/// ô mới lấy số tiếp theo của khu. Ô bị xoá khỏi mặt bằng mà đang có xe hoặc đã gán cư dân thì từ chối.
Future<void> _syncSlots(List<String> layout) async {
  final zones = {for (final z in await Zone.find()) z['name'] as String: z};
  final old = await Slot.find();
  final byPos = {for (final s in old) '${s['row']},${s['col']}': s};
  final keep = <Object?>{};
  final created = <(int, int, Doc)>[];
  for (final (r, c) in cellsOf(layout, isZoneLetter)) {
    final z = zones[layout[r][c]]!;
    final s = byPos['$r,$c'];
    if (s != null && s['zone_id'] == z['_id']) {
      keep.add(s['_id']);
      if (s['vehicle_type'] != z['vehicle_type']) await Slot.updateOne({'_id': s['_id']}, {'vehicle_type': z['vehicle_type']});
    } else {
      created.add((r, c, z));
    }
  }
  final removed = old.where((s) => !keep.contains(s['_id'])).toList();
  final busy = await _occupiedSlots();
  final blocked = removed.where((s) => s['card_uid'] != null || busy.containsKey(s['code'])).toList();
  if (blocked.isNotEmpty) {
    throw HttpError(409,
        'Ô ${blocked.map((s) => s['code']).take(5).join(', ')} đang có xe hoặc đã gán cư dân, không xoá khỏi mặt bằng được');
  }
  await Slot.deleteMany({'_id': {r'$in': [for (final s in removed) s['_id']]}});
  // Số tiếp theo của mỗi khu: lớn hơn mọi số đang dùng
  final next = <String, int>{};
  for (final s in await Slot.find({}, null, {'code': 1})) {
    final [zn, n, ...] = (s['code'] as String).split('-');
    final num = int.tryParse(n) ?? 0;
    next[zn] = (next[zn] ?? 0) > num ? next[zn]! : num;
  }
  for (final (r, c, z) in created) {
    final n = (next[z['name']] ?? 0) + 1;
    next[z['name']] = n;
    await Slot.insert({
      'code': '${z['name']}-${n.toString().padLeft(2, '0')}', 'zone_id': z['_id'], 'row': r, 'col': c,
      'vehicle_type': z['vehicle_type'],
    });
  }
}

Map<String, dynamic> _typeInput(Req req) {
  final name = str(req.b('name'));
  final prices = [for (final k in ['priceDay', 'priceNight', 'priceMonth']) asInt(req.b(k))];
  if (name.isEmpty) throw HttpError(400, 'Cần tên loại xe');
  if (!prices.every((v) => v != null && v >= 0)) throw HttpError(400, 'Giá là số nguyên ≥ 0');
  return {'name': name, 'price_day': prices[0], 'price_night': prices[1], 'price_month': prices[2]};
}

Map<String, dynamic> _zoneInput(Req req, Map<String, Map> types) {
  final name = str(req.b('name')).toUpperCase();
  final vt = str(req.b('vehicleType'));
  if (!zoneLetterRe.hasMatch(name)) throw HttpError(400, 'Tên khu là 1 chữ cái A-Z (trừ I, O dùng cho lối vào / lối ra)');
  if (!types.containsKey(vt)) throw HttpError(400, 'Loại xe là một trong: ${types.keys.join(', ')}');
  return {'name': name, 'vehicle_type': vt};
}

/// Sơ đồ bãi đầy đủ: mặt bằng + khu + ô kèm trạng thái (free | resident | parked | off) và xe đang đậu.
Future<Map<String, dynamic>> lotMap({bool withPlates = true}) async {
  final (zones, slots, busy, types, layout) = await (
    Zone.find({}, {'name': 1}), Slot.find({}, {'code': 1}), _occupiedSlots(), vehicleTypes(), _getLayout(),
  ).wait;
  final owners = {
    for (final c in await Card.find({
      'uid': {r'$in': [for (final s in slots) if (s['card_uid'] != null) s['card_uid']]}
    }, null, {'uid': 1, 'owner': 1, 'apartment': 1, 'plate': 1}))
      c['uid']: c
  };
  return {
    'layout': layout,
    'types': types.values.toList(),
    'zones': [
      for (final z in zones)
        {
          ...row(z)!,
          'slots': [
            for (final s in slots.where((s) => s['zone_id'] == z['_id']))
              {
                ...row(s)!,
                'state': s['active'] != true
                    ? 'off'
                    : busy.containsKey(s['code'])
                        ? 'parked'
                        : s['card_uid'] != null
                            ? 'resident'
                            : 'free',
                if (withPlates) ...{
                  'plate': busy[s['code']]?['plate_in'], 'since': busy[s['code']]?['time_in'],
                  'owner': owners[s['card_uid']]?['owner'], 'apartment': owners[s['card_uid']]?['apartment'],
                  'resident_plate': owners[s['card_uid']]?['plate'],
                },
              },
          ],
        },
    ],
  };
}

/// Chỗ trống theo loại xe (cho trang chủ, OLED, khách xem trên app).
Future<Map<String, Map<String, int>>> freeByType() async {
  final map = await lotMap(withPlates: false);
  final out = <String, Map<String, int>>{};
  for (final z in map['zones'] as List) {
    final t = out.putIfAbsent(z['vehicle_type'], () => {'capacity': 0, 'free': 0, 'visitorFree': 0});
    for (final s in z['slots'] as List) {
      if (s['state'] == 'off') continue;
      t['capacity'] = t['capacity']! + 1;
      if (s['state'] != 'parked') t['free'] = t['free']! + 1;
      if (s['state'] == 'free') t['visitorFree'] = t['visitorFree']! + 1;
    }
  }
  return out;
}

/// Đường tới ô: ai đăng nhập cũng xem được (cư dân xem đường tới ô của mình, ĐT cổng chỉ đường cho khách).
Future<Map<String, dynamic>> routeOf(Req req) async {
  final r = await slotRoute(str(req.query['slot']).toUpperCase());
  if (r == null) throw HttpError(404, 'Không có ô này trên mặt bằng');
  return r;
}

/// Kiểm tra + lưu mặt bằng, đồng bộ ô đậu.
Future<void> applyLayout(Object? raw) async {
  final layout = raw is List ? [for (final l in raw) '$l'.toUpperCase()] : null;
  final err = layoutError(layout, [for (final z in await Zone.find({}, null, {'name': 1})) z['name'] as String]);
  if (err != null) throw HttpError(400, err);
  await _syncSlots(layout!);
  await Settings.updateOne({'_id': 1}, {'layout': layout});
}

void lotRoutes(Router router) {
  router.get('/lot/map', (_) async => json(await lotMap()));

  // Lưu mặt bằng: kiểm tra lối vào / ra, mọi ô đậu có đường tới, rồi đồng bộ ô đậu.
  router.put('/lot/layout', (req) async {
    await applyLayout(req.b('layout'));
    return json(await lotMap());
  });

  // ---- Loại xe + bảng giá ----
  router.get('/vehicle-types', (_) async => json((await vehicleTypes()).values.toList()));

  router.post('/vehicle-types', (req) async {
    final code = str(req.b('code')).toLowerCase();
    if (!_codeRe.hasMatch(code)) throw HttpError(400, 'Mã loại xe 2-20 ký tự: chữ thường, số, _ (VD: ebike)');
    return json(await VehicleType.insert({'code': code, ..._typeInput(req)}), 201);
  });

  router.put('/vehicle-types/:id', (req) async {
    final t = await VehicleType.findByIdAndUpdate(pathId(req.params['id']!), _typeInput(req));
    if (t == null) throw HttpError(404, 'Không có loại xe này');
    return json(row(t));
  });

  router.delete('/vehicle-types/:id', (req) async {
    final t = await VehicleType.findById(pathId(req.params['id']!));
    if (t == null) throw HttpError(404, 'Không có loại xe này');
    final used = await [
      Zone.exists({'vehicle_type': t['code']}), Card.exists({'vehicle_type': t['code']}),
      Session.exists({'vehicle_type': t['code']}),
    ].wait;
    if (used.any((u) => u)) throw HttpError(409, inUse);
    await VehicleType.deleteOne({'_id': t['_id']});
    return noContent();
  });

  // ---- Khu (ô của khu vẽ trên mặt bằng bằng chữ cái tên khu) ----
  router.post('/zones', (req) async => json(await Zone.insert(_zoneInput(req, await vehicleTypes())), 201));

  router.put('/zones/:id', (req) async {
    final id = pathId(req.params['id']!);
    final old = await Zone.findById(id);
    if (old == null) throw HttpError(404, 'Không có khu này');
    final data = _zoneInput(req, await vehicleTypes());
    if (data['name'] != old['name']) {
      throw HttpError(400, 'Không đổi tên khu (tên trùng ký tự trên mặt bằng); tạo khu mới rồi vẽ lại');
    }
    if (data['vehicle_type'] != old['vehicle_type']) {
      final slots = await Slot.find({'zone_id': id});
      final busy = await _occupiedSlots();
      if (slots.any((s) => s['card_uid'] != null || busy.containsKey(s['code']))) {
        throw HttpError(409, 'Khu đang có xe hoặc có ô cư dân, không đổi loại xe được');
      }
      await Slot.updateMany({'zone_id': id}, {'vehicle_type': data['vehicle_type']});
    }
    return json(row(await Zone.findByIdAndUpdate(id, data)));
  });

  router.delete('/zones/:id', (req) async {
    final z = await Zone.findById(pathId(req.params['id']!));
    if (z == null) throw HttpError(404, 'Không có khu này');
    if (await Slot.exists({'zone_id': z['_id']})) {
      throw HttpError(409, 'Khu ${z['name']} còn ô trên mặt bằng, xoá các ô đó trước');
    }
    await Zone.deleteOne({'_id': z['_id']});
    return noContent();
  });

  // ---- Ô: gán cho cư dân (thẻ tháng cùng loại xe) / bỏ gán / tạm khoá ----
  router.patch('/slots/:code', (req) async {
    final code = req.params['code']!.toUpperCase();
    final slot = await Slot.findOne({'code': code});
    if (slot == null) throw HttpError(404, 'Không có ô này');
    final changes = <String, dynamic>{};
    if (req.has('cardUid')) {
      final uid = truthy(req.b('cardUid')) ? '${req.b('cardUid')}'.toUpperCase() : null;
      if (uid != null) {
        final card = await Card.findOne({'uid': uid});
        if (card == null || card['kind'] != 'monthly') throw HttpError(400, 'Chỉ gán ô cho thẻ vé tháng');
        if (card['vehicle_type'] != null && card['vehicle_type'] != slot['vehicle_type']) {
          throw HttpError(400, 'Ô này khác loại xe của thẻ');
        }
        await Slot.updateMany({'card_uid': uid, 'code': {r'$ne': code}}, {'card_uid': null}); // mỗi thẻ 1 ô
      }
      changes['card_uid'] = uid;
    }
    if (req.b('active') is bool) changes['active'] = req.b('active');
    return json(row(await Slot.findOneAndUpdate({'code': code}, changes)));
  });
}
