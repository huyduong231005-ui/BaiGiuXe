import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { ago, loginAs, startApp } from './helpers.js';

let ctx, token;
before(async () => {
  ctx = await startApp();
  token = await loginAs(ctx, 'manager', 'quanly');
});
after(() => ctx.close());

const call = (method, path, body) => ctx.call(method, path, { token, body });
const scan = (body) => call('POST', '/gate/scan', { score: 0.95, ...body });

test('bảng giá theo loại xe: 3 loại mặc định, thêm / sửa / không xoá được loại đang dùng', async () => {
  const types = (await call('GET', '/vehicle-types')).body;
  assert.deepEqual(types.map((t) => [t.code, t.price_day, t.price_night, t.price_month]),
    [['motorbike', 5000, 10000, 150000], ['car', 25000, 50000, 1500000], ['bicycle', 2000, 5000, 100000]]);
  assert.equal((await call('POST', '/vehicle-types', { code: 'X', name: 'Lỗi', priceDay: 1, priceNight: 1, priceMonth: 1 })).status, 400);
  const e = await call('POST', '/vehicle-types', { code: 'ebike', name: 'Xe điện', priceDay: 4000, priceNight: 8000, priceMonth: 120000 });
  assert.equal(e.status, 201);
  assert.equal((await call('PUT', `/vehicle-types/${e.body.id}`, { name: 'Xe máy điện', priceDay: 4000, priceNight: 8000, priceMonth: 130000 })).body.price_month, 130000);
  assert.equal((await call('DELETE', `/vehicle-types/${e.body.id}`)).status, 204);
  const quote = await call('POST', '/fees/quote', { timeIn: '2026-10-28T01:00:00Z', timeOut: '2026-10-28T03:00:00Z', vehicleType: 'car' });
  assert.equal(quote.body.fee, 25000);
});

// Mặt bằng thử: lối vào ở cột 1, lối ra ở cột 7, một làn đường, khu A xe máy 2 ô gần cổng vào, khu C ô tô 2 ô.
const LAYOUT = [
  '#I#####O#',
  '#=======#',
  '#AA.CC..#',
  '#########',
];

test('mặt bằng: tạo khu, vẽ ô, kiểm tra lối vào / ra / đường tới ô, giữ mã ô khi sửa, gán ô cư dân', async () => {
  assert.equal((await call('POST', '/zones', { name: 'A', vehicleType: 'tau' })).status, 400);
  assert.equal((await call('POST', '/zones', { name: 'I', vehicleType: 'motorbike' })).status, 400); // I, O dành cho lối vào / ra
  const a = await call('POST', '/zones', { name: 'a', vehicleType: 'motorbike' });
  assert.equal(a.status, 201);
  await call('POST', '/zones', { name: 'C', vehicleType: 'car' });

  const bad = async (layout) => (await call('PUT', '/lot/layout', { layout })).body.message;
  assert.match(await bad(LAYOUT.map((l) => l.replace('CC', 'BB'))), /Khu B chưa tạo/);
  assert.match(await bad(LAYOUT.map((l) => l.replace('O', '#'))), /lối ra/);
  assert.match(await bad([...LAYOUT.slice(0, 3), '#.....A.#', '#########']), /không có đường xe tới/);
  assert.match(await bad(['#I#O', '#==#', '#=']), /dài bằng nhau/);

  const saved = await call('PUT', '/lot/layout', { layout: LAYOUT });
  assert.equal(saved.status, 200);
  assert.deepEqual(saved.body.layout, LAYOUT);
  assert.deepEqual(saved.body.zones.map((z) => z.slots.map((s) => [s.code, s.row, s.col])),
    [[['A-01', 2, 1], ['A-02', 2, 2]], [['C-01', 2, 4], ['C-02', 2, 5]]]);

  await call('POST', '/cards', { uid: 'C0000001', kind: 'monthly', plate: '59X111111', owner: 'Cư dân 1', apartment: 'a1-12.05' });
  await call('POST', '/cards', { uid: 'C0000002', kind: 'guest' });
  assert.equal((await call('PATCH', '/slots/A-01', { cardUid: 'C0000002' })).status, 400); // thẻ lượt không giữ ô
  assert.equal((await call('PATCH', '/slots/C-01', { cardUid: 'C0000001' })).status, 400); // khác loại xe
  assert.equal((await call('PATCH', '/slots/A-01', { cardUid: 'c0000001' })).body.card_uid, 'C0000001');
  const cards = (await call('GET', '/cards?q=C0000001')).body;
  assert.deepEqual([cards[0].slot_code, cards[0].apartment, cards[0].vehicle_type], ['A-01', 'A1-12.05', 'motorbike']);

  // Sửa mặt bằng: dời C-02 sang cột 6. Ô giữ vị trí giữ nguyên mã (ô cư dân A-01 không bị lệch), ô mới lấy số mới.
  const moved = LAYOUT.map((l, r) => (r === 2 ? '#AA.C.C.#' : l));
  const m = (await call('PUT', '/lot/layout', { layout: moved })).body;
  assert.deepEqual(m.zones[1].slots.map((s) => [s.code, s.col]), [['C-01', 4], ['C-02', 6]]);
  assert.equal(m.zones[0].slots[0].card_uid, 'C0000001');
  await call('PUT', '/lot/layout', { layout: LAYOUT });
  assert.equal((await call('GET', '/status')).body.capacity, 4); // có sơ đồ thì sức chứa = số ô
  assert.equal((await call('DELETE', `/zones/${a.body.id}`)).status, 409); // còn ô trên mặt bằng

  // Đường từ cổng vào tới ô + lời chỉ dẫn, và từ ô ra cổng ra
  const r = (await call('GET', '/lot/route?slot=c-02')).body;
  assert.deepEqual([r.path[0], r.path.at(-1), r.exitPath.at(-1)], [[0, 1], [2, 5], [0, 7]]);
  assert.equal(r.hint, 'Qua cổng vào, đi thẳng 1 ô, rẽ trái đi 4 ô, ô C-02 ở bên phải');
  assert.equal((await call('GET', '/lot/route?slot=Z-99')).status, 404);
});

