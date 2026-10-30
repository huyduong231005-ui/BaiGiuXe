// Lõi HTTP trên shelf: đọc body JSON, router nhỏ giữ đúng thứ tự kiểm quyền như bản Express cũ, JSON trả về như JS
// (ngày dạng ISO UTC có mili giây, số thực nguyên in thành số nguyên).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mongo_dart/mongo_dart.dart' show ObjectId;
import 'package:shelf/shelf.dart';

class HttpError implements Exception {
  HttpError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'HttpError($status, $message)';
}

const _maxJson = 100 * 1024;

/// Chuỗi đã trim, không phải chuỗi thì ''.
String str(Object? v) => v is String ? v.trim() : '';

/// Cắt chuỗi tối đa n ký tự (như slice(0, n) của JS).
String cut(String s, int n) => s.length > n ? s.substring(0, n) : s;

/// Giá trị "truthy" theo JS (null, false, '', 0 là sai).
bool truthy(Object? v) => v != null && v != false && v != '' && v != 0;

/// Số nguyên kể cả 5.0 (Number.isInteger của JS); không phải thì null.
int? asInt(Object? v) => v is int ? v : v is double && v.isFinite && v == v.truncateToDouble() ? v.toInt() : null;

/// Number(s) || dflt của JS: chuỗi không phải số hoặc bằng 0 thì lấy mặc định.
num numOr(String? s, num dflt) {
  final n = num.tryParse((s ?? '').trim());
  return n == null || n.isNaN || n == 0 ? dflt : n;
}

/// id trên đường dẫn: Number(id) || 0.
num pathId(String s) {
  final n = numOr(s, 0);
  return n == n.truncate() ? n.toInt() : n;
}

/// new Date(v) của JS: chuỗi ISO 8601 hoặc số mili giây; không hợp lệ thì null.
DateTime? toDate(Object? v) => switch (v) {
      DateTime d => d,
      String s => DateTime.tryParse(s.trim()),
      num n when n.isFinite && n.abs() < 8.64e15 => DateTime.fromMillisecondsSinceEpoch(n.round()),
      _ => null,
    };

/// Sắp xếp ổn định (List.sort của Dart không giữ thứ tự các phần tử bằng nhau như Array.sort của JS).
List<T> sortedStable<T>(Iterable<T> items, int Function(T a, T b) compare) {
  final indexed = items.indexed.toList()..sort((a, b) => compare(a.$2, b.$2) != 0 ? compare(a.$2, b.$2) : a.$1 - b.$1);
  return [for (final (_, v) in indexed) v];
}

/// Đưa dữ liệu về dạng JSON giống Express trả ra.
Object? jsonSafe(Object? v) => switch (v) {
      Map m => {for (final e in m.entries) '${e.key}': jsonSafe(e.value)},
      Iterable l => [for (final x in l) jsonSafe(x)],
      DateTime d => DateTime.fromMillisecondsSinceEpoch(d.millisecondsSinceEpoch, isUtc: true).toIso8601String(),
      double d when d.isFinite && d == d.truncateToDouble() && d.abs() < 9e15 => d.toInt(),
      double d when !d.isFinite => null,
      ObjectId id => id.oid,
      _ => v,
    };

Response json(Object? data, [int status = 200]) => Response(status,
    body: jsonEncode(jsonSafe(data)), headers: {'content-type': 'application/json; charset=utf-8'});

Response noContent() => Response(204);

class Req {
  Req(this.raw, this.body);
  final Request raw;

  /// Body JSON đã đọc (null nếu không gửi JSON).
  final Object? body;
  Map<String, String> params = {};
  Map<String, dynamic> user = const {};

  Map<String, String> get query => raw.url.queryParameters;
  Map get map => body is Map ? body as Map : const {};
  Object? b(String key) => map[key];

  /// key có trong body (kể cả giá trị null), như `'key' in req.body` của JS.
  bool has(String key) => map.containsKey(key);

  String? header(String name) => raw.headers[name];

  /// IP người gọi: API đứng sau 1 proxy (Render) nên lấy địa chỉ cuối của X-Forwarded-For.
  String get ip {
    final fwd = header('x-forwarded-for');
    if (fwd != null && fwd.trim().isNotEmpty) return fwd.split(',').last.trim();
    return (raw.context['shelf.io.connection_info'] as HttpConnectionInfo?)?.remoteAddress.address ?? '';
  }

  /// Body ảnh (Content-Type image/*), tối đa limit byte. Không phải ảnh thì trả mảng rỗng.
  Future<Uint8List> image(int limit) async {
    if (!(header('content-type') ?? '').toLowerCase().startsWith('image/')) return Uint8List(0);
    return readLimited(raw.read(), limit);
  }
}

