// Mỗi file test dùng một database riêng trên MongoDB thật (mặc định mongodb://127.0.0.1:27017, đổi bằng biến
// TEST_MONGODB_URI, không kèm tên database), xoá database khi xong; mail và Google được giả lập.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bai_giu_xe_api/src/app.dart';
import 'package:bai_giu_xe_api/src/db.dart';
import 'package:bai_giu_xe_api/src/deps.dart';
import 'package:bai_giu_xe_api/src/rules.dart' show calcFee;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf_io.dart' as shelf_io;

const jwtSecret = 'test-secret';

typedef Res = ({int status, dynamic body});

class Ctx {
  Ctx(this.base, this._server);
  final String base;
  final HttpServer _server;
  final mails = <({String to, String code, String purpose})>[];

  Future<Res> call(String method, String path,
      {String? token, Object? body, List<int>? raw, Map<String, String>? headers}) async {
    final req = http.Request(method, Uri.parse(base + path));
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    req.headers.addAll(headers ?? {});
    if (raw != null) req.bodyBytes = raw;
    final res = await http.Response.fromStream(await req.send());
    return (status: res.statusCode, body: res.body.isEmpty ? null : jsonDecode(res.body));
  }

  Future<void> close() async {
    await _server.close(force: true);
    await db.drop();
    await db.close();
  }
}

/// App + server thật trên cổng ngẫu nhiên.
Future<Ctx> startApp({VerifyGoogle? verifyGoogle, http.Client? plateClient}) async {
  // Phí qua đêm, ngày doanh thu... tính theo giờ Việt Nam; chạy test với TZ=Asia/Ho_Chi_Minh nếu máy ở múi khác.
  if (DateTime.now().timeZoneOffset != const Duration(hours: 7)) {
    throw StateError('Test cần múi giờ Việt Nam (UTC+7): đặt TZ=Asia/Ho_Chi_Minh');
  }
  final uri = Platform.environment['TEST_MONGODB_URI'] ?? 'mongodb://127.0.0.1:27017';
  await connect('$uri/bgx_test_${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(1 << 30)}');
  await initDb();
  late Ctx ctx;
  final app = createApp(Deps(
    jwtSecret: jwtSecret,
    sendMail: (to, code, purpose) async => ctx.mails.add((to: to, code: code, purpose: purpose)),
    verifyGoogle: verifyGoogle ?? (_) async => throw Exception('không dùng'),
    plateToken: 'plate-token',
    plateClient: plateClient,
  ));
  final server = await shelf_io.serve(app, InternetAddress.loopbackIPv4, 0);
  return ctx = Ctx('http://127.0.0.1:${server.port}', server);
}

/// Tạo tài khoản đã kích hoạt với vai trò cho trước và trả về JWT (qua đúng luồng OTP).
Future<String> loginAs(Ctx ctx, String role, [String? name]) async {
  final username = name ?? role;
  final email = '$username@test.vn';
  await ctx.call('POST', '/auth/register', body: {'email': email, 'username': username, 'password': 'matkhau1'});
  final reg = ctx.mails.lastWhere((m) => m.to == email);
  final res = await ctx.call('POST', '/auth/register/verify', body: {'email': email, 'code': reg.code});
  if (role != 'customer') await User.updateOne({'username': username}, {'role': role});
  return res.body['token'];
}

DateTime ago(num hours) => DateTime.now().subtract(Duration(milliseconds: (hours * 3600e3).round()));

/// Phí xe máy (giá mặc định) nếu xe vào lúc timeIn và ra bây giờ: test chạy sau 22:00 thì lượt vào vài giờ trước đã qua
/// mốc đêm, tính giá đêm.
int motorbikeFeeSince(DateTime timeIn) =>
    calcFee(timeIn, DateTime.now(), const {'price_day': 5000, 'price_night': 10000, 'night_mark': '22:00:00'});
