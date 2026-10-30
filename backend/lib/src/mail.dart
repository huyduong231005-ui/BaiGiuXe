// Gửi email qua Brevo HTTP API (Render free chặn cổng SMTP nên không dùng Gmail SMTP được).
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'deps.dart';

final _brevoUrl = Uri.parse('https://api.brevo.com/v3/smtp/email');

const _subjects = {
  'register': 'Mã xác minh đăng ký tài khoản',
  'login': 'Mã OTP đăng nhập',
};

SendMail brevoMailer({required String apiKey, required String from}) => (to, code, purpose) async {
      final res = await http.post(_brevoUrl,
          headers: {'api-key': apiKey, 'content-type': 'application/json'},
          body: jsonEncode({
            'sender': {'email': from, 'name': 'Bãi giữ xe'},
            'to': [
              {'email': to}
            ],
            // Mã đặt đầu tiêu đề: mỗi thư một tiêu đề nên Gmail không gộp vào luồng cũ và thấy mã ngay ở thông báo.
            'subject': '$code – ${_subjects[purpose]}',
            'htmlContent': '<p>Mã OTP của bạn là:</p><h2 style="letter-spacing:4px">$code</h2>'
                '<p>Mã có hiệu lực trong 5 phút. Không chia sẻ mã này cho ai.</p>',
          }));
      if (res.statusCode < 200 || res.statusCode >= 300) throw Exception('Brevo ${res.statusCode}: ${res.body}');
    };

/// Kiểm idToken của Google Sign-In.
/// shortcut: hỏi endpoint tokeninfo của Google (Google tự kiểm chữ ký + hạn), thêm 1 lượt gọi mạng mỗi lần đăng nhập;
/// tự kiểm chữ ký bằng khoá JWKS của Google nếu lượng đăng nhập Google lớn.
VerifyGoogle googleVerifier(String clientId) => (idToken) async {
      final res = await http.get(Uri.https('oauth2.googleapis.com', '/tokeninfo', {'id_token': idToken}));
      if (res.statusCode != 200) throw Exception('Google tokeninfo ${res.statusCode}');
      final p = jsonDecode(res.body) as Map<String, dynamic>;
      if (p['aud'] != clientId || !const ['accounts.google.com', 'https://accounts.google.com'].contains(p['iss'])) {
        throw Exception('Token Google không dành cho app này');
      }
      return {...p, 'email_verified': p['email_verified'] == true || p['email_verified'] == 'true'};
    };