Future<Uint8List> readLimited(Stream<List<int>> stream, int limit) async {
  final out = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    out.add(chunk);
    if (out.length > limit) throw HttpError(413, 'Dữ liệu gửi lên quá lớn');
  }
  return out.takeBytes();
}

Future<Object?> _readJson(Request r) async {
  final type = (r.headers['content-type'] ?? '').toLowerCase();
  if (!type.startsWith('application/json')) return null;
  final text = utf8.decode(await readLimited(r.read(), _maxJson), allowMalformed: true);
  if (text.trim().isEmpty) return null;
  try {
    final v = jsonDecode(text);
    if (v is Map || v is List) return v;
  } on FormatException {
    // xử lý chung bên dưới
  }
  throw HttpError(400, 'Dữ liệu không hợp lệ');
}

typedef Handler = FutureOr<Response> Function(Req req);
typedef Middleware = Future<void> Function(Req req);

class _Route {
  _Route(this.method, this.segs, this.handler);
  final String method;
  final List<String> segs;
  final Handler handler;
}

/// Nhóm API. guard chạy cho mọi đường dẫn tới được nhóm (như app.use(guard) của Express: đường dẫn lạ không có token
/// thì 401 chứ không 404); guardAll = false thì chỉ chạy khi khớp một API của nhóm. prefix giới hạn đường dẫn của nhóm.
class Router {
  Router({String? prefix, this.guard, this.guardAll = true}) : _prefix = prefix == null ? null : _split(prefix);
  final List<String>? _prefix;
  final Middleware? guard;
  final bool guardAll;
  final _routes = <_Route>[];

  static List<String> _split(String path) => path.split('/').where((s) => s.isNotEmpty).toList();

  void get(String path, Handler h) => _routes.add(_Route('GET', _split(path), h));
  void post(String path, Handler h) => _routes.add(_Route('POST', _split(path), h));
  void put(String path, Handler h) => _routes.add(_Route('PUT', _split(path), h));
  void patch(String path, Handler h) => _routes.add(_Route('PATCH', _split(path), h));
  void delete(String path, Handler h) => _routes.add(_Route('DELETE', _split(path), h));

  Map<String, String>? _match(List<String> pattern, List<String> segs) {
    if (pattern.length != segs.length) return null;
    final params = <String, String>{};
    for (var i = 0; i < segs.length; i++) {
      if (pattern[i].startsWith(':')) {
        params[pattern[i].substring(1)] = segs[i];
      } else if (pattern[i] != segs[i]) {
        return null;
      }
    }
    return params;
  }

  /// Trả về response nếu nhóm xử lý được, null để nhóm sau thử.
  Future<Response?> handle(Req req, List<String> segs) async {
    final p = _prefix;
    if (p != null && (segs.length < p.length || !Iterable.generate(p.length).every((i) => segs[i] == p[i]))) return null;
    final method = req.raw.method == 'HEAD' ? 'GET' : req.raw.method;
    _Route? hit;
    Map<String, String>? params;
    for (final r in _routes) {
      if (r.method != method) continue;
      params = _match(r.segs, segs);
      if (params != null) {
        hit = r;
        break;
      }
    }
    if (guard != null && (guardAll || hit != null)) await guard!(req);
    if (hit == null) return null;
    req.params = params!;
    return await hit.handler(req);
  }
}

/// Lỗi trùng index unique của MongoDB (E11000).
bool isDuplicateKey(Object e) =>
    (e is Map && e['code'] == 11000) || e.toString().contains('E11000') || e.toString().contains('code: 11000');

/// Handler shelf: đọc JSON rồi đưa qua lần lượt các nhóm; lỗi -> {message} như bản Express.
Future<Response> Function(Request) pipeline(List<Router> routers, {Future<void> Function()? before}) =>
    (Request request) async {
      try {
        await before?.call();
        final req = Req(request, await _readJson(request));
        final segs = request.url.pathSegments.where((s) => s.isNotEmpty).toList();
        for (final r in routers) {
          final res = await r.handle(req, segs);
          if (res != null) return res;
        }
        throw HttpError(404, 'Không tìm thấy API');
      } catch (e, st) {
        if (e is HttpError) return json({'message': e.message}, e.status);
        if (isDuplicateKey(e)) return json({'message': 'Dữ liệu bị trùng (đã tồn tại)'}, 409);
        stderr.writeln('$e\n$st');
        return json({'message': 'Lỗi máy chủ'}, 500);
      }
    };
