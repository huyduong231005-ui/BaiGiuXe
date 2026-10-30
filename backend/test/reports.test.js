import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import ExcelJS from 'exceljs';
import { ago, loginAs, startApp } from './helpers.js';

let ctx, token;
before(async () => {
  ctx = await startApp();
  token = await loginAs(ctx, 'manager', 'quanly');
  const { Card, Session, Guard, Attendance, insert } = ctx.db;
  await Card.create([{ uid: '11111111', kind: 'guest' }, { uid: '22222222', kind: 'monthly', plate: '30A99999' }]);
  await insert(Session, { card_uid: '11111111', plate_in: '59X112345', time_in: new Date('2026-10-05T08:00:00+07:00'),
    time_out: new Date('2026-10-05T10:00:00+07:00'), fee: 3000, parked: false });
  await insert(Session, { card_uid: '22222222', plate_in: '30A99999', time_in: ago(1) });
  const g = await insert(Guard, { name: 'Nguyễn Văn Tuấn' });
  await insert(Attendance, { guard_id: g.id, shift_name: 'Ca sáng', shift_start: new Date('2026-10-05T06:00:00+07:00'),
    shift_end: new Date('2026-10-05T14:00:00+07:00'), time_in: new Date('2026-10-05T06:15:00+07:00'),
    time_out: new Date('2026-10-05T14:00:00+07:00'), method_in: 'finger', method_out: 'finger', on_duty: false });
});
after(() => ctx.close());

test('tra cứu xe trong bãi theo biển: khớp lệch 1 ký tự, xét cả candidates, kèm phí tạm tính', async () => {
  const r = await ctx.call('GET', '/sessions/lookup?plate=30A-99998', { token });
  assert.equal(r.body.matches.length, 1);
  assert.deepEqual([r.body.matches[0].card_uid, r.body.matches[0].exact, r.body.matches[0].feeNow], ['22222222', false, 0]);
  const viaCandidate = await ctx.call('GET', '/sessions/lookup?plate=51F00001&candidates=30A99999', { token });
  assert.equal(viaCandidate.body.matches[0].card_kind, 'monthly');
  assert.equal((await ctx.call('GET', '/sessions/lookup?plate=59X112345', { token })).body.matches.length, 0); // đã ra
  assert.equal((await ctx.call('GET', '/sessions/lookup', { token })).status, 400);
});

test('báo cáo tháng Excel: doanh thu, lượt gửi, bảng công', async () => {
  const res = await fetch(`${ctx.base}/reports/monthly.xlsx?month=2026-10`, { headers: { authorization: `Bearer ${token}` } });
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-disposition'), /bao-cao-2026-10\.xlsx/);
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await res.arrayBuffer());
  assert.deepEqual(wb.worksheets.map((w) => w.name), ['Doanh thu', 'Lượt gửi', 'Bảng công', 'Chi tiết chấm công']);
  const rev = wb.getWorksheet('Doanh thu');
  assert.deepEqual(rev.getRow(2).values.slice(1), ['2026-10-05', 1, 3000]);
  assert.deepEqual(rev.getRow(3).values.slice(1), ['Tổng', 1, 3000]);
  const att = wb.getWorksheet('Bảng công').getRow(2).values.slice(1);
  assert.deepEqual(att, ['Nguyễn Văn Tuấn', 1, 7.75, 1, 15, 0, 0, 0]);
  assert.equal((await ctx.call('GET', '/reports/monthly.xlsx?month=10-2026', { token })).status, 400);
});