test('khách vãng lai được chỉ ô trống không phải ô cư dân; cư dân vào ô riêng; hết chỗ thì từ chối', async () => {
  await call('POST', '/cards', { uid: 'C0000003', kind: 'guest' });
  const guest = (await scan({ gate: 'in', uid: 'C0000002', plate: '30A11111', vehicle: 'Motorcycle' })).body;
  assert.deepEqual([guest.ok, guest.l2, guest.slot], [true, 'Moi vao o A-02', 'A-02']); // A-01 là của cư dân
  assert.equal(guest.route.hint, 'Qua cổng vào, đi thẳng 1 ô, rẽ trái đi 1 ô, ô A-02 ở bên phải');
  const full = (await scan({ gate: 'in', uid: 'C0000003', plate: '30A22222', vehicle: 'Motorcycle' })).body;
  assert.deepEqual([full.ok, full.l2], [false, 'Het cho xe may']);
  const car = (await scan({ gate: 'in', uid: 'C0000003', plate: '51G33333', vehicle: 'Sedan' })).body;
  assert.deepEqual([car.ok, car.slot], [true, 'C-01']); // OCR nhận ra ô tô -> ô tô trống gần cổng vào nhất
  const resident = (await scan({ gate: 'in', uid: 'C0000001', plate: '59X111111' })).body;
  assert.deepEqual([resident.ok, resident.slot], [true, 'A-01']);

  const map = (await call('GET', '/lot/map')).body;
  const a01 = map.zones[0].slots[0];
  assert.deepEqual([a01.state, a01.plate, a01.apartment], ['parked', '59X111111', 'A1-12.05']);
  assert.equal((await call('GET', '/status')).body.byType.motorbike.free, 0);
  // Khách xem sơ đồ: không lộ biển số / chủ xe
  const khach = await loginAs(ctx, 'customer', 'khach');
  const pub = (await ctx.call('GET', '/lot/map/public', { token: khach })).body;
  assert.equal(pub.zones[0].slots[0].plate, undefined);

  // Xe ra: ô trả lại, giá theo loại xe của lượt (ô tô 25.000đ)
  const out = (await scan({ gate: 'out', uid: 'C0000003', plate: '51G33333' })).body;
  assert.deepEqual([out.ok, out.fee, out.slot], [true, 25000, 'C-01']);
  assert.equal((await call('DELETE', `/zones/${map.zones[0].id}`)).status, 409); // khu có xe / ô cư dân
});

