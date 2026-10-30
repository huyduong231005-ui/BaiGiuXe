import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';

import 'db.dart';
import 'deps.dart';
import 'http.dart';
import 'jwt.dart';

const _otpTtl = Duration(minutes: 5);
const _otpResend = Duration(seconds: 30); // chống spam email / đốt hạn mức 300 mail/ngày của Brevo
const _otpMaxAttempts = 5;
const _tokenTtl = Duration(days: 7);
const roles = ['admin', 'manager', 'guard', 'customer'];
final emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final usernameRe = RegExp(r'^[a-z0-9_.]{3,30}$');
const minPassword = 6;
const _maxFullname = 100;
final _random = Random.secure();

String _sha256(String s) => sha256.convert(utf8.encode(s)).toString();
String _maskEmail(String email) => email.replaceFirstMapped(RegExp(r'^(.).*(@.*)$'), (m) => '${m[1]}***${m[2]}');
String _pass(Object? v) => v is String ? v : '';

// bcrypt chạy ở isolate riêng: ~100ms mỗi lần, không chặn các request khác.
Future<String> hashPassword(String s) => Isolate.run(() => BCrypt.hashpw(s, BCrypt.gensalt(logRounds: 10)));
Future<bool> checkPassword(String s, String hash) => Isolate.run(() {
      try {
        return BCrypt.checkpw(s, hash);
      } catch (_) {
        return false; // hash hỏng
      }
    });

/// Dữ liệu tài khoản trả cho client (không bao giờ kèm hash mật khẩu).
Map<String, dynamic> publicUser(Map u) => {
      'id': u['id'], 'username': u['username'], 'email': u['email'], 'fullName': u['full_name'], 'role': u['role'],
      'guardId': u['guard_id'], 'active': u['active'],
    };

String signToken(Map user, String jwtSecret) =>
    jwtSign({'sub': user['id'], 'role': user['role']}, jwtSecret, expiresIn: _tokenTtl);

