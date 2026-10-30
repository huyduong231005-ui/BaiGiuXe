// Mô hình MongoDB, giữ nguyên tên collection, id số tự tăng, tên trường snake_case, giá trị mặc định và index như bản
// Mongoose trước đây: dữ liệu đang có trên Atlas dùng tiếp được, JSON trả về không đổi nên app Flutter không phải sửa.
// ignore_for_file: non_constant_identifier_names
import 'dart:io';

import 'package:mongo_dart/mongo_dart.dart';

late Db db;
String? _uri;
Future<void>? _opening;

/// Kết nối MongoDB (mongodb:// hoặc mongodb+srv:// của Atlas).
Future<void> connect(String uri) async {
  _uri = uri;
  db = await Db.create(uri);
  await db.open();
}

/// Mất kết nối (Atlas đóng socket lâu không dùng...) thì mở lại trước khi xử lý request.
Future<void> ensureConnected() {
  if (db.isConnected) return Future.value();
  return _opening ??= () async {
    try {
      await db.close().catchError((_) {});
      db = await Db.create(_uri!);
      await db.open();
    } finally {
      _opening = null;
    }
  }();
}

typedef Doc = Map<String, dynamic>;

DateTime _now() => DateTime.now();

class Model {
  Model(this.name, [this.defaults = _none]);
  final String name;

  /// Giá trị mặc định của các trường (như default trong schema Mongoose), gọi lại mỗi lần thêm để lấy giờ hiện tại.
  final Doc Function() defaults;
  static Doc _none() => {};

  DbCollection get col => db.collection(name);

  Future<List<Doc>> find([Doc filter = const {}, Map<String, Object>? sort, Map<String, Object>? fields, int? limit]) =>
      col.modernFind(filter: filter, sort: sort, projection: fields, limit: limit).toList();

  Future<Doc?> findOne(Doc filter, {Map<String, Object>? sort, Map<String, Object>? fields}) =>
      col.modernFindOne(filter: filter, sort: sort, projection: fields);

  Future<Doc?> findById(Object? id) => findOne({'_id': id});

  Future<bool> exists(Doc filter) async => await findOne(filter, fields: {'_id': 1}) != null;

  Future<int> count(Doc filter) => col.count(filter);

  /// Thêm document có id số tự tăng, trả về dòng JSON.
  Future<Doc> insert(Doc data) async => create({'_id': await nextId(name), ...data});

  /// Thêm document (đủ các trường mặc định), trả về dòng JSON.
  Future<Doc> create(Doc data) async {
    final doc = <String, dynamic>{if (data.containsKey('_id')) '_id': data['_id'], ...defaults(), ...data};
    _check(await col.insertOne(doc));
    return row(doc)!;
  }

  /// Sửa một document, trả về bản mới (null nếu không có). upsert thì điền giá trị mặc định khi tạo mới.
  Future<Doc?> findOneAndUpdate(Doc filter, Doc update, {bool upsert = false}) async {
    final u = _update(update, upsert ? filter : null);
    if (u.isEmpty) return findOne(filter);
    final res = await col.modernFindAndModify(query: filter, update: u, returnNew: true, upsert: upsert);
    return res.value;
  }

  Future<Doc?> findByIdAndUpdate(Object? id, Doc update) => findOneAndUpdate({'_id': id}, update);

  Future<void> updateOne(Doc filter, Doc update, {bool upsert = false}) async {
    final u = _update(update, upsert ? filter : null);
    if (u.isNotEmpty) _check(await col.updateOne(filter, u, upsert: upsert));
  }

  Future<void> updateMany(Doc filter, Doc update) async {
    final u = _update(update, null);
    if (u.isNotEmpty) _check(await col.updateMany(filter, u));
  }

  Future<int> deleteOne(Doc filter) async => (await col.deleteOne(filter)).nRemoved;
  Future<int> deleteMany(Doc filter) async => (await col.deleteMany(filter)).nRemoved;

