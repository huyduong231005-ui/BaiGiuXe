// Quản trị tài khoản API: xem, đổi vai trò, khoá, gắn với hồ sơ bảo vệ, xoá.
import 'auth.dart';
import 'db.dart';
import 'http.dart';

/// Các API /admin/... (đã kiểm vai trò admin ở app.dart).
void adminRoutes(Router router) {
  // Admin tạo sẵn tài khoản (quản lý, bảo vệ, khách vé tháng) đã kích hoạt, không cần OTP đăng ký.
  router.post('/admin/users', (req) async {
    final email = str(req.b('email')).toLowerCase();
    final username = str(req.b('username')).toLowerCase();
    final password = req.b('password') is String ? req.b('password') as String : '';
    final role = req.b('role') ?? 'customer';
    if (!emailRe.hasMatch(email)) throw HttpError(400, 'Email không hợp lệ');
    if (!usernameRe.hasMatch(username)) throw HttpError(400, 'Tên đăng nhập 3–30 ký tự: chữ thường, số, dấu _ hoặc .');
    if (password.length < minPassword) throw HttpError(400, 'Mật khẩu tối thiểu $minPassword ký tự');
    if (!roles.contains(role)) throw HttpError(400, 'Vai trò là một trong: ${roles.join(', ')}');
    final user = await User.insert({
      'email': email, 'username': username, 'full_name': str(req.b('fullName')),
      'password_hash': await hashPassword(password), 'role': role, 'guard_id': asInt(req.b('guardId')), 'active': true,
    });
    return json(publicUser(user), 201);
  });

  router.get('/admin/users', (req) async {
    final q = containsText(str(req.query['q']));
    final role = str(req.query['role']);
    final users = await User.find({
      r'$or': [{'username': q}, {'email': q}, {'full_name': q}],
      if (role.isNotEmpty) 'role': role,
    }, {'_id': 1});
    return json([for (final u in users) publicUser(row(u)!)]);
  });

  router.patch('/admin/users/:id', (req) async {
    final id = pathId(req.params['id']!);
    final user = row(await User.findById(id));
    if (user == null) throw HttpError(404, 'Không có tài khoản này');
    final role = req.b('role') ?? user['role'];
    if (!roles.contains(role)) throw HttpError(400, 'Vai trò là một trong: ${roles.join(', ')}');
    if (id == req.user['id'] && (role != 'admin' || req.b('active') == false)) {
      throw HttpError(400, 'Không tự hạ quyền hoặc tự khoá tài khoản admin đang dùng');
    }
    final guardId = req.has('guardId') ? req.b('guardId') : user['guard_id'];
    if (guardId != null && asInt(guardId) == null) throw HttpError(400, 'guardId là số hoặc null');
    return json(publicUser((await setUser(id, {
      'role': role, 'active': req.b('active') is bool ? req.b('active') : user['active'], 'guard_id': asInt(guardId),
      'full_name': req.has('fullName') ? str(req.b('fullName')) : user['full_name'],
    }))!));
  });

  // Như khoá ngoại cũ: xoá mã OTP và đơn vé tháng của tài khoản, thẻ / đơn đã duyệt bỏ liên kết.
  router.delete('/admin/users/:id', (req) async {
    final id = pathId(req.params['id']!);
    if (id == req.user['id']) throw HttpError(400, 'Không tự xoá tài khoản đang dùng');
    if (await User.deleteOne({'_id': id}) == 0) throw HttpError(404, 'Không có tài khoản này');
    await [
      Otp.deleteMany({'user_id': id}),
      TicketRequest.deleteMany({'user_id': id}),
      TicketRequest.updateMany({'handled_by': id}, {'handled_by': null}).then((_) => 0),
      Card.updateMany({'user_id': id}, {'user_id': null}).then((_) => 0),
    ].wait;
    return noContent();
  });
}
