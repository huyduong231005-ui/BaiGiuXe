import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { ago, loginAs, startApp } from './helpers.js';
import { ymd } from '../src/parking.js';
import { decideEntry, decideExit, extendUntil, monthlyValid } from '../src/rules.js';

let ctx, manager, khach, khac;
before(async () => {
  ctx = await startApp();
  manager = await loginAs(ctx, 'manager', 'quanly');
  khach = await loginAs(ctx, 'customer', 'khach');
  khac = await loginAs(ctx, 'customer', 'khac');
});
after(() => ctx.close());

test('hạn vé tháng: cộng nối tiếp khi còn hạn, tính từ hôm nay khi hết hạn', () => {
  const now = new Date(2026, 9, 30, 9);
  assert.equal(extendUntil(null, 1, now), '2026-11-29');
  assert.equal(extendUntil('2026-11-15', 1, now), '2026-12-15');
  assert.equal(extendUntil('2026-10-01', 3, now), '2027-01-29');
  assert.ok(monthlyValid({ kind: 'monthly', valid_until: '2026-10-30' }, new Date(2026, 9, 30, 23, 59)));
  assert.ok(!monthlyValid({ kind: 'monthly', valid_until: '2026-10-29' }, now));
});

test('cổng: vé tháng hết hạn không cho vào; thẻ báo mất bị chặn cả vào lẫn ra', () => {
  const now = new Date(2026, 9, 30, 9);
  const base = { hasOpenSession: false, free: 5, plate: '59X112345', score: 0.95, now };
  const card = { active: true, kind: 'monthly', plate: '59X112345', valid_until: '2026-10-29' };
  assert.equal(decideEntry({ ...base, card }).message, 'Ve thang het han');
  assert.equal(decideEntry({ ...base, card: { ...card, lost_at: new Date() } }).message, 'The da bao mat');
  const exit = decideExit({ card: { ...card, lost_at: new Date() }, session: { plate_in: '59X112345', time_in: now },
    plate: '59X112345', now, settings: { price_day: 3000, price_night: 5000, night_mark: '22:00' } });
  assert.deepEqual([exit.ok, exit.open], [false, false]);
});