  /// Trường thường gom vào $set như Mongoose; upsert thì thêm $setOnInsert cho các trường mặc định chưa đặt.
  Doc _update(Doc update, Doc? upsertFilter) {
    final out = <String, dynamic>{};
    final set = <String, dynamic>{};
    update.forEach((k, v) => k.startsWith(r'$') ? out[k] = v : set[k] = v);
    if (set.isNotEmpty) out[r'$set'] = {...?out[r'$set'], ...set};
    if (upsertFilter != null) {
      final taken = {...?(out[r'$set'] as Map?)?.keys, ...upsertFilter.keys, ...?(out[r'$inc'] as Map?)?.keys};
      final onInsert = <String, dynamic>{...?(out[r'$setOnInsert'] as Map?)}..addAll({
          for (final e in defaults().entries)
            if (!taken.contains(e.key)) e.key: e.value
        });
      if (onInsert.isNotEmpty) out[r'$setOnInsert'] = onInsert;
    }
    return out;
  }

  static void _check(WriteResult r) {
    final e = r.writeError;
    if (e == null) return;
    if (e.code == 11000) throw {'code': 11000, 'errmsg': e.errmsg};
    throw StateError('MongoDB ${e.code}: ${e.errmsg}');
  }
}

/// Id số tự tăng theo từng collection.
Future<int> nextId(String name) async {
  final res = await db.collection('counters').modernFindAndModify(
      query: {'_id': name}, update: {r'$inc': {'seq': 1}}, returnNew: true, upsert: true);
  return (res.value!['seq'] as num).toInt();
}

/// Document -> dòng JSON: _id số thành id, bỏ các cờ nội bộ dùng cho index.
Doc? row(Doc? d) {
  if (d == null) return null;
  final r = Map<String, dynamic>.of(d)
    ..remove('_id')
    ..remove('parked')
    ..remove('on_duty');
  return d['_id'] is num ? {'id': d['_id'], ...r} : r;
}

final User = Model('app_users', () => {
      'full_name': '', 'password_hash': null, // null với tài khoản tạo bằng Google
      'google_id': null, 'role': 'customer', 'guard_id': null, // tài khoản bảo vệ gắn với hồ sơ bảo vệ
      'active': false, 'created_at': _now(), // active = true sau khi xác minh email
    });

final Otp = Model('otps', () => {'attempts': 0});

final Settings = Model('settings', () => {
      'capacity': 50, // dùng khi chưa vẽ sơ đồ ô đậu; có ô thì sức chứa = số ô
      'night_mark': '22:00:00', 'layout': <String>[], // mặt bằng bãi dạng lưới ký tự (xem layout.dart)
      'lot_name': 'Bãi giữ xe', 'address': null, 'lat': null, 'lng': null,
    });

// Loại xe và bảng giá (vé lượt ngày / mỗi đêm, vé tháng). code: motorbike | car | bicycle | ...
final VehicleType = Model('vehicle_types', () => {'price_day': 0, 'price_night': 0, 'price_month': 0});

// Khu đậu xe: tên 1 chữ cái (trùng ký tự vẽ ô của khu trên mặt bằng), cùng một loại xe.
final Zone = Model('zones');

// Ô đậu, sinh từ mặt bằng (row, col = vị trí trên lưới). card_uid = ô riêng của cư dân (thẻ tháng); null = ô cho khách.
final Slot = Model('slots', () => {'card_uid': null, 'active': true}); // active = false: ô tạm khoá (sửa chữa...)

// Khoản thu ngoài phí lượt: vé tháng (duyệt đơn đăng ký / gia hạn).
final Payment = Model('payments', () => {
      'kind': 'monthly', 'card_uid': null, 'user_id': null, 'request_id': null, 'months': null,
      'vehicle_type': null, 'note': null, 'created_at': _now(),
    });

