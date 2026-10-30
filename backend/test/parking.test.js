import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { ago, loginAs, startApp } from './helpers.js';

let ctx, token;
before(async () => {
  ctx = await startApp();
  token = await loginAs(ctx, 'manager', 'quanly');
});
after(() => ctx.close());

test('thẻ: thêm, chuẩn hoá biển, vé tháng bắt buộc biển, sửa, tìm, không xoá được thẻ đã có lịch sử', async () => {
  const bad = await ctx.call('POST', '/cards', { token, body: { uid: 'A1B2C3D4', kind: 'monthly' } });
  assert.deepEqual([bad.status, bad.body.message], [400, 'Vé tháng cần biển số']);
  assert.equal((await ctx.call('POST', '/cards', { token, body: { uid: 'xyz' } })).status, 400);

  const c = await ctx.call('POST', '/cards', { token, body: { uid: 'a1b2c3d4', kind: 'monthly', plate: '59x1-123.45', owner: 'An' } });
  assert.equal(c.status, 201);
  assert.deepEqual([c.body.uid, c.body.plate], ['A1B2C3D4', '59X112345']);
  assert.equal((await ctx.call('POST', '/cards', { token, body: { uid: 'A1B2C3D4' } })).status, 409);

  const p = await ctx.call('PATCH', '/cards/A1B2C3D4', { token, body: { active: false } });
  assert.deepEqual([p.body.active, p.body.kind], [false, 'monthly']);
  assert.equal((await ctx.call('GET', '/cards?q=an', { token })).body.length, 1);

  await ctx.db.insert(ctx.db.Session, { card_uid: 'A1B2C3D4', plate_in: '59X112345' });
  const del = await ctx.call('DELETE', '/cards/A1B2C3D4', { token });
  assert.equal(del.status, 409);
});

test('số chỗ trống công khai, lịch sử theo ngày + doanh thu, phí tạm tính', async () => {
  await ctx.call('POST', '/cards', { token, body: { uid: '11111111' } });
  await ctx.db.insert(ctx.db.Session,
    { card_uid: '11111111', plate_in: '30A99999', time_in: ago(3), time_out: ago(1), fee: 3000, parked: false });
  const st = await ctx.call('GET', '/status');
  assert.deepEqual(st.body, { capacity: 50, occupied: 1, free: 49 });

  const h = await ctx.call('GET', '/sessions?plate=30a-999', { token });
  assert.deepEqual([h.body.count, h.body.revenue], [1, 3000]);
  const open = await ctx.call('GET', '/sessions?open=true', { token });
  assert.equal(open.body.sessions[0].plate_in, '59X112345');
  assert.equal((await ctx.call('GET', '/sessions?date=30-10-2026', { token })).status, 400);

  const rev = await ctx.call('GET', '/stats/revenue', { token });
  assert.equal(rev.body.total, 3000);

  const q = await ctx.call('POST', '/fees/quote', { body: { timeIn: '2026-10-28T13:00:00Z', timeOut: '2026-10-29T00:00:00Z' } });
  assert.deepEqual([q.body.fee, q.body.nights], [5000, 1]); // 20:00 -> 07:00 giờ VN qua mốc 22:00
});

test('cho xe ra khi mất thẻ: đóng lượt, tính phí, tạo lệnh mở cổng', async () => {
  await ctx.call('POST', '/cards', { token, body: { uid: '22222222' } });
  const s = await ctx.db.insert(ctx.db.Session, { card_uid: '22222222', plate_in: '51F00001', time_in: ago(2) });
  assert.equal((await ctx.call('GET', `/sessions/${s.id}/fee`, { token })).body.fee, 3000);
  const r = await ctx.call('POST', `/sessions/${s.id}/release`, { token });
  assert.deepEqual([r.status, r.body.fee], [200, 3000]);
  assert.equal((await ctx.call('POST', `/sessions/${s.id}/release`, { token })).status, 409);
  const [ev] = (await ctx.call('GET', '/events?limit=1', { token })).body;
  assert.deepEqual([ev.kind, ev.status, ev.gate], ['open_cmd', 'pending', 'out']);
});

test('mở cổng từ API và thẻ vừa quẹt cho màn thêm thẻ', async () => {
  assert.equal((await ctx.call('POST', '/gate/open', { token })).status, 201);
  const since = new Date().toISOString();
  assert.equal((await ctx.call('GET', `/scans/latest?since=${since}`, { token })).body, null);
  await ctx.db.insert(ctx.db.GateEvent, { gate: 'in', kind: 'scan', uid: '99AABBCC', status: 'denied' });
  const scan = await ctx.call('GET', `/scans/latest?since=${since}`, { token });
  assert.deepEqual([scan.body.uid, scan.body.registered], ['99AABBCC', false]);
});

test('cài đặt: kiểm dữ liệu rồi lưu', async () => {
  const bad = await ctx.call('PUT', '/settings', { token, body: { capacity: 0, priceDay: 1, priceNight: 1, nightMark: '22:00' } });
  assert.equal(bad.status, 400);
  const r = await ctx.call('PUT', '/settings', { token, body: { capacity: 80, priceDay: 4000, priceNight: 6000, nightMark: '21:30' } });
  assert.deepEqual([r.body.capacity, r.body.night_mark], [80, '21:30:00']);
  assert.equal((await ctx.call('GET', '/status')).body.capacity, 80);
});