test('thống kê nhận diện biển: tốc độ, đọc được lần đầu, khớp biển lúc ra', async () => {
  await scan({ gate: 'in', uid: 'FFFFFFFF', plate: null, score: 0, shots: 2, ocrMs: 3400, totalMs: 3900 });
  const st = (await call('GET', '/stats/ocr')).body;
  assert.ok(st.scans >= 5);
  assert.equal(st.ocrMs.p95, 3400);
  assert.ok(st.readRate < 100);
  assert.equal(st.exitMatchRate, 100);
  assert.ok(st.reasons.some((r) => r.message === 'Het cho xe may'));
  assert.equal(st.recent[0].shots, 2);
});

test('doanh thu: tách vé lượt / vé tháng, theo ngày và theo tháng, theo loại xe', async () => {
  // Đơn vé tháng ô tô 2 tháng được duyệt -> khoản thu 3.000.000đ
  const khach = await loginAs(ctx, 'customer', 'khach2');
  const r = await ctx.call('POST', '/me/requests', { token: khach,
    body: { plate: '51H44444', ownerName: 'Bình', months: 2, vehicleType: 'car', apartment: 'B2-03.01' } });
  const ok = await call('POST', `/requests/${r.body.id}/approve`, { cardUid: 'D0000001' });
  assert.deepEqual([ok.body.card.vehicle_type, ok.body.card.apartment], ['car', 'B2-03.01']);

  const day = (await call('GET', '/stats/revenue')).body;
  assert.equal(day.rows.length, 30);
  assert.deepEqual([day.visitor, day.monthly, day.total], [25000, 3000000, 3025000]);
  assert.equal(day.rows.at(-1).total, 3025000);
  const car = day.byType.find((t) => t.vehicle_type === 'car');
  assert.deepEqual([car.name, car.visitor, car.monthly], ['Ô tô', 25000, 3000000]);
  const month = (await call('GET', '/stats/revenue?group=month')).body;
  assert.equal(month.rows.length, 12);
  assert.equal(month.rows.at(-1).total, 3025000);
  assert.equal((await call('GET', '/stats/revenue?group=year')).status, 400);
});

test('mất mạng: ESP32 lấy danh sách thẻ tháng, gửi bù lượt ra / vào không bị ghi trùng', async () => {
  const wl = (await call('GET', '/gate/whitelist')).body;
  assert.ok(wl.some((c) => c.u === 'C0000001' && c.d === 0));
  assert.ok(!wl.some((c) => c.u === 'C0000002')); // thẻ lượt không có

  // Cư dân mới chưa có lượt gửi: mất mạng lúc vào (2 giờ trước) và lúc ra (1 giờ trước). Giờ ESP32 = giờ địa phương dạng epoch.
  await call('POST', '/cards', { uid: 'C0000004', kind: 'monthly', plate: '59X444444', apartment: 'C3-01.01' });
  const local = (d) => Math.floor(d.getTime() / 1000) - d.getTimezoneOffset() * 60;
  const events = [
    { t: 'out', uid: 'C0000004', ts: local(ago(1)), by: 'card' }, // gửi lệch thứ tự: API tự xếp theo giờ
    { t: 'in', uid: 'C0000004', ts: local(ago(2)), by: 'card' },
    { t: 'out', ts: local(ago(1)), by: 'finger', guard: 3 },
  ];
  assert.deepEqual((await call('POST', '/gate/offline', { events })).body, { received: 3, applied: 3 });
  assert.deepEqual((await call('POST', '/gate/offline', { events })).body, { received: 3, applied: 0 }); // gửi lại
  const [s] = (await call('GET', '/sessions?plate=59X444444&date=' + new Date(Date.now() - 2 * 3600e3).toLocaleDateString('sv'))).body.sessions;
  assert.deepEqual([s.offline, s.fee, Math.round((new Date(s.time_out) - new Date(s.time_in)) / 3600e3)], [true, 0, 1]);
  const log = (await call('GET', '/events?limit=3')).body.map((e) => e.message);
  assert.ok(log.some((m) => m === 'Offline: bao ve mo bang van tay #3'));
});
