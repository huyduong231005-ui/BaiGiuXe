import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { ago, loginAs, startApp } from './helpers.js';

let ctx, token, guardId;
const IMG = 'in/2026-10-30/1761800000000_A1B2C3D4.jpg';
before(async () => {
  ctx = await startApp();
  token = await loginAs(ctx, 'manager', 'camera');
  await ctx.call('POST', '/cards', { token, body: { uid: 'A1B2C3D4' } });
  await ctx.call('POST', '/cards', { token, body: { uid: 'B1B2C3D4', kind: 'monthly', plate: '30A99999' } });
  guardId = (await ctx.call('POST', '/guards', { token, body: { name: 'Nguyễn Văn Tuấn', pin: '2468' } })).body.id;
});
after(() => ctx.close());

const scan = (body) => ctx.call('POST', '/gate/scan', { token, body });

test('quẹt thẻ: API kiểm tra, mở / đóng lượt gửi, ghi nhật ký, trả 2 dòng OLED và chỗ trống', async () => {
  assert.equal((await scan({ gate: 'x', uid: 'A1B2C3D4' })).status, 400);
  assert.equal((await scan({ gate: 'in', uid: 'FFFFFFFF', plate: '59X112345', score: 0.9 })).body.message, 'The chua dang ky');
  assert.equal((await scan({ gate: 'in', uid: 'A1B2C3D4', plate: null })).body.message, 'Khong doc duoc bien');
  assert.equal((await scan({ gate: 'in', uid: 'A1B2C3D4', plate: '59X112345', score: 0.5 })).body.message, 'Bien mo, quet lai');
  assert.equal((await scan({ gate: 'in', uid: 'B1B2C3D4', plate: '59X112345', score: 0.9 })).body.message, 'Sai xe ve thang');

  const vao = (await scan({ gate: 'in', uid: 'a1b2c3d4', plate: '59x1-123.45', score: 0.95, img: IMG })).body;
  assert.deepEqual([vao.ok, vao.l1, vao.l2, vao.status.free], [true, '59X112345', 'Moi vao', 49]);
  assert.equal((await scan({ gate: 'in', uid: 'A1B2C3D4', plate: '59X112345', score: 0.95 })).body.message, 'The dang gui xe');
  // Biển đã trong bãi thì thẻ khác cũng không đưa vào được
  assert.equal((await scan({ gate: 'in', uid: 'B1B2C3D4', plate: '59X112345', score: 0.95 })).body.message, 'Xe da o trong bai');

  assert.equal((await scan({ gate: 'out', uid: 'A1B2C3D4', plate: '30A11111' })).body.message, 'Sai bien so');
  const ra = (await scan({ gate: 'out', uid: 'A1B2C3D4', plate: '59X112346', candidates: ['59X112345'] })).body;
  assert.deepEqual([ra.ok, ra.open, ra.fee, ra.l2, ra.status.free], [true, true, 3000, 'Phi: 3000d', 50]);
  assert.equal((await scan({ gate: 'out', uid: 'A1B2C3D4', plate: '59X112345' })).body.message, 'Khong co luot gui');

  const s = (await ctx.call('GET', '/sessions?plate=59X112345', { token })).body.sessions[0];
  assert.deepEqual([s.img_in, s.fee, s.plate_out], [IMG, 3000, '59X112346']);
  const [last] = (await ctx.call('GET', '/events?limit=1', { token })).body;
  assert.deepEqual([last.kind, last.status, last.uid], ['scan', 'denied', 'A1B2C3D4']);
});

test('bảo vệ mở tay: sai PIN bị từ chối, đúng PIN đóng lượt bị từ chối gần đây kèm tên bảo vệ', async () => {
  assert.deepEqual((await ctx.call('POST', '/gate/auth', { token, body: { pin: '0000' } })).body.ok, false);
  const enroll = (await ctx.call('POST', '/gate/auth', { token, body: { pin: '2468', enroll: true } })).body;
  assert.deepEqual([enroll.ok, enroll.guardId], [true, guardId]);

  await ctx.db.insert(ctx.db.Session, { card_uid: 'A1B2C3D4', plate_in: '59X112345', time_in: ago(1) });
  const r = (await ctx.call('POST', '/gate/auth', { token, body: { pin: '2468', denied: { uid: 'A1B2C3D4', plate: '59X112345' } } })).body;
  assert.match(r.message, /PIN bao ve #\d+ \| the A1B2C3D4 \| Phi: 3000d/);
  const s = (await ctx.call('GET', '/sessions?plate=59X112345', { token })).body.sessions.at(-1); // lượt vào 1 giờ trước
  assert.deepEqual([s.override_name, s.fee], ['Nguyễn Văn Tuấn', 3000]);
});

test('đăng ký vân tay rồi chấm công bằng vân tay: vào ca, ra ca', async () => {
  assert.equal((await ctx.call('POST', '/gate/enrolled', { token, body: { id: 999 } })).status, 404);
  assert.equal((await ctx.call('POST', '/gate/enrolled', { token, body: { id: guardId } })).body.ok, true);
  assert.deepEqual((await ctx.call('POST', '/gate/punch', { token, body: { finger: 77 } })).body,
    { ok: false, pinWrong: false, l1: 'KHONG RO', l2: 'Van tay #77 chua gan' });

  const vao = (await ctx.call('POST', '/gate/punch', { token, body: { finger: guardId } })).body;
  assert.deepEqual([vao.ok, vao.l1], [true, 'VAO CA']);
  assert.match(vao.l2, /^Tuan \d\d:\d\d/);
  const ra = (await ctx.call('POST', '/gate/punch', { token, body: { pin: '2468' } })).body;
  assert.equal(ra.l1, 'RA CA');
  const att = (await ctx.call('GET', '/attendance', { token })).body.records[0];
  assert.deepEqual([att.method_in, att.method_out, att.open], ['finger', 'pin', false]);
});

test('lệnh mở cổng từ app quản lý: ĐT cổng ra hỏi định kỳ, lệnh quá cũ bị bỏ', async () => {
  const cmd = (await ctx.call('POST', '/gate/open', { token })).body;
  await ctx.db.insert(ctx.db.GateEvent, { gate: 'out', kind: 'open_cmd', created_at: ago(1) });
  assert.deepEqual((await ctx.call('GET', '/gate/commands', { token })).body.map((c) => c.id), [cmd.id]);
  assert.equal((await ctx.call('POST', `/gate/commands/${cmd.id}/done`, { token })).body.status, 'done');
  assert.deepEqual((await ctx.call('GET', '/gate/commands', { token })).body, []);
  assert.equal((await ctx.call('POST', '/gate/emergency', { token, body: { on: true } })).body.message, 'Bat khan cap');
});

test('API cổng chỉ cho quản lý / admin', async () => {
  const guard = await loginAs(ctx, 'guard', 'baove');
  assert.equal((await ctx.call('POST', '/gate/scan', { token: guard, body: { gate: 'in', uid: 'A1B2C3D4' } })).status, 403);
  assert.equal((await ctx.call('GET', '/gate/commands')).status, 401);
});
