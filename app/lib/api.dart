import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// REST API đã deploy (thư mục backend/). Đổi khi build: --dart-define=API_URL=https://...
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'https://baigiuxe.onrender.com');

/// Web client ID của Google Cloud (trùng GOOGLE_CLIENT_ID ở backend). Không phải bí mật.
const googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '75402119088-8aukujb89r7m96koo09lcig17hl6fo1e.apps.googleusercontent.com',
);

class ApiException implements Exception {
  ApiException(this.message, [this.status]);
  final String message;
  final int? status;

  @override
  String toString() => message;
}

class ApiUser {
  ApiUser.fromJson(Map<String, dynamic> j)
      : id = j['id'] as int?,
        username = j['username'] as String,
        email = j['email'] as String,
        fullName = j['fullName'] as String? ?? '',
        role = j['role'] as String,
        guardId = j['guardId'] as int?;

  final int? id;
  final String username, email, fullName;
  final String role; // admin | manager | guard | customer (chủ vé tháng)
  final int? guardId;

  bool get isStaff => role == 'admin' || role == 'manager';
  bool get isCustomer => role == 'customer';
  String get displayName => fullName.isEmpty ? username : fullName;
}

class Api {
  Api({http.Client? client}) : _client = client ?? http.Client();

  static const _tokenKey = 'api_token', _userKey = 'api_user';
  // Render free ngủ sau 15 phút, lần gọi đầu có thể mất ~50 giây để thức dậy.
  static const _timeout = Duration(seconds: 70);

  final http.Client _client;
  String? _token;
  SharedPreferences? _prefs;

  /// Người đang đăng nhập (null = chưa).
  final session = ValueNotifier<ApiUser?>(null);

  /// Mở app: lấy lại phiên đã lưu, không gọi mạng (API có thể đang ngủ). Token hết hạn -> 401 -> đăng xuất.
  void restore(SharedPreferences prefs) {
    _prefs = prefs;
    _token = prefs.getString(_tokenKey);
    final user = prefs.getString(_userKey);
    if (_token != null && user != null) session.value = ApiUser.fromJson(jsonDecode(user) as Map<String, dynamic>);
  }

  Future<dynamic> get(String path, [Map<String, String>? query]) => _send('GET', path, query: query);
  Future<dynamic> post(String path, [Map<String, dynamic>? body]) => _send('POST', path, body: body ?? const {});
  Future<dynamic> put(String path, Map<String, dynamic> body) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, Map<String, dynamic> body) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  /// Tải file nhị phân (báo cáo Excel).
  Future<Uint8List> getBytes(String path, [Map<String, String>? query]) async =>
      await _send('GET', path, query: query, raw: true) as Uint8List;

  /// Gửi ảnh JPEG (nhận diện biển số, tải ảnh lượt quẹt lên).
  Future<dynamic> postJpeg(String path, Uint8List jpg, {Duration timeout = _timeout}) =>
      _send('POST', path, jpeg: jpg, timeout: timeout);
  Future<dynamic> putJpeg(String path, Uint8List jpg, Map<String, String> query) =>
      _send('PUT', path, jpeg: jpg, query: query);

  /// Gọi API với thời hạn riêng (ĐT camera: ESP32 chỉ chờ kết quả 12 giây).
  Future<dynamic> postWithin(String path, Map<String, dynamic> body, Duration timeout) =>
      _send('POST', path, body: body, timeout: timeout);

  Future<dynamic> _send(String method, String path,
      {Map<String, dynamic>? body,
      Map<String, String>? query,
      Uint8List? jpeg,
      Duration timeout = _timeout,
      bool raw = false}) async {
    var uri = Uri.parse('$apiUrl$path');
    if (query != null) uri = uri.replace(queryParameters: query);
    final req = http.Request(method, uri);
    if (_token != null) req.headers['authorization'] = 'Bearer $_token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    if (jpeg != null) {
      req.headers['content-type'] = 'image/jpeg';
      req.bodyBytes = jpeg;
    }

    final http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout));
    } on TimeoutException {
      throw ApiException('Máy chủ phản hồi quá lâu, hãy thử lại');
    } on http.ClientException {
      throw ApiException('Không kết nối được máy chủ, kiểm tra mạng');
    }

    if (raw && res.statusCode < 400) return res.bodyBytes;
    dynamic data;
    try {
      // JSON luôn là UTF-8; không dùng res.body vì thiếu charset thì http giải mã latin1.
      if (res.bodyBytes.isNotEmpty) data = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      data = null;
    }
    if (res.statusCode >= 400) {
      final message = (data is Map ? data['message'] as String? : null) ?? 'Lỗi máy chủ (${res.statusCode})';
      // Token API hết hạn / tài khoản bị khoá: về màn đăng nhập.
      if (res.statusCode == 401 && _token != null && !path.startsWith('/auth')) await logout();
      throw ApiException(message, res.statusCode);
    }
    return data;
  }

  Future<ApiUser> _saveSession(dynamic data) async {
    _token = data['token'] as String;
    final user = data['user'] as Map<String, dynamic>;
    await _prefs?.setString(_tokenKey, _token!);
    await _prefs?.setString(_userKey, jsonEncode(user));
    return session.value = ApiUser.fromJson(user);
  }

  /// Trả về email đã che (VD: h***@gmail.com) để hiện ở màn OTP.
  Future<String> register({required String email, required String username, required String password, required String fullName}) async =>
      (await post('/auth/register', {'email': email, 'username': username, 'password': password, 'fullName': fullName}))['email']
          as String;

  Future<ApiUser> verifyRegister(String email, String code) async =>
      _saveSession(await post('/auth/register/verify', {'email': email, 'code': code}));

  Future<String> login(String username, String password) async =>
      (await post('/auth/login', {'username': username, 'password': password}))['email'] as String;

  Future<ApiUser> verifyLogin(String username, String code) async =>
      _saveSession(await post('/auth/login/verify', {'username': username, 'code': code}));

  Future<ApiUser> loginWithGoogle(String idToken) async => _saveSession(await post('/auth/google', {'idToken': idToken}));

  /// Sửa hồ sơ của chính mình (PATCH /me) rồi cập nhật phiên đang lưu.
  Future<ApiUser> updateProfile(Map<String, dynamic> changes) async {
    final user = await patch('/me', changes) as Map<String, dynamic>;
    await _prefs?.setString(_userKey, jsonEncode(user));
    return session.value = ApiUser.fromJson(user);
  }

  Future<void> logout() async {
    _token = null;
    session.value = null;
    await _prefs?.remove(_tokenKey);
    await _prefs?.remove(_userKey);
  }
}

// Test thay bằng Api(client: MockClient(...)) để không gọi mạng thật.
var api = Api();
