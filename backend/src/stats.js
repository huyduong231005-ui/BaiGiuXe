// Thống kê: doanh thu theo ngày / tháng (vé lượt + vé tháng, theo loại xe) và tốc độ / độ chính xác nhận diện biển.
import { Router } from 'express';
import { HttpError, str } from './auth.js';
import { GateEvent, Payment, Session } from './db.js';
import { vehicleTypes } from './lot.js';
import { dayRange, today, ymd } from './parking.js';
import { MIN_PLATE_SCORE } from './rules.js';

const MAX_DAYS = 366;
const MAX_MONTHS = 36;
const DEFAULT_DAYS = 30;
const DEFAULT_MONTHS = 12;
const OCR_DAYS = 30;
const MONTH_RE = /^\d{4}-\d{2}$/;

const ym = (d) => ymd(d).slice(0, 7);

/** Khoảng thời gian + danh sách kỳ (ngày hoặc tháng) để biểu đồ không bị thủng ở kỳ không có tiền. */
function periods(group, fromQ, toQ) {
  if (group === 'month') {
    const now = new Date();
    const to = toQ || ym(now);
    const from = fromQ || ym(new Date(now.getFullYear(), now.getMonth() - DEFAULT_MONTHS + 1, 1));
    if (!MONTH_RE.test(from) || !MONTH_RE.test(to)) throw new HttpError(400, 'Tháng dạng YYYY-MM');
    const [fy, fm] = from.split('-').map(Number), [ty, tm] = to.split('-').map(Number);
    const start = new Date(fy, fm - 1, 1), end = new Date(ty, tm, 1);
    const keys = [];
    for (let d = new Date(start); d < end; d = new Date(d.getFullYear(), d.getMonth() + 1, 1)) keys.push(ym(d));
    if (!keys.length || keys.length > MAX_MONTHS) throw new HttpError(400, `Khoảng tháng không hợp lệ (tối đa ${MAX_MONTHS})`);
    return { start, end, keys, key: ym };
  }
  const [, end] = dayRange(toQ || today());
  const [start] = dayRange(fromQ || today());
  if (!fromQ) start.setDate(start.getDate() - DEFAULT_DAYS + 1);
  const keys = [];
  for (let d = new Date(start); d < end; d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) keys.push(ymd(d));
  if (!keys.length || keys.length > MAX_DAYS) throw new HttpError(400, `Khoảng ngày không hợp lệ (tối đa ${MAX_DAYS} ngày)`);
  return { start, end, keys, key: ymd };
}

/** Doanh thu theo kỳ: vé lượt (phí lúc xe ra) + vé tháng (khoản thu khi duyệt đơn), kèm tổng theo loại xe. */
export async function revenue(group = 'day', from = '', to = '') {
  const { start, end, keys, key } = periods(group, from, to);
  const [sessions, payments, types] = await Promise.all([
    Session.find({ time_out: { $gte: start, $lt: end } }, { time_out: 1, fee: 1, vehicle_type: 1 }).lean(),
    Payment.find({ created_at: { $gte: start, $lt: end } }).lean(),
    vehicleTypes(),
  ]);
  const rows = new Map(keys.map((k) => [k, { period: k, sessions: 0, visitor: 0, monthly: 0, total: 0 }]));
  const byType = new Map();
  const typeRow = (code) => byType.get(code) ?? byType.set(code, {
    vehicle_type: code, name: types[code]?.name ?? code, sessions: 0, visitor: 0, monthly: 0 }).get(code);
  for (const s of sessions) {
    const r = rows.get(key(s.time_out));
    r.sessions++;
    r.visitor += s.fee ?? 0;
    const t = typeRow(s.vehicle_type ?? 'motorbike');
    t.sessions++;
    t.visitor += s.fee ?? 0;
  }
  for (const p of payments) {
    rows.get(key(p.created_at)).monthly += p.amount;
    typeRow(p.vehicle_type ?? 'motorbike').monthly += p.amount;
  }
  const list = [...rows.values()].map((r) => ({ ...r, total: r.visitor + r.monthly }));
  const sum = (k) => list.reduce((a, r) => a + r[k], 0);
  return { group, total: sum('total'), visitor: sum('visitor'), monthly: sum('monthly'), sessions: sum('sessions'),
    rows: list, byType: [...byType.values()] };
}

const avg = (xs) => (xs.length ? Math.round(xs.reduce((a, b) => a + b, 0) / xs.length) : null);
const pct = (xs, p) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)];
};
const rate = (n, d) => (d ? Math.round((n / d) * 1000) / 10 : null); // phần trăm, 1 chữ số thập phân

/**
 * Nhận diện biển trong N ngày gần nhất, từ nhật ký quẹt thẻ:
 * - Tốc độ: thời gian chụp + OCR, thời gian từ lúc quẹt tới lúc ESP32 có kết quả (trung bình, trung vị, p95).
 * - Độ chính xác: đọc được ngay lần chụp đầu, độ tin cậy trung bình, tỉ lệ biển lúc ra khớp biển lúc vào.
 */
export async function ocrStats(days = OCR_DAYS) {
  const since = new Date(Date.now() - days * 864e5);
  const scans = await GateEvent.find({ kind: 'scan', created_at: { $gte: since } }).sort({ _id: -1 }).lean();
  const measured = scans.filter((e) => e.ocr_ms != null);
  const read = scans.filter((e) => e.plate);
  const firstShot = measured.filter((e) => e.shots === 1 && e.plate && e.score >= MIN_PLATE_SCORE);
  const exits = scans.filter((e) => e.gate === 'out' && e.plate && e.message !== 'Khong co luot gui');
  const mismatched = exits.filter((e) => e.message === 'Sai bien so');
  const ms = (k) => measured.map((e) => e[k]).filter((v) => v != null);
  return {
    days,
    scans: scans.length,
    readRate: rate(read.length, scans.length),
    firstShotRate: rate(firstShot.length, measured.length),
    avgScore: read.length ? Math.round((read.reduce((a, e) => a + (e.score ?? 0), 0) / read.length) * 1000) / 1000 : null,
    ocrMs: { avg: avg(ms('ocr_ms')), p50: pct(ms('ocr_ms'), 50), p95: pct(ms('ocr_ms'), 95) },
    totalMs: { avg: avg(ms('total_ms')), p50: pct(ms('total_ms'), 50), p95: pct(ms('total_ms'), 95) },
    exits: exits.length,
    exitMatchRate: rate(exits.length - mismatched.length, exits.length),
    reasons: Object.entries(scans.filter((e) => e.status === 'denied').reduce((a, e) => ({ ...a, [e.message]: (a[e.message] ?? 0) + 1 }), {}))
      .map(([message, count]) => ({ message, count })).sort((a, b) => b.count - a.count),
    recent: measured.slice(0, 20).map((e) => ({ at: e.created_at, gate: e.gate, plate: e.plate, score: e.score, shots: e.shots,
      ocr_ms: e.ocr_ms, total_ms: e.total_ms, vehicle_type: e.vehicle_type, message: e.message })),
  };
}

export function statsRouter() {
  const router = Router();
  router.get('/stats/revenue', async (req, res) => {
    const group = str(req.query.group) || 'day';
    if (!['day', 'month'].includes(group)) throw new HttpError(400, 'group là day hoặc month');
    res.json(await revenue(group, str(req.query.from), str(req.query.to)));
  });
  router.get('/stats/ocr', async (req, res) => {
    const days = Math.min(Math.max(Number(req.query.days) || OCR_DAYS, 1), 365);
    res.json(await ocrStats(days));
  });
  return router;
}
