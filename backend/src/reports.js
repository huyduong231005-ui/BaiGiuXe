// Báo cáo tháng ra Excel: doanh thu theo ngày, danh sách lượt gửi, bảng công bảo vệ.
import { Router } from 'express';
import ExcelJS from 'exceljs';
import { HttpError, str } from './auth.js';
import { attStat, summarize } from './rules.js';

const MONTH_RE = /^\d{4}-\d{2}$/;
const tz = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
const local = (d) => (d ? new Date(d).toLocaleString('vi-VN', { timeZone: tz() }) : '');
const hours = (min) => Math.round((min / 60) * 100) / 100;

/** Thêm 1 sheet: dòng tiêu đề in đậm, cố định khi cuộn, cột tự rộng theo tiêu đề. */
function addSheet(wb, name, columns, rows) {
  const ws = wb.addWorksheet(name, { views: [{ state: 'frozen', ySplit: 1 }] });
  ws.columns = columns.map(([header, key, width = Math.max(12, header.length + 2)]) => ({ header, key, width }));
  ws.getRow(1).font = { bold: true };
  ws.addRows(rows);
  return ws;
}

export async function monthlyWorkbook(db, month) {
  const [y, m] = month.split('-').map(Number);
  const from = new Date(y, m - 1, 1), to = new Date(y, m, 1);
  const sessions = (await db.query(
    `select s.*, c.kind as card_kind, g.name as override_name from sessions s
     left join cards c on c.uid = s.card_uid left join guards g on g.id = s.override_by
     where s.time_in >= $1 and s.time_in < $2 order by s.time_in`, [from, to])).rows;
  const revenue = (await db.query(
    `select to_char(time_out at time zone $3, 'YYYY-MM-DD') as day, count(*)::int as sessions,
            coalesce(sum(fee), 0)::int as revenue
     from sessions where time_out >= $1 and time_out < $2 group by 1 order by 1`, [from, to, tz()])).rows;
  const attendance = (await db.query(
    `select a.*, g.name as guard_name from attendance a join guards g on g.id = a.guard_id
     where a.time_in >= $1 and a.time_in < $2 order by a.time_in`, [from, to])).rows;

  const wb = new ExcelJS.Workbook();
  wb.creator = 'Bãi giữ xe API';
  const rev = addSheet(wb, 'Doanh thu', [['Ngày', 'day'], ['Số lượt ra', 'sessions'], ['Doanh thu (đ)', 'revenue', 16]], revenue);
  rev.addRow({ day: 'Tổng', sessions: revenue.reduce((a, r) => a + r.sessions, 0), revenue: revenue.reduce((a, r) => a + r.revenue, 0) })
    .font = { bold: true };
  rev.getColumn('revenue').numFmt = '#,##0';

  addSheet(wb, 'Lượt gửi', [['Mã', 'id', 8], ['Thẻ', 'card'], ['Loại vé', 'kind'], ['Biển vào', 'plateIn'], ['Biển ra', 'plateOut'],
    ['Giờ vào', 'timeIn', 20], ['Giờ ra', 'timeOut', 20], ['Phí (đ)', 'fee'], ['Bảo vệ mở tay', 'guard', 16]],
  sessions.map((s) => ({ id: s.id, card: s.card_uid, kind: s.card_kind === 'monthly' ? 'Vé tháng' : 'Vé lượt',
    plateIn: s.plate_in, plateOut: s.plate_out, timeIn: local(s.time_in), timeOut: local(s.time_out) || 'Đang gửi',
    fee: s.fee, guard: s.override_name ?? '' })));

  addSheet(wb, 'Bảng công', [['Bảo vệ', 'name', 22], ['Số ca', 'shifts'], ['Giờ làm', 'hours'], ['Số lần trễ', 'lateCount'],
    ['Phút trễ', 'lateMin'], ['Số lần về sớm', 'earlyCount'], ['Phút về sớm', 'earlyMin'], ['Quên chấm ra', 'missingOut']],
  summarize(attendance).map((g) => ({ ...g, hours: hours(g.workedMin) })));

  addSheet(wb, 'Chi tiết chấm công', [['Bảo vệ', 'name', 22], ['Ca', 'shift'], ['Vào', 'in', 20], ['Ra', 'out', 20],
    ['Trễ (phút)', 'late'], ['Về sớm (phút)', 'early'], ['Giờ làm', 'hours'], ['Cách chấm', 'method']],
  attendance.map((a) => {
    const s = attStat(a);
    return { name: a.guard_name, shift: a.shift_name ?? 'Ngoài ca', in: local(a.time_in),
      out: s.open ? 'Đang trực' : s.missingOut ? 'Quên chấm ra' : local(a.time_out), late: s.lateMin, early: s.earlyMin,
      hours: hours(s.workedMin), method: a.method_in === 'pin' ? 'PIN' : 'Vân tay' };
  }));
  return wb;
}

export function reportsRouter({ db }) {
  const router = Router();
  router.get('/reports/monthly.xlsx', async (req, res) => {
    const month = str(req.query.month);
    if (!MONTH_RE.test(month)) throw new HttpError(400, 'Tháng dạng YYYY-MM');
    const wb = await monthlyWorkbook(db, month);
    res.set({
      'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'content-disposition': `attachment; filename="bao-cao-${month}.xlsx"`,
    });
    res.send(Buffer.from(await wb.xlsx.writeBuffer()));
  });
  return router;
}
