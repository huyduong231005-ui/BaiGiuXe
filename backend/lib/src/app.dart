import 'dart:io';

import 'package:shelf/shelf.dart' show Request, Response;

import 'admin.dart';
import 'auth.dart';
import 'customer.dart';
import 'db.dart' show ensureConnected;
import 'deps.dart';
import 'gate.dart';
import 'guards.dart';
import 'http.dart';
import 'lot.dart';
import 'parking.dart';
import 'plates.dart';
import 'reports.dart';
import 'stats.dart';

const _authWindow = Duration(minutes: 15);
const _authMaxRequests = 100;

/// Giới hạn số lần gọi /auth theo IP trong mỗi cửa sổ 15 phút (chống dò mật khẩu / OTP).
Middleware _rateLimit() {
  final hits = <String, (DateTime, int)>{};
  return (req) async {
    final now = DateTime.now();
    if (hits.length > 10000) hits.removeWhere((_, v) => now.difference(v.$1) > _authWindow);
    final (start, n) = hits[req.ip] ?? (now, 0);
    final fresh = now.difference(start) > _authWindow;
    hits[req.ip] = fresh ? (now, 1) : (start, n + 1);
    if (!fresh && n + 1 > _authMaxRequests) throw HttpError(429, 'Gọi quá nhiều lần, hãy thử lại sau ít phút');
  };
}

/// Trang chủ và /docs (Swagger UI), /index.html (danh sách API, số chỗ trống trực tiếp), /openapi.json: file tĩnh trong public/.
Router _staticRoutes() {
  final router = Router();
  Future<Response> file(String name, String type) async {
    final f = File('public/$name');
    if (!await f.exists()) throw HttpError(404, 'Không tìm thấy API');
    return Response.ok(await f.readAsBytes(), headers: {'content-type': type});
  }

  const html = 'text/html; charset=utf-8';
  for (final (path, name) in [('/', 'docs.html'), ('/index.html', 'index.html'), ('/index', 'index.html'),
    ('/docs', 'docs.html'), ('/docs.html', 'docs.html')]) {
    router.get(path, (_) => file(name, html));
  }
  router.get('/openapi.json', (_) => file('openapi.json', 'application/json; charset=utf-8'));
  return router;
}

/// Thứ tự nhóm giữ như bản Express: công khai -> đăng nhập bất kỳ -> /admin -> /me (khách hàng) -> quản lý + admin.
/// MongoDB kết nối sẵn (db.connect) trước khi gọi.
Future<Response> Function(Request) createApp(Deps deps) {
  Middleware auth([List<String> roles = const []]) => requireAuth(deps, roles);

  final public = Router();
  publicRoutes(public);
  imageRoutes(public, deps);
  public.get('/health', (_) => json({'ok': true}));

  final signedIn = Router(guard: auth(), guardAll: false)
    ..get('/me', (req) => json(publicUser(req.user)))
    ..patch('/me', (req) async => json(await updateProfile(req)))
    ..get('/me/attendance', (req) async => json(await meAttendance(req)))
    // Sơ đồ bãi không kèm biển số / chủ xe: cư dân xem ô của mình, khách xem chỗ trống.
    ..get('/lot/map/public', (_) async => json(await lotMap(withPlates: false)))
    ..get('/lot/route', (req) async => json(await routeOf(req)));

  final admin = Router(prefix: '/admin', guard: auth(['admin']));
  adminRoutes(admin);

  // Các API /me/... còn lại là của khách hàng (chủ vé tháng)
  final customer = Router(prefix: '/me', guard: auth(['customer']));
  customerRoutes(customer, deps);

  final staff = Router(guard: auth(['admin', 'manager']));
  viewRoutes(staff, deps);
  manageRoutes(staff);
  guardRoutes(staff);
  plateRoutes(staff, deps);
  reportRoutes(staff);
  requestRoutes(staff);
  gateRoutes(staff);
  lotRoutes(staff);
  statsRoutes(staff);

  return pipeline([_staticRoutes(), authRouter(deps, _rateLimit()), public, signedIn, admin, customer, staff],
      before: ensureConnected);
}