test('khách gửi đơn vé tháng -> sửa -> quản lý duyệt, gán thẻ -> thẻ hiện trong app khách', async () => {
  const bad = await ctx.call('POST', '/me/requests', { token: khach, body: { plate: '59', ownerName: 'An', months: 1, apartment: 'A1-12.05' } });
  assert.equal(bad.status, 400);
  const r0 = await ctx.call('POST', '/me/requests', { token: khach, body: { plate: '59x1-123.45', ownerName: 'An', months: 1 } });
  assert.equal(r0.status, 400); // thiếu căn hộ
  const r = await ctx.call('POST', '/me/requests', { token: khach, body: { plate: '59x1-123.45', ownerName: 'An', months: 1, apartment: 'A1-12.05' } });
  assert.deepEqual([r.status, r.body.plate, r.body.status], [201, '59X112345', 'pending']);
  const e = await ctx.call('PATCH', `/me/requests/${r.body.id}`, { token: khach, body: { plate: '59X112345', ownerName: 'Nguyễn An', months: 3, apartment: 'a1-12.05' } });
  assert.equal(e.body.months, 3);
  assert.equal((await ctx.call('PATCH', `/me/requests/${r.body.id}`, { token: khac, body: { plate: '59X112345', ownerName: 'X', months: 1, apartment: 'B2' } })).status, 409);

  // Khách không vào được API của quản lý, quản lý không vào được /me/requests
  assert.equal((await ctx.call('GET', '/requests', { token: khach })).status, 403);
  assert.equal((await ctx.call('GET', '/me/requests', { token: manager })).status, 403);

  const list = await ctx.call('GET', '/requests?status=pending', { token: manager });
  assert.equal(list.body[0].username, 'khach');
  assert.equal((await ctx.call('POST', `/requests/${r.body.id}/approve`, { token: manager, body: {} })).status, 400);
  const ok = await ctx.call('POST', `/requests/${r.body.id}/approve`, { token: manager, body: { cardUid: 'a1b2c3d4' } });
  assert.equal(ok.status, 200);
  assert.deepEqual([ok.body.card.uid, ok.body.card.kind, ok.body.card.plate, ok.body.request.status],
    ['A1B2C3D4', 'monthly', '59X112345', 'approved']);
  assert.match(ok.body.card.valid_until, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal((await ctx.call('POST', `/requests/${r.body.id}/approve`, { token: manager, body: { cardUid: 'A1B2C3D4' } })).status, 409);

  const cards = await ctx.call('GET', '/me/cards', { token: khach });
  assert.deepEqual([cards.body.length, cards.body[0].valid], [1, true]);
  assert.equal((await ctx.call('GET', '/me/cards', { token: khac })).body.length, 0);
});

test('gia hạn thẻ đang dùng: hạn mới nối tiếp hạn cũ; thẻ của khách khác thì không gán được', async () => {
  await ctx.db.Card.updateOne({ uid: 'A1B2C3D4' }, { valid_until: ymd(new Date(Date.now() + 10 * 864e5)) });
  const r = await ctx.call('POST', '/me/requests', { token: khach, body: { plate: '59X112345', ownerName: 'An', months: 1, cardUid: 'A1B2C3D4', apartment: 'A1-12.05' } });
  assert.equal((await ctx.call('POST', '/me/requests', { token: khac, body: { plate: '59X112345', ownerName: 'X', months: 1, cardUid: 'A1B2C3D4', apartment: 'B2' } })).status, 400);
  const before = (await ctx.db.Card.findOne({ uid: 'A1B2C3D4' }).lean()).valid_until;
  const ok = await ctx.call('POST', `/requests/${r.body.id}/approve`, { token: manager, body: {} });
  assert.equal(ok.body.card.valid_until, extendUntil(before, 1));

  const r2 = await ctx.call('POST', '/me/requests', { token: khac, body: { plate: '30A99999', ownerName: 'Bình', months: 1, apartment: 'B2-03.01' } });
  assert.equal((await ctx.call('POST', `/requests/${r2.body.id}/approve`, { token: manager, body: { cardUid: 'A1B2C3D4' } })).status, 409);
  const rej = await ctx.call('POST', `/requests/${r2.body.id}/reject`, { token: manager, body: { reply: 'Bãi hết chỗ vé tháng' } });
  assert.deepEqual([rej.body.status, rej.body.reply], ['rejected', 'Bãi hết chỗ vé tháng']);
  assert.equal((await ctx.call('DELETE', `/me/requests/${r2.body.id}`, { token: khac })).status, 409); // đã xử lý thì không huỷ
});

test('báo mất thẻ, mã QR vé, lịch sử và ảnh xe của chính mình', async () => {
  await ctx.db.insert(ctx.db.Session,
    { card_uid: 'A1B2C3D4', plate_in: '59X112345', img_in: 'in/2026-10-30/1761800000000_A1B2C3D4.jpg', time_in: ago(2) });
  const mine = (await ctx.call('GET', '/me/cards', { token: khach })).body[0];
  assert.deepEqual([mine.parked_plate, mine.fee_now], ['59X112345', 0]); // vé tháng còn hạn: miễn phí

  const qr = await ctx.call('GET', '/me/cards/A1B2C3D4/qr', { token: khach });
  assert.ok(!qr.body.qr.includes('A1B2C3D4')); // mã QR không lộ UID thẻ
  assert.equal((await ctx.call('GET', '/me/cards/A1B2C3D4/qr', { token: khac })).status, 404);
  const scan = await ctx.call('GET', `/sessions/by-ticket?qr=${encodeURIComponent(qr.body.qr)}`, { token: manager });
  assert.deepEqual([scan.body.cardUid, scan.body.matches[0].plate_in], ['A1B2C3D4', '59X112345']);
  assert.equal((await ctx.call('GET', '/sessions/by-ticket?qr=gia-mao', { token: manager })).status, 400);

  const hist = await ctx.call('GET', '/me/sessions', { token: khach });
  assert.equal(hist.body.length, 1);
  const img = await ctx.call('GET', '/me/plates/url?path=in/2026-10-30/1761800000000_A1B2C3D4.jpg', { token: khach });
  assert.equal(img.status, 200);
  assert.equal((await ctx.call('GET', '/me/plates/url?path=in/2026-10-30/1761800000000_A1B2C3D4.jpg', { token: khac })).status, 403);

  assert.equal((await ctx.call('POST', '/me/cards/A1B2C3D4/lost', { token: khac })).status, 404);
  const lost = await ctx.call('POST', '/me/cards/A1B2C3D4/lost', { token: khach });
  assert.deepEqual([lost.body.active, Boolean(lost.body.lost_at)], [false, true]);
  // Quản lý mở lại khi khách tìm thấy thẻ
  const back = await ctx.call('PATCH', '/cards/A1B2C3D4', { token: manager, body: { active: true, lost: false } });
  assert.deepEqual([back.body.active, back.body.lost_at, back.body.valid_until], [true, null, mine.valid_until]);
});

test('admin tạo tài khoản đã kích hoạt; thông tin bãi công khai cho bản đồ', async () => {
  const admin = await loginAs(ctx, 'admin', 'admin1');
  const u = await ctx.call('POST', '/admin/users', { token: admin,
    body: { email: 'bv2@test.vn', username: 'baove2', password: 'matkhau1', role: 'guard', fullName: 'Bảo vệ 2' } });
  assert.deepEqual([u.status, u.body.role, u.body.active], [201, 'guard', true]);
  assert.equal((await ctx.call('POST', '/admin/users', { token: manager, body: {} })).status, 403);

  await ctx.call('PUT', '/settings', { token: manager,
    body: { capacity: 50, priceDay: 3000, priceNight: 5000, nightMark: '22:00', lotName: 'Bãi xe HUTECH', address: '475A Điện Biên Phủ', lat: 10.8017, lng: 106.7149 } });
  const lot = await ctx.call('GET', '/lot');
  assert.deepEqual([lot.body.name, lot.body.lat, lot.body.free], ['Bãi xe HUTECH', 10.8017, 49]);
  assert.equal((await ctx.call('PUT', '/settings', { token: manager,
    body: { capacity: 50, priceDay: 3000, priceNight: 5000, nightMark: '22:00', lat: 200, lng: 1 } })).status, 400);
});
