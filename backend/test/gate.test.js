import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { ago, loginAs, startApp } from './helpers.js';

let ctx, token, guardId;
before(async () => {
  ctx = await startApp();
  token = await loginAs(ctx, 'manager', 'camera');
  await ctx.call('POST', '/cards', { token, body: { uid: 'A1B2C3D4' } });
  guardId = (await ctx.call('POST', '/guards', { token, body: { name: 'Nguyễn Văn Tuấn', pin: '2468' } })).body.id;
});
after(() => ctx.close());

test('xe vào rồi ra: context đủ dữ liệu để quyết định, không vào 2 lần, đóng lượt 1 lần', async () => {
  const c0 = (await ctx.call('GET', '/gate/context?uid=a1b2c3d4', { token })).body;
  assert.deepEqual([c0.card.uid, c0.open, c0.status.free, c0.settings.price_day, c0.parked], ['A1B2C3D4', null, 50, 3000, []]);

  assert.equal((await ctx.call('POST', '/gate/sessions', { token, body: { card_uid: 'A1B2C3D4' } })).status, 400); // thiếu biển
  assert.equal((await ctx.call('POST', '/gate/sessions', { token, body: { card_uid: 'FFFFFFFF', plate_in: '59X112345' } })).status, 400);
  const s = await ctx.call('POST', '/gate/sessions', { token, body: { card_uid: 'A1B2C3D4', plate_in: '59x1-123.45', img_in: 'in/2026-10-30/1_A1B2C3D4.jpg' } });
  assert.deepEqual([s.status, s.body.plate_in, s.body.time_out], [201, '59X112345', null]);
  assert.equal((await ctx.call('POST', '/gate/sessions', { token, body: { card_uid: 'A1B2C3D4', plate_in: '30A99999' } })).status, 409);

  const c1 = (await ctx.call('GET', '/gate/context?uid=A1B2C3D4', { token })).body;
  assert.deepEqual([c1.open.id, c1.status.free, c1.parked], [s.body.id, 49, ['59X112345']]);

  const out = await ctx.call('POST', `/gate/sessions/${s.body.id}/close`, { token, body: { plate_out: '59X112345', fee: 3000 } });
  assert.deepEqual([out.status, out.body.fee, Boolean(out.body.time_out)], [200, 3000, true]);
  assert.equal((await ctx.call('POST', `/gate/sessions/${s.body.id}/close`, { token, body: { fee: 3000 } })).status, 409);
  assert.equal((await ctx.call('GET', '/status')).body.free, 50);
});

test('bảo vệ mở tay: tìm theo PIN / vân tay, đóng lượt của thẻ bị từ chối kèm tên bảo vệ', async () => {
  assert.equal((await ctx.call('POST', '/gate/guards/find', { token, body: { pin: '0000' } })).body, null);
  assert.deepEqual((await ctx.call('POST', '/gate/guards/find', { token, body: { pin: '2468' } })).body, { id: guardId, name: 'Nguyễn Văn Tuấn' });
  const f = await ctx.call('POST', `/gate/guards/${guardId}/finger`, { token });
  assert.deepEqual([f.body.finger_id, f.body.pin_hash], [guardId, undefined]);
  assert.equal((await ctx.call('POST', '/gate/guards/find', { token, body: { finger: guardId } })).body.id, guardId);

  await ctx.db.insert(ctx.db.Session, { card_uid: 'A1B2C3D4', plate_in: '59X112345', time_in: ago(1) });
  const r = await ctx.call('POST', '/gate/release-card', { token, body: { uid: 'A1B2C3D4', plate: '59X112345', guardId } });
  assert.deepEqual([r.body.fee, r.body.session.override_by], [3000, guardId]);
  assert.deepEqual((await ctx.call('POST', '/gate/release-card', { token, body: { uid: 'A1B2C3D4' } })).body, { session: null, fee: null });
});

test('nhật ký cổng và lệnh mở cổng từ app quản lý (ĐT cổng ra hỏi định kỳ)', async () => {
  assert.equal((await ctx.call('POST', '/gate/events', { token, body: { gate: 'x', kind: 'scan' } })).status, 400);
  const e = await ctx.call('POST', '/gate/events', { token, body: { gate: 'in', kind: 'scan', uid: 'a1b2c3d4', status: 'ok', plate: '59X112345', open: false } });
  assert.deepEqual([e.status, e.body.uid], [201, 'A1B2C3D4']);

  const cmd = (await ctx.call('POST', '/gate/open', { token })).body;
  await ctx.db.insert(ctx.db.GateEvent, { gate: 'out', kind: 'open_cmd', created_at: ago(1) }); // quá cũ, bỏ qua
  assert.deepEqual((await ctx.call('GET', '/gate/commands', { token })).body.map((c) => c.id), [cmd.id]);
  assert.equal((await ctx.call('POST', `/gate/commands/${cmd.id}/done`, { token })).body.status, 'done');
  assert.deepEqual((await ctx.call('GET', '/gate/commands', { token })).body, []);
});

test('chấm công: mở ca, chỉ 1 ca đang mở mỗi bảo vệ, đóng ca', async () => {
  assert.equal((await ctx.call('GET', `/gate/attendance/open?guardId=${guardId}`, { token })).body, null);
  const a = await ctx.call('POST', '/gate/attendance', { token, body: { guard_id: guardId, shift_id: 1, shift_name: 'Ca sáng',
    shift_start: '2026-10-30T06:00:00+07:00', shift_end: '2026-10-30T14:00:00+07:00', method_in: 'finger' } });
  assert.deepEqual([a.status, a.body.shift_name], [201, 'Ca sáng']);
  assert.equal((await ctx.call('POST', '/gate/attendance', { token, body: { guard_id: guardId, method_in: 'pin' } })).status, 409);
  assert.equal((await ctx.call('GET', `/gate/attendance/open?guardId=${guardId}`, { token })).body.id, a.body.id);
  const c = await ctx.call('POST', `/gate/attendance/${a.body.id}/close`, { token, body: { method_out: 'pin' } });
  assert.deepEqual([c.body.method_out, Boolean(c.body.time_out)], ['pin', true]);
  assert.equal((await ctx.call('POST', `/gate/attendance/${a.body.id}/close`, { token, body: { method_out: 'pin' } })).status, 409);
});

test('API cổng chỉ cho quản lý / admin', async () => {
  const guard = await loginAs(ctx, 'guard', 'baove');
  assert.equal((await ctx.call('GET', '/gate/context?uid=A1B2C3D4', { token: guard })).status, 403);
  assert.equal((await ctx.call('GET', '/gate/commands')).status, 401);
});