/// Kiểm token và nạp người dùng từ DB (đổi vai trò / khoá có hiệu lực ngay), kiểm vai trò nếu có truyền.
Middleware requireAuth(Deps deps, [List<String> allowed = const []]) => (req) async {
      final token = (req.header('authorization') ?? '').replaceFirst(RegExp('^Bearer '), '');
      Object? sub;
      try {
        sub = jwtVerify(token, deps.jwtSecret)['sub'];
      } catch (_) {
        throw HttpError(401, 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn');
      }
      final user = row(await User.findById(sub is num ? sub : pathId('$sub')));
      if (user?['active'] != true) throw HttpError(401, 'Tài khoản không còn hoạt động');
      if (allowed.isNotEmpty && !allowed.contains(user!['role'])) throw HttpError(403, 'Bạn không có quyền làm việc này');
      req.user = user!;
    };

/// PATCH /me: tự đổi họ tên và mật khẩu (phải nhập đúng mật khẩu hiện tại).
Future<Map<String, dynamic>> updateProfile(Req req) async {
  final user = req.user;
  var fullName = user['full_name'];
  var hash = user['password_hash'] as String?;
  if (req.has('fullName')) {
    fullName = str(req.b('fullName'));
    if (fullName == '' || fullName.length > _maxFullname) throw HttpError(400, 'Họ tên 1–$_maxFullname ký tự');
  }
  final newPassword = _pass(req.b('newPassword'));
  if (newPassword.isNotEmpty) {
    if (newPassword.length < minPassword) throw HttpError(400, 'Mật khẩu mới tối thiểu $minPassword ký tự');
    // Tài khoản tạo bằng Google chưa có mật khẩu thì cho đặt mới luôn
    if (hash != null && !(await checkPassword(_pass(req.b('currentPassword')), hash))) {
      throw HttpError(400, 'Mật khẩu hiện tại không đúng');
    }
    hash = await hashPassword(newPassword);
  }
  return publicUser((await setUser(user['id'], {'full_name': fullName, 'password_hash': hash}))!);
}

/// Sửa tài khoản, trả về dòng mới (null nếu không có).
Future<Map<String, dynamic>?> setUser(Object? id, Map<String, dynamic> changes) async =>
    row(await User.findByIdAndUpdate(id, changes));

Future<Map<String, dynamic>?> _findUser(Map<String, dynamic> filter) async => row(await User.findOne(filter));

Router authRouter(Deps deps, Middleware rateLimit) {
  final router = Router(prefix: '/auth', guard: rateLimit);
  Map<String, dynamic> session(Map user) => {'token': signToken(user, deps.jwtSecret), 'user': publicUser(user)};
  Map<String, dynamic> otpOf(Map user, String purpose) => {'user_id': user['id'], 'purpose': purpose};

  Future<void> issueOtp(Map user, String purpose) async {
    final last = await Otp.findOne(otpOf(user, purpose));
    final waitMs = last == null
        ? 0
        : (last['expires_at'] as DateTime).subtract(_otpTtl).add(_otpResend).difference(DateTime.now()).inMilliseconds;
    if (waitMs > 0) throw HttpError(429, 'Vui lòng đợi ${(waitMs / 1000).ceil()} giây rồi gửi lại mã');
    final code = _random.nextInt(1000000).toString().padLeft(6, '0');
    await Otp.updateOne(otpOf(user, purpose),
        {'code_hash': _sha256(code), 'attempts': 0, 'expires_at': DateTime.now().add(_otpTtl)}, upsert: true);
    try {
      await deps.sendMail(user['email'], code, purpose);
    } catch (err) {
      stderr.writeln('Gửi email OTP lỗi: $err');
      throw HttpError(502, 'Không gửi được email OTP, hãy thử lại');
    }
  }

  Future<void> consumeOtp(Map user, String purpose, Object? code) async {
    final otp = await Otp.findOne(otpOf(user, purpose));
    if (otp == null || (otp['expires_at'] as DateTime).isBefore(DateTime.now())) {
      throw HttpError(400, 'Mã OTP đã hết hạn, hãy gửi lại mã mới');
    }
    if (otp['code_hash'] != _sha256(str(code))) {
      if ((otp['attempts'] as num) + 1 >= _otpMaxAttempts) {
        await Otp.deleteOne(otpOf(user, purpose));
        throw HttpError(400, 'Nhập sai quá nhiều lần, hãy gửi lại mã mới');
      }
      await Otp.updateOne(otpOf(user, purpose), {r'$inc': {'attempts': 1}});
      throw HttpError(400, 'Mã OTP không đúng');
    }
    await Otp.deleteOne(otpOf(user, purpose));
  }

  // Tài khoản tự đăng ký là khách hàng (chủ vé tháng); quản lý / bảo vệ do admin cấp quyền.
  router.post('/auth/register', (req) async {
    final email = str(req.b('email')).toLowerCase();
    final username = str(req.b('username')).toLowerCase();
    final fullName = cut(str(req.b('fullName')), _maxFullname);
    final password = _pass(req.b('password'));
    if (!emailRe.hasMatch(email)) throw HttpError(400, 'Email không hợp lệ');
    if (!usernameRe.hasMatch(username)) throw HttpError(400, 'Tên đăng nhập 3–30 ký tự: chữ thường, số, dấu _ hoặc .');
    if (password.length < minPassword) throw HttpError(400, 'Mật khẩu tối thiểu $minPassword ký tự');

    final existing = await _findUser({
      r'$or': [{'email': email}, {'username': username}]
    });
    // Đăng ký lại khi chưa xác minh (VD: mất mã OTP) thì cho cập nhật và gửi mã mới.
    final isRetry =
        existing != null && existing['active'] != true && existing['email'] == email && existing['username'] == username;
    if (existing != null && !isRetry) throw HttpError(409, 'Tên đăng nhập hoặc email đã được dùng');
    final hash = await hashPassword(password);
    final user = isRetry
        ? (await setUser(existing['id'], {'full_name': fullName, 'password_hash': hash}))!
        : await User.insert({'email': email, 'username': username, 'full_name': fullName, 'password_hash': hash});
    await issueOtp(user, 'register');
    return json({'message': 'Đã gửi mã OTP tới email', 'email': _maskEmail(email)}, 201);
  });

  router.post('/auth/register/verify', (req) async {
    final user = await _findUser({'email': str(req.b('email')).toLowerCase()});
    if (user == null || user['active'] == true) {
      throw HttpError(400, 'Không có tài khoản nào đang chờ xác minh với email này');
    }
    await consumeOtp(user, 'register', req.b('code'));
    return json(session((await setUser(user['id'], {'active': true}))!));
  });

  router.post('/auth/login', (req) async {
    final user = await _findUser({'username': str(req.b('username')).toLowerCase()});
    final hash = user?['password_hash'];
    final ok = hash is String && hash.isNotEmpty && await checkPassword(_pass(req.b('password')), hash);
    if (!ok) throw HttpError(401, 'Sai tên đăng nhập hoặc mật khẩu');
    if (user!['active'] != true) throw HttpError(403, 'Tài khoản chưa xác minh email');
    await issueOtp(user, 'login');
    return json({'message': 'Đã gửi mã OTP tới email', 'email': _maskEmail(user['email'])});
  });

  router.post('/auth/login/verify', (req) async {
    final user = await _findUser({'username': str(req.b('username')).toLowerCase()});
    if (user?['active'] != true) throw HttpError(400, 'Tài khoản không hợp lệ');
    await consumeOtp(user!, 'login', req.b('code'));
    return json(session(user));
  });

  // OAuth2: app gửi idToken lấy từ Google Sign-In, backend tự xác thực với Google.
  router.post('/auth/google', (req) async {
    Map? payload;
    try {
      payload = await deps.verifyGoogle(str(req.b('idToken')));
    } catch (_) {
      throw HttpError(401, 'Token Google không hợp lệ');
    }
    if (payload?['email_verified'] != true) throw HttpError(400, 'Email Google chưa được xác minh');
    final email = (payload!['email'] as String).toLowerCase();
    var user = await _findUser({
      r'$or': [{'google_id': payload['sub']}, {'email': email}]
    });
    if (user == null) {
      final base = cut(email.split('@')[0].toLowerCase().replaceAll(RegExp(r'[^a-z0-9_.]'), ''), 24).padRight(3, '0');
      final taken = await User.exists({'username': base});
      user = await User.insert({'email': email, 'username': taken ? '${base}_${1000 + _random.nextInt(9000)}' : base});
    }
    // Google đã xác minh email nên kích hoạt luôn
    final name = truthy(user['full_name']) ? user['full_name'] : (truthy(payload['name']) ? payload['name'] : '');
    user = await setUser(user['id'], {'google_id': payload['sub'], 'active': true, 'full_name': name});
    return json(session(user!));
  });

  return router;
}