final Card = Model('cards', () => {
      'kind': 'guest',
      'vehicle_type': null, // vé tháng: loại xe (giá tháng, ô đậu); vé lượt: null, loại xe lấy theo lượt gửi
      'apartment': null, 'plate': null, 'owner': null, 'active': true, 'created_at': _now(),
      'user_id': null, // chủ thẻ có tài khoản app
      'valid_until': null, // 'YYYY-MM-DD': vé tháng dùng tới hết ngày này (null = không giới hạn)
      'lost_at': null, // chủ thẻ báo mất: cổng từ chối cả lúc vào lẫn lúc ra
    });

final Guard = Model('guards', () => {'finger_id': null, 'pin_hash': null}); // finger_id: ô vân tay trên AS608

// parked = true khi chưa ra: 1 thẻ chỉ có 1 lượt đang gửi, 1 biển chỉ có 1 lượt đang gửi.
final Session = Model('sessions', () => {
      'plate_in': null, 'plate_out': null, 'img_in': null, 'img_out': null, 'time_in': _now(), 'time_out': null,
      'fee': null, 'override_by': null, // bảo vệ mở tay
      'vehicle_type': 'motorbike', 'slot_code': null, // ô đậu được chỉ lúc vào
      'offline': false, // ghi bù từ ESP32 sau khi mất mạng
      'parked': true,
    });

final GateEvent = Model('gate_events', () => {
      // gate: in | out; kind: scan | override | emergency | open_cmd; status: pending | ok | denied | done
      'uid': null, 'ref_id': null, 'guard_id': null, 'status': 'pending', 'plate': null, 'img': null,
      'message': null, 'open': false,
      // Số liệu nhận diện biển của lượt quẹt (thống kê tốc độ / độ chính xác): thời gian chụp + OCR, từ lúc quẹt tới
      // lúc có kết quả, số lần chụp (1 hoặc 2)
      'ocr_ms': null, 'total_ms': null, 'shots': null, 'score': null, 'vehicle_type': null, 'slot_code': null,
      'offline_key': null, // lượt ghi bù từ ESP32: chống ghi trùng khi gửi lại
      'created_at': _now(),
    });

// start_time / end_time dạng 'HH:MM:SS'; end_time <= start_time = ca qua đêm.
final ShiftDef = Model('shift_defs');

// on_duty = true khi chưa chấm ra: mỗi bảo vệ chỉ có 1 ca đang mở.
final Attendance = Model('attendance', () => {
      'shift_id': null, 'shift_name': null, // chép tên ca lúc chấm, đổi/xoá ca sau này không làm sai bảng công cũ
      'shift_start': null, 'shift_end': null, // mốc ca theo lịch (đã gắn ngày) để tính trễ / về sớm
      'time_in': _now(), 'time_out': null,
      'method_in': null, 'method_out': null, // finger | pin | auto (quên chấm ra)
      'on_duty': true,
    });

final TicketRequest = Model('ticket_requests', () => {
      'card_uid': null, // có = gia hạn thẻ đang dùng; null = đăng ký mới
      'vehicle_type': 'motorbike', 'apartment': null, 'note': null,
      'status': 'pending', // pending | approved | rejected | cancelled
      'reply': null, 'handled_by': null, 'handled_at': null, 'created_at': _now(),
    });

// Ảnh biển số (JPEG đã thu nhỏ ~150KB). shortcut: lưu thẳng trong MongoDB, tự xoá sau 90 ngày để không đầy 512MB của
// Atlas free; chuyển sang object storage nếu cần giữ ảnh lâu hơn.
final PlateImage = Model('plate_images', () => {'created_at': _now()});

Doc _unique(Doc key, [Doc? partial]) => {'key': key, 'unique': true, 'partialFilterExpression': ?partial};
Doc _plain(Doc key) => {'key': key};
const _isString = {r'$type': 'string'};
const _isNumber = {r'$type': 'number'};

