import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { loginAs, startApp } from './helpers.js';

let ctx;
before(async () => {
  ctx = await startApp({
    verifyGoogle: async (t) => (t === 'good' ? { sub: 'g-1', email: 'Lan@Gmail.com', email_verified: true, name: 'Lan' } : null),
    verifySupabase: async (t) => (t === 'supabase-staff' ? { email: 'camera@bai.vn' } : null),
  });
});
after(() => ctx.close());

test('đăng ký -> OTP qua email -> xác minh -> đăng nhập 2 bước bằng OTP', async () => {
  const r = await ctx.call('POST', '/auth/register', { body: { email: 'huy@test.vn', username: 'huy', password: 'matkhau1' } });
  assert.equal(r.status, 201);
  assert.equal(r.body.email, 'h***@test.vn');
  const otp = ctx.mails.at(-1);
  assert.equal(otp.purpose, 'register');

  assert.equal((await ctx.call('POST', '/auth/register/verify', { body: { email: 'huy@test.vn', code: '000000' } })).status, 400);
  const v = await ctx.call('POST', '/auth/register/verify', { body: { email: 'huy@test.vn', code: otp.code } });
  assert.equal(v.status, 200);
  assert.equal(v.body.user.role, 'guard');

  assert.equal((await ctx.call('POST', '/auth/login', { body: { username: 'huy', password: 'sai' } })).status, 401);
  assert.equal((await ctx.call('POST', '/auth/login', { body: { username: 'huy', password: 'matkhau1' } })).status, 200);
  const code = ctx.mails.at(-1).code;
  const l = await ctx.call('POST', '/auth/login/verify', { body: { username: 'huy', code } });
  assert.equal(l.status, 200);
  const me = await ctx.call('GET', '/me', { token: l.body.token });
  assert.equal(me.body.username, 'huy');
  assert.equal(me.body.password_hash, undefined);
  // Mã đã dùng thì không dùng lại được
  assert.equal((await ctx.call('POST', '/auth/login/verify', { body: { username: 'huy', code } })).status, 400);
});

test('chặn gửi lại OTP trong 30 giây và trùng tên đăng nhập', async () => {
  await ctx.call('POST', '/auth/register', { body: { email: 'a@test.vn', username: 'aaa', password: 'matkhau1' } });
  const again = await ctx.call('POST', '/auth/register', { body: { email: 'a@test.vn', username: 'aaa', password: 'matkhau1' } });
  assert.equal(again.status, 429);
  const dup = await ctx.call('POST', '/auth/register', { body: { email: 'b@test.vn', username: 'aaa', password: 'matkhau1' } });
  assert.equal(dup.status, 409);
});

test('đăng nhập Google tạo tài khoản đã kích hoạt', async () => {
  assert.equal((await ctx.call('POST', '/auth/google', { body: { idToken: 'bad' } })).status, 400);
  const r = await ctx.call('POST', '/auth/google', { body: { idToken: 'good' } });
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.user.username, r.body.user.email, r.body.user.active], ['lan', 'lan@gmail.com', true]);
});

test('phân quyền: bảo vệ không xem được lịch sử, quản lý không vào /admin', async () => {
  const guard = await loginAs(ctx, 'guard', 'baove1');
  const manager = await loginAs(ctx, 'manager', 'quanly1');
  assert.equal((await ctx.call('GET', '/sessions', { token: guard })).status, 403);
  assert.equal((await ctx.call('GET', '/sessions', { token: manager })).status, 200);
  assert.equal((await ctx.call('GET', '/admin/users', { token: manager })).status, 403);
  assert.equal((await ctx.call('GET', '/sessions')).status, 401);
});

test('token Supabase của ĐT camera (staff) dùng được như quản lý', async () => {
  const me = await ctx.call('GET', '/me', { token: 'supabase-staff' });
  assert.deepEqual([me.body.role, me.body.device], ['manager', true]);
  assert.equal((await ctx.call('GET', '/cards', { token: 'supabase-staff' })).status, 200);
  assert.equal((await ctx.call('GET', '/cards', { token: 'supabase-khac' })).status, 401);
});

test('admin đổi vai trò, không tự hạ quyền mình', async () => {
  const admin = await loginAs(ctx, 'admin', 'admin1');
  const users = (await ctx.call('GET', '/admin/users?q=baove1', { token: admin })).body;
  const r = await ctx.call('PATCH', `/admin/users/${users[0].id}`, { token: admin, body: { role: 'manager' } });
  assert.equal(r.body.role, 'manager');
  const self = (await ctx.call('GET', '/me', { token: admin })).body;
  assert.equal((await ctx.call('PATCH', `/admin/users/${self.id}`, { token: admin, body: { role: 'guard' } })).status, 400);
});
