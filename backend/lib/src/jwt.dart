// JWT HS256 tự viết (vài chục dòng) thay cho jsonwebtoken: cùng định dạng nên token cũ vẫn dùng được sau khi đổi sang Dart.
import 'dart:convert';

import 'package:crypto/crypto.dart';

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
List<int> _unb64(String s) => base64Url.decode(base64Url.normalize(s));
List<int> _sign(String data, String secret) => Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(data)).bytes;

int _nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String jwtSign(Map<String, Object?> payload, String secret, {required Duration expiresIn, String? audience}) {
  final iat = _nowSec();
  final head = _b64(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final body = _b64(utf8.encode(jsonEncode(
      {...payload, 'iat': iat, 'exp': iat + expiresIn.inSeconds, 'aud': ?audience})));
  return '$head.$body.${_b64(_sign('$head.$body', secret))}';
}

/// Kiểm chữ ký, hạn dùng, audience (nếu truyền). Sai thì ném FormatException.
Map<String, dynamic> jwtVerify(String token, String secret, {String? audience}) {
  final parts = token.split('.');
  if (parts.length != 3) throw const FormatException('jwt malformed');
  final header = jsonDecode(utf8.decode(_unb64(parts[0])));
  if (header is! Map || header['alg'] != 'HS256') throw const FormatException('invalid algorithm');
  final expected = _sign('${parts[0]}.${parts[1]}', secret);
  final got = _unb64(parts[2]);
  var diff = expected.length ^ got.length;
  for (var i = 0; i < expected.length && i < got.length; i++) {
    diff |= expected[i] ^ got[i];
  }
  if (diff != 0) throw const FormatException('invalid signature');
  final payload = jsonDecode(utf8.decode(_unb64(parts[1])));
  if (payload is! Map<String, dynamic>) throw const FormatException('invalid payload');
  final now = _nowSec();
  if (payload['exp'] is num && now >= (payload['exp'] as num)) throw const FormatException('jwt expired');
  if (payload['nbf'] is num && now < (payload['nbf'] as num)) throw const FormatException('jwt not active');
  if (audience != null) {
    final aud = payload['aud'];
    if (!(aud == audience || (aud is List && aud.contains(audience)))) throw const FormatException('jwt audience invalid');
  }
  return payload;
}