// Đúng các index Mongoose đã tạo (tên mặc định field_1), để lần chạy đầu trên CSDL cũ không báo trùng khác tuỳ chọn.
final _indexes = <String, List<Doc>>{
  'app_users': [
    _unique({'username': 1}), _unique({'email': 1}),
    _unique({'google_id': 1}, {'google_id': _isString}), _unique({'guard_id': 1}, {'guard_id': _isNumber}),
  ],
  'otps': [_unique({'user_id': 1, 'purpose': 1})],
  'vehicle_types': [_unique({'code': 1})],
  'zones': [_unique({'name': 1})],
  'slots': [_unique({'code': 1}), _unique({'card_uid': 1}, {'card_uid': _isString})],
  'payments': [_plain({'created_at': -1})],
  'cards': [_unique({'uid': 1}), _plain({'user_id': 1})],
  'guards': [_unique({'finger_id': 1}, {'finger_id': _isNumber})],
  'sessions': [
    _unique({'card_uid': 1}, {'parked': true}), _unique({'plate_in': 1}, {'parked': true}), _plain({'time_in': -1}),
  ],
  'gate_events': [_plain({'kind': 1, 'status': 1}), _unique({'offline_key': 1}, {'offline_key': _isString})],
  'attendance': [_unique({'guard_id': 1}, {'on_duty': true}), _plain({'time_in': -1})],
  'ticket_requests': [_plain({'status': 1, 'created_at': -1})],
  'plate_images': [_unique({'path': 1}), {'key': {'created_at': 1}, 'expireAfterSeconds': 90 * 24 * 3600}],
};

// Giá mặc định tham khảo chung cư TP.HCM (QĐ 35/2018 trần xe máy 310.000đ/tháng; dự án thực tế 100–150k xe máy,
// ô tô 1,2–1,5 triệu). Quản lý sửa được trong app.
const _defaultTypes = [
  ('motorbike', 'Xe máy', 5000, 10000, 150000),
  ('car', 'Ô tô', 25000, 50000, 1500000),
  ('bicycle', 'Xe đạp', 2000, 5000, 100000),
];

const _defaultShifts = [('Ca sáng', '06:00:00', '14:00:00'), ('Ca chiều', '14:00:00', '22:00:00'), ('Ca đêm', '22:00:00', '06:00:00')];

/// Tạo index, dòng cài đặt và 3 ca mặc định nếu CSDL còn trống (thay cho migration).
Future<void> initDb() async {
  for (final MapEntry(key: collection, value: specs) in _indexes.entries) {
    final indexes = [for (final s in specs) {...s, 'name': (s['key'] as Doc).entries.map((e) => '${e.key}_${e.value}').join('_')}];
    final res = await db.runCommand({'createIndexes': collection, 'indexes': indexes});
    if (res['ok'] != 1 && res['ok'] != 1.0) stderr.writeln('Không tạo được index $collection: ${res['errmsg']}');
  }
  await Settings.updateOne({'_id': 1}, {r'$setOnInsert': {'capacity': 50}}, upsert: true);
  if (!(await VehicleType.exists({}))) {
    for (final (code, name, day, night, month) in _defaultTypes) {
      await VehicleType.insert({'code': code, 'name': name, 'price_day': day, 'price_night': night, 'price_month': month});
    }
  }
  if (!(await ShiftDef.exists({}))) {
    for (final (name, start, end) in _defaultShifts) {
      await ShiftDef.insert({'name': name, 'start_time': start, 'end_time': end});
    }
  }
}

/// Điều kiện "chứa" không phân biệt hoa thường; escape chuỗi người dùng nhập trước khi đưa vào regex.
Doc containsText(String s) => {r'$regex': s.replaceAllMapped(RegExp(r'[.*+?^${}()|[\]\\]'), (m) => '\\${m[0]}'), r'$options': 'i'};
