import 'package:http/http.dart' as http;

typedef SendMail = Future<void> Function(String to, String code, String purpose);

/// Payload của idToken Google (sub, email, email_verified, name); token sai thì ném lỗi.
typedef VerifyGoogle = Future<Map?> Function(String idToken);

/// Phụ thuộc bên ngoài của API; test thay bằng bản giả.
class Deps {
  Deps({
    required this.jwtSecret,
    required this.sendMail,
    required this.verifyGoogle,
    required this.plateToken,
    http.Client? plateClient,
  }) : plateClient = plateClient ?? http.Client();

  final String jwtSecret;
  final SendMail sendMail;
  final VerifyGoogle verifyGoogle;
  final String plateToken;

  /// Gọi Plate Recognizer.
  final http.Client plateClient;
}
