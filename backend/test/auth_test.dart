import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Ctx ctx;
  setUpAll(() async => ctx = await startApp(
      verifyGoogle: (t) async =>
          t == 'good' ? {'sub': 'g-1', 'email': 'Lan@Gmail.com', 'email_verified': true, 'name': 'Lan'} : null));
  tearDownAll(() => ctx.close());

  test('đăng ký -> OTP qua email -> xác minh -> đăng nhập 2 bước bằng OTP', () async {
    final r = await ctx.call('POST', '/auth/register', body: {'email': 'huy@test.vn', 'username': 'huy', 'password': 'matkhau1'});
    expect(r.status, 201);
    expect(r.body['email'], 'h***@test.vn');
    final otp = ctx.mails.last;
    expect(otp.purpose, 'register');

    expect((await ctx.call('POST', '/auth/register/verify', body: {'email': 'huy@test.vn', 'code': '000000'})).status, 400);
    final v = await ctx.call('POST', '/auth/register/verify', body: {'email': 'huy@test.vn', 'code': otp.code});
    expect(v.status, 200);
    expect(v.body['user']['role'], 'customer'); // tự đăng ký = khách hàng (chủ vé tháng)

    expect((await ctx.call('POST', '/auth/login', body: {'username': 'huy', 'password': 'sai'})).status, 401);
    expect((await ctx.call('POST', '/auth/login', body: {'username': 'huy', 'password': 'matkhau1'})).status, 200);
    final code = ctx.mails.last.code;
    final l = await ctx.call('POST', '/auth/login/verify', body: {'username': 'huy', 'code': code});
    expect(l.status, 200);
    final me = await ctx.call('GET', '/me', token: l.body['token']);
    expect(me.body['username'], 'huy');
    expect((me.body as Map).containsKey('password_hash'), isFalse);
    // Mã đã dùng thì không dùng lại được
    expect((await ctx.call('POST', '/auth/login/verify', body: {'username': 'huy', 'code': code})).status, 400);
  });

  test('chặn gửi lại OTP trong 30 giây và trùng tên đăng nhập', () async {
    await ctx.call('POST', '/auth/register', body: {'email': 'a@test.vn', 'username': 'aaa', 'password': 'matkhau1'});
    final again = await ctx.call('POST', '/auth/register', body: {'email': 'a@test.vn', 'username': 'aaa', 'password': 'matkhau1'});
    expect(again.status, 429);
    final dup = await ctx.call('POST', '/auth/register', body: {'email': 'b@test.vn', 'username': 'aaa', 'password': 'matkhau1'});
    expect(dup.status, 409);
  });

  test('đăng nhập Google tạo tài khoản đã kích hoạt', () async {
    expect((await ctx.call('POST', '/auth/google', body: {'idToken': 'bad'})).status, 400);
    final r = await ctx.call('POST', '/auth/google', body: {'idToken': 'good'});
    expect(r.status, 200);
    expect([r.body['user']['username'], r.body['user']['email'], r.body['user']['active']], ['lan', 'lan@gmail.com', true]);
  });

  test('phân quyền: bảo vệ không xem được lịch sử, quản lý không vào /admin', () async {
    final guard = await loginAs(ctx, 'guard', 'baove1');
    final manager = await loginAs(ctx, 'manager', 'quanly1');
    expect((await ctx.call('GET', '/sessions', token: guard)).status, 403);
    expect((await ctx.call('GET', '/sessions', token: manager)).status, 200);
    expect((await ctx.call('GET', '/admin/users', token: manager)).status, 403);
    expect((await ctx.call('GET', '/sessions')).status, 401);
    expect((await ctx.call('GET', '/khong-co', token: manager)).status, 404);
  });

  test('token giả / sai chữ ký bị từ chối; JSON hỏng trả 400', () async {
    expect((await ctx.call('GET', '/cards', token: 'khong-phai-jwt')).status, 401);
    final bad = await ctx.call('POST', '/auth/login', raw: '{"x":'.codeUnits, headers: {'content-type': 'application/json'});
    expect([bad.status, bad.body['message']], [400, 'Dữ liệu không hợp lệ']);
  });

  test('admin đổi vai trò, không tự hạ quyền mình', () async {
    final admin = await loginAs(ctx, 'admin', 'admin1');
    final users = (await ctx.call('GET', '/admin/users?q=baove1', token: admin)).body;
    final r = await ctx.call('PATCH', '/admin/users/${users[0]['id']}', token: admin, body: {'role': 'manager'});
    expect(r.body['role'], 'manager');
    final self = (await ctx.call('GET', '/me', token: admin)).body;
    expect((await ctx.call('PATCH', '/admin/users/${self['id']}', token: admin, body: {'role': 'guard'})).status, 400);
  });
}
