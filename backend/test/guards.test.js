import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import bcrypt from 'bcryptjs';
import { loginAs, startApp } from './helpers.js';

let ctx, token;
before(async () => {
  ctx = await startApp();
  token = await loginAs(ctx, 'manager', 'quanly');
});
after(() => ctx.close());

const tuan = async () => ctx.db.row(await ctx.db.Guard.findOne({ name: 'Nguyễn Văn Tuấn' }).lean());

test('bảo vệ: PIN bắt buộc 4-8 số, lưu dạng bcrypt, không trả hash ra ngoài', async () => {
  assert.equal((await ctx.call('POST', '/guards', { token, body: { name: 'Tuấn', pin: '12' } })).status, 400);
  const g = await ctx.call('POST', '/guards', { token, body: { name: 'Nguyễn Văn Tuấn', pin: '1234' } });
  assert.equal(g.status, 201);
  assert.deepEqual([g.body.has_pin, g.body.pin_hash], [true, undefined]);
  const { pin_hash: hash } = await ctx.db.Guard.findById(g.body.id).lean();
  assert.ok(hash.startsWith('$2') && (await bcrypt.compare('1234', hash)));

  const p = await ctx.call('PATCH', `/guards/${g.body.id}`, { token, body: { fingerId: 3 } });
  assert.deepEqual([p.body.finger_id, p.body.name], [3, 'Nguyễn Văn Tuấn']);
  assert.equal((await ctx.call('PATCH', `/guards/${g.body.id}`, { token, body: { fingerId: 999 } })).status, 400);
});

test('ca trực: thêm, sửa, kiểm giờ HH:MM', async () => {
  assert.equal((await ctx.call('GET', '/shifts', { token })).body.length, 3); // 3 ca mặc định do initDb tạo
  assert.equal((await ctx.call('POST', '/shifts', { token, body: { name: 'Ca gãy', startTime: '25:00', endTime: '01:00' } })).status, 400);
  const s = await ctx.call('POST', '/shifts', { token, body: { name: 'Ca hành chính', startTime: '08:00', endTime: '17:00' } });
  const u = await ctx.call('PUT', `/shifts/${s.body.id}`, { token, body: { name: 'Ca HC', startTime: '07:30', endTime: '17:00' } });
  assert.deepEqual([u.body.name, u.body.start_time], ['Ca HC', '07:30:00']);
  assert.equal((await ctx.call('DELETE', `/shifts/${s.body.id}`, { token })).status, 204);
});

test('bảng công tháng: tổng hợp theo bảo vệ; tài khoản bảo vệ chỉ xem của mình', async () => {
  const g = await tuan();
  await ctx.db.insert(ctx.db.Attendance, { guard_id: g.id, shift_name: 'Ca sáng',
    shift_start: new Date('2026-10-28T06:00:00+07:00'), shift_end: new Date('2026-10-28T14:00:00+07:00'),
    time_in: new Date('2026-10-28T06:10:00+07:00'), time_out: new Date('2026-10-28T13:50:00+07:00'),
    method_in: 'finger', method_out: 'pin', on_duty: false });
  const r = await ctx.call('GET', '/attendance?month=2026-10', { token });
  assert.deepEqual(r.body.summary[0], { guardId: g.id, name: 'Nguyễn Văn Tuấn', shifts: 1, workedMin: 460,
    lateCount: 1, lateMin: 10, earlyCount: 1, earlyMin: 10, missingOut: 0 });
  assert.equal(r.body.records[0].lateMin, 10);

  const guard = await loginAs(ctx, 'guard', 'tuan');
  assert.equal((await ctx.call('GET', '/me/attendance', { token: guard })).status, 404);
  await ctx.db.User.updateOne({ username: 'tuan' }, { guard_id: g.id });
  const mine = await ctx.call('GET', '/me/attendance?month=2026-10', { token: guard });
  assert.equal(mine.body.records.length, 1);
  assert.equal((await ctx.call('GET', '/attendance', { token: guard })).status, 403);
});

test('không xoá được bảo vệ đã có bảng công', async () => {
  const g = await tuan();
  assert.equal((await ctx.call('DELETE', `/guards/${g.id}`, { token })).status, 409);
});
