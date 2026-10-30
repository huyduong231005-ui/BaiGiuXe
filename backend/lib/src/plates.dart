// Nhận diện biển số qua API: token Plate Recognizer nằm trên máy chủ, không nằm trong file cài app.
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart' show BsonBinary;
import 'package:shelf/shelf.dart' show Response;

import 'db.dart';
import 'deps.dart';
import 'http.dart';
import 'jwt.dart';
import 'rules.dart';

final _plateUrl = Uri.parse('https://api.platerecognizer.com/v1/plate-reader/');
const _maxImage = 5 * 1024 * 1024; // app gửi ảnh đã thu về cạnh dài 1280px (~150KB)
const _upstreamTimeout = Duration(seconds: 8);
// Đường dẫn ảnh do ĐT camera đặt: <cổng>/<ngày>/<mili giây>_<uid>.jpg
final imgPathRe = RegExp(r'^(in|out)/\d{4}-\d{2}-\d{2}/\d+_[0-9A-F]+\.jpg$');
const _imgAudience = 'bgx-img';
const _imgTtl = Duration(hours: 1);

/// Link xem ảnh có chữ ký, hết hạn sau 1 giờ (Image.network trong app không gửi kèm token đăng nhập).
String imageUrl(Req req, String path, String jwtSecret) {
  final t = jwtSign({'path': path}, jwtSecret, expiresIn: _imgTtl, audience: _imgAudience);
  // Render đứng sau proxy: giao thức thật nằm ở X-Forwarded-Proto
  final proto = req.header('x-forwarded-proto')?.split(',').first.trim() ?? req.raw.requestedUri.scheme;
  final host = req.header('host') ?? req.raw.requestedUri.authority;
  return '$proto://$host/plates/img?${Uri(queryParameters: {'path': path, 't': t}).query}';
}

/// GET /plates/img: trả ảnh JPEG nếu chữ ký còn hạn và đúng đường dẫn (không cần đăng nhập).
void imageRoutes(Router router, Deps deps) {
  router.get('/plates/img', (req) async {
    final path = str(req.query['path']);
    try {
      if (jwtVerify(str(req.query['t']), deps.jwtSecret, audience: _imgAudience)['path'] != path) throw Exception();
    } catch (_) {
      throw HttpError(403, 'Link ảnh không hợp lệ hoặc đã hết hạn');
    }
    final img = await PlateImage.findOne({'path': path});
    if (img == null) throw HttpError(404, 'Không có ảnh này');
    return Response.ok((img['data'] as BsonBinary).byteList,
        headers: {'content-type': 'image/jpeg', 'cache-control': 'private, max-age=3600'});
  });
}

/// Kết quả Plate Recognizer -> biển có độ tin cậy cao nhất + các phương án đọc khác + loại phương tiện.
Map<String, dynamic> bestPlate(List? results) {
  if (results == null || results.isEmpty) return {'plate': null, 'score': 0, 'candidates': [], 'vehicle': null};
  final best = results.reduce((a, b) => (a['score'] as num) >= (b['score'] as num) ? a : b) as Map;
  final plate = normPlate(best['plate']);
  final candidates = [for (final c in (best['candidates'] as List?) ?? []) normPlate(c['plate'])];
  return {
    'plate': plate, 'score': best['score'], 'candidates': candidates.isNotEmpty ? candidates : [plate],
    'vehicle': (best['vehicle'] as Map?)?['type'],
  };
}

void plateRoutes(Router router, Deps deps) {
  router.post('/plates/recognize', (req) async {
    final image = await req.image(_maxImage);
    if (image.isEmpty) throw HttpError(400, 'Gửi ảnh JPEG trong body với Content-Type: image/jpeg');
    final form = http.MultipartRequest('POST', _plateUrl)
      ..headers['authorization'] = 'Token ${deps.plateToken}'
      ..fields['regions'] = 'vn'
      ..fields['config'] = '{"region":"strict"}' // chỉ nhận kết quả đúng mẫu biển Việt Nam
      ..files.add(http.MultipartFile.fromBytes('upload', image, filename: 'shot.jpg'));
    http.Response upstream;
    try {
      upstream = await http.Response.fromStream(await deps.plateClient.send(form).timeout(_upstreamTimeout));
    } catch (err) {
      throw HttpError(504, 'Không gọi được dịch vụ nhận diện: $err');
    }
    if (upstream.statusCode < 200 || upstream.statusCode >= 300) {
      stderr.writeln('Plate Recognizer ${upstream.statusCode} ${upstream.body}');
      throw HttpError(502, 'Dịch vụ nhận diện lỗi ${upstream.statusCode}');
    }
    return json(bestPlate((jsonDecode(upstream.body) as Map)['results'] as List?));
  });

  // Ảnh biển số lưu trong MongoDB: trả đường dẫn ký có hạn 1 giờ.
  router.get('/plates/url', (req) async {
    final path = str(req.query['path']);
    if (!imgPathRe.hasMatch(path)) throw HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    return json({'url': imageUrl(req, path, deps.jwtSecret)});
  });
}
