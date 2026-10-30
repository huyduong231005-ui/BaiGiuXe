// Cùng các ca với app/test/logic_test.dart: API và app phải tính giống nhau.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import './helpers.js'; // đặt TZ=Asia/Ho_Chi_Minh
import {
  attStat, calcFee, decideEntry, decideExit, nearestShift, normPlate, oledName, samePlate, summarize,
} from '../src/rules.js';

const cfg = { price_day: 3000, price_night: 5000, night_mark: '22:00:00' };
const at = (d, h, m = 0) => new Date(2026, 9, d, h, m);

test('normPlate bỏ ký tự phân cách, viết hoa', () => {
  assert.equal(normPlate('59x1-123.45'), '59X112345');
  assert.equal(normPlate(null), '');
});

test('samePlate chấp nhận lệch 1 ký tự, lệch 2 là xe khác', () => {
  assert.ok(samePlate('59X112345', '59M112345'));
  assert.ok(samePlate('59X112345', '59X11234'));
  assert.ok(!samePlate('59X112345', '59M112346'));
});

test('calcFee: trong ngày, qua 1 đêm, đúng mốc đêm, qua 2 đêm, vé tháng', () => {
  assert.equal(calcFee(at(28, 8), at(28, 21, 59), cfg), 3000);
  assert.equal(calcFee(at(28, 20), at(29, 7), cfg), 5000);
  assert.equal(calcFee(at(28, 22), at(28, 23), cfg), 5000);
  assert.equal(calcFee(at(28, 20), at(30, 7), cfg), 10000);
  assert.equal(calcFee(at(28, 20), at(30, 7), cfg, true), 0);
});

test('decideEntry kiểm lần lượt từng quy tắc', () => {
  const card = { active: true, kind: 'guest' };
  const ok = { card, hasOpenSession: false, free: 5, plate: '59X112345', score: 0.95 };
  assert.equal(decideEntry({ ...ok, card: null }).message, 'The chua dang ky');
  assert.equal(decideEntry({ ...ok, card: { active: false } }).message, 'The bi khoa');
  assert.equal(decideEntry({ ...ok, hasOpenSession: true }).message, 'The dang gui xe');
  assert.equal(decideEntry({ ...ok, free: 0 }).message, 'Bai da day');
  assert.equal(decideEntry({ ...ok, plate: null }).message, 'Khong doc duoc bien');
  assert.equal(decideEntry({ ...ok, score: 0.5 }).message, 'Bien mo, quet lai');
  assert.equal(decideEntry({ ...ok, parkedPlates: ['59M112345'] }).message, 'Xe da o trong bai');
  assert.equal(decideEntry({ ...ok, card: { active: true, kind: 'monthly', plate: '30A99999' } }).message, 'Sai xe ve thang');
  assert.deepEqual(decideEntry(ok), { ok: true, open: false, message: 'Moi vao' });
});

test('decideExit: lệch biển từ chối, khớp candidates thì mở cổng kèm phí', () => {
  const session = { plate_in: '59X112345', time_in: at(28, 8) };
  const base = { card: { kind: 'guest' }, session, now: at(28, 10), settings: cfg };
  assert.equal(decideExit({ ...base, session: null }).message, 'Khong co luot gui');
  assert.equal(decideExit({ ...base, plate: '30A99999' }).message, 'Sai bien so');
  const d = decideExit({ ...base, plate: '30A99999', candidates: ['59X112345'] });
  assert.deepEqual(d, { ok: true, open: true, message: 'Phi: 3000d', fee: 3000 });
});

test('attStat + summarize: trễ, về sớm, giờ làm, quên chấm ra', () => {
  const base = { guard_id: 1, guard_name: 'Tuấn', shift_start: '2026-10-28T06:00:00Z', shift_end: '2026-10-28T14:00:00Z' };
  const done = { ...base, time_in: '2026-10-28T06:12:00Z', time_out: '2026-10-28T13:55:00Z', method_out: 'finger' };
  const forgot = { ...base, shift_start: '2026-10-29T06:00:00Z', shift_end: '2026-10-29T14:00:00Z',
    time_in: '2026-10-29T06:00:00Z', time_out: '2026-10-29T14:00:00Z', method_out: 'auto' };
  assert.deepEqual(attStat(done), { lateMin: 12, earlyMin: 5, workedMin: 463, open: false, missingOut: false });
  assert.equal(attStat(forgot).workedMin, 0);
  const [s] = summarize([done, forgot]);
  assert.deepEqual(s, { guardId: 1, name: 'Tuấn', shifts: 2, workedMin: 463, lateCount: 1, lateMin: 12,
    earlyCount: 1, earlyMin: 5, missingOut: 1 });
});

test('nearestShift: ca gần nhất xét cả hôm trước / hôm sau, ca qua đêm (giống logic_test.dart)', () => {
  const defs = [
    { _id: 1, name: 'Sang', start_time: '06:00:00', end_time: '14:00:00' },
    { _id: 2, name: 'Chieu', start_time: '14:00:00', end_time: '22:00:00' },
    { _id: 3, name: 'Dem', start_time: '22:00:00', end_time: '06:00:00' },
  ];
  const s = nearestShift(defs, at(28, 6, 10));
  assert.deepEqual([s.def.name, s.start, s.end], ['Sang', at(28, 6), at(28, 14)]);
  assert.equal(nearestShift(defs, at(28, 13, 45)).def.name, 'Chieu');
  const dem = nearestShift(defs, at(28, 21, 50));
  assert.deepEqual([dem.def.name, dem.end], ['Dem', at(29, 6)]);
  const night = nearestShift([{ _id: 3, name: 'Dem', start_time: '23:30', end_time: '07:30' }], at(29, 0, 15));
  assert.deepEqual([night.start, night.end], [at(28, 23, 30), at(29, 7, 30)]);
  assert.equal(nearestShift([], at(28, 8)), null);
});

test('oledName lấy tên gọi, bỏ dấu', () => {
  assert.equal(oledName('Nguyễn Văn Tuấn'), 'Tuan');
  assert.equal(oledName('Trần Đức'), 'Duc');
  assert.equal(oledName('  Lê Thị Ưởng  '), 'Uong');
});

test('các ca chuyển từ logic_test.dart của app: lỗi OCR thực tế, vé tháng hết hạn lúc đang gửi, thiếu biển lúc vào', () => {
  assert.ok(samePlate('29M303658', '29Y303658')); // Y đọc thành M
  assert.ok(samePlate('29Y303653', '29Y303658')); // 8 đọc thành 3
  assert.ok(samePlate('29-y3 036.58', '29Y303658'));
  const now = at(30, 9);
  const card = (until) => ({ active: true, kind: 'monthly', plate: '59X112345', valid_until: until });
  const session = { plate_in: '59X112345', time_in: at(29, 8) };
  const exit = (c) => decideExit({ card: c, session, plate: '59X112345', now, settings: cfg });
  assert.equal(exit(card('2026-10-29')).fee, 5000); // hết hạn trong lúc gửi -> tính như vé lượt
  assert.equal(exit(card('2026-11-29')).fee, 0);
  assert.equal(decideEntry({ card: card(null), hasOpenSession: false, free: 1, plate: '59X112345', now }).ok, true);
  assert.equal(decideExit({ card: null, session: { ...session, plate_in: null }, plate: 'X', now, settings: cfg }).message,
    'Thieu bien luc vao');
  const others = decideExit({ card: null, session, plate: '30A999999', candidates: ['30A999998'], now, settings: cfg });
  assert.equal(others.message, 'Sai bien so');
});
