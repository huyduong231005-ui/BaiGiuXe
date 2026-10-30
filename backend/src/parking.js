// Bãi xe: số chỗ trống, lượt gửi, lịch sử + doanh thu, mở cổng, cho xe ra khi mất thẻ, thẻ, cài đặt.
import { Router } from 'express';
import { HttpError, str } from './auth.js';
import { calcFee, minutesOf, nightsCrossed, normPlate } from './rules.js';

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const UID_RE = /^[0-9A-F]{8,20}$/;
const MAX_ROWS = 1000;
const MAX_REVENUE_DAYS = 366;

/** "2026-10-30" -> [00:00, 24:00) giờ địa phương. */
export function dayRange(date) {
  if (!DATE_RE.test(date)) throw new HttpError(400, 'Ngày dạng YYYY-MM-DD');
  const [y, m, d] = date.split('-').map(Number);
  return [new Date(y, m - 1, d), new Date(y, m - 1, d + 1)];
}

export const today = () => {
  const t = new Date();
  return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
};

export async function parkingStatus(db) {
  const { rows } = await db.query(
    `select s.capacity, count(x.id)::int as occupied from settings s
     left join sessions x on x.time_out is null group by s.capacity`);
  const { capacity, occupied } = rows[0];
  return { capacity, occupied, free: capacity - occupied };
}

const getSettings = async (db) => (await db.query('select * from settings where id = 1')).rows[0];

/** Phí nếu cho lượt gửi này ra vào thời điểm now. */
async function feeNow(db, session, now = new Date()) {
  const [card] = (await db.query('select kind from cards where uid = $1', [session.card_uid])).rows;
  return calcFee(session.time_in, now, await getSettings(db), card?.kind === 'monthly');
}

const openGate = (db, message) =>
  db.query("insert into gate_events (gate, kind, message) values ('out', 'open_cmd', $1) returning *", [message]);

/** Các API công khai: trang chủ hiển thị số chỗ trống, máy tính phí. */
export function publicRouter({ db }) {
  const router = Router();
  router.get('/status', async (_req, res) => res.json(await parkingStatus(db)));

  router.post('/fees/quote', async (req, res) => {
    const timeIn = new Date(req.body?.timeIn);
    const timeOut = req.body?.timeOut ? new Date(req.body.timeOut) : new Date();
    if (Number.isNaN(+timeIn) || Number.isNaN(+timeOut) || timeOut < timeIn) {
      throw new HttpError(400, 'timeIn / timeOut phải là thời điểm ISO 8601, giờ ra sau giờ vào');
    }
    const settings = await getSettings(db);
    const monthly = req.body?.kind === 'monthly';
    res.json({
      fee: calcFee(timeIn, timeOut, settings, monthly),
      nights: nightsCrossed(timeIn, timeOut, minutesOf(settings.night_mark)),
      monthly,
      priceDay: settings.price_day,
      priceNight: settings.price_night,
      nightMark: settings.night_mark.slice(0, 5),
    });
  });
  return router;
}

/** Xem lượt gửi, lịch sử, doanh thu, thẻ, cài đặt (quản lý + admin, kiểm ở app.js). */
export function viewRouter({ db }) {
  const router = Router();

  router.get('/sessions', async (req, res) => {
    const params = [];
    const where = [];
    if (req.query.open === 'true') {
      where.push('s.time_out is null');
    } else {
      const [from, to] = dayRange(str(req.query.date) || today());
      params.push(from, to);
      where.push('s.time_in >= $1 and s.time_in < $2');
    }
    const plate = normPlate(req.query.plate);
    if (plate) {
      params.push(`%${plate}%`);
      where.push(`(s.plate_in ilike $${params.length} or s.plate_out ilike $${params.length})`);
    }
    const { rows } = await db.query(
      `select s.*, c.kind as card_kind, c.owner as card_owner, g.name as override_name
       from sessions s left join cards c on c.uid = s.card_uid left join guards g on g.id = s.override_by
       where ${where.join(' and ')} order by s.time_in desc limit ${MAX_ROWS}`, params);
    res.json({ count: rows.length, revenue: rows.reduce((a, s) => a + (s.fee ?? 0), 0), sessions: rows });
  });

  router.get('/sessions/:id/fee', async (req, res) => {
    const [s] = (await db.query('select * from sessions where id = $1', [Number(req.params.id) || 0])).rows;
    if (!s) throw new HttpError(404, 'Không có lượt gửi này');
    if (s.time_out) return res.json({ fee: s.fee, closed: true });
    res.json({ fee: await feeNow(db, s), closed: false });
  });

  router.get('/events', async (req, res) => {
    const limit = Math.min(Math.max(Number(req.query.limit) || 20, 1), 200);
    const { rows } = await db.query(
      `select e.*, g.name as guard_name from gate_events e left join guards g on g.id = e.guard_id
       order by e.id desc limit ${limit}`);
    res.json(rows);
  });

  // Doanh thu theo ngày (theo giờ ra), mặc định 7 ngày gần nhất.
  router.get('/stats/revenue', async (req, res) => {
    const to = str(req.query.to) || today();
    const [, end] = dayRange(to);
    const [start] = dayRange(str(req.query.from) || today());
    if (!req.query.from) start.setDate(start.getDate() - 6);
    if (start >= end || (end - start) / 864e5 > MAX_REVENUE_DAYS) {
      throw new HttpError(400, `Khoảng ngày không hợp lệ (tối đa ${MAX_REVENUE_DAYS} ngày)`);
    }
    // Gom theo ngày ở múi giờ của API (Postgres của Supabase chạy UTC).
    const { rows } = await db.query(
      `select to_char(time_out at time zone $3, 'YYYY-MM-DD') as day,
              count(*)::int as sessions, coalesce(sum(fee), 0)::int as revenue
       from sessions where time_out >= $1 and time_out < $2 group by 1 order by 1`,
      [start, end, Intl.DateTimeFormat().resolvedOptions().timeZone]);
    res.json({ total: rows.reduce((a, r) => a + r.revenue, 0), days: rows });
  });

  // Màn thêm thẻ hỏi định kỳ: thẻ vừa quẹt ở cổng bất kỳ sau mốc since (thay cho Realtime).
  router.get('/scans/latest', async (req, res) => {
    const since = new Date(str(req.query.since) || 0);
    if (Number.isNaN(+since)) throw new HttpError(400, 'since phải là thời điểm ISO 8601');
    const [e] = (await db.query(
      `select e.uid, e.gate, e.created_at, c.uid is not null as registered from gate_events e
       left join cards c on c.uid = e.uid
       where e.kind = 'scan' and e.uid is not null and e.created_at > $1 order by e.id desc limit 1`, [since])).rows;
    res.json(e ?? null);
  });

  router.get('/cards', async (req, res) => {
    const q = `%${str(req.query.q).toUpperCase()}%`;
    const { rows } = await db.query(
      `select * from cards where uid like $1 or upper(coalesce(plate, '')) like $1 or upper(coalesce(owner, '')) like $1
       order by created_at desc`, [q]);
    res.json(rows);
  });

  router.get('/settings', async (_req, res) => res.json(await getSettings(db)));
  return router;
}

function cardRow(body, uid) {
  const kind = body?.kind ?? 'guest';
  if (!['guest', 'monthly'].includes(kind)) throw new HttpError(400, 'Loại vé là guest hoặc monthly');
  const plate = normPlate(body?.plate) || null;
  if (kind === 'monthly' && !plate) throw new HttpError(400, 'Vé tháng cần biển số');
  if (!UID_RE.test(uid)) throw new HttpError(400, 'UID phải là 8-20 ký tự hex (0-9, A-F)');
  return [uid, kind, plate, str(body?.owner) || null, body?.active !== false];
}

export function manageRouter({ db }) {
  const router = Router();

  // Mất thẻ / xử lý tay: tính phí tới bây giờ, đóng lượt gửi, ra lệnh mở barrier cổng ra.
  router.post('/sessions/:id/release', async (req, res) => {
    const [s] = (await db.query('select * from sessions where id = $1', [Number(req.params.id) || 0])).rows;
    if (!s) throw new HttpError(404, 'Không có lượt gửi này');
    if (s.time_out) throw new HttpError(409, 'Lượt gửi đã kết thúc');
    const fee = await feeNow(db, s);
    const { rows } = await db.query(
      'update sessions set time_out = now(), fee = $2 where id = $1 and time_out is null returning *', [s.id, fee]);
    if (!rows.length) throw new HttpError(409, 'Lượt gửi vừa được đóng ở nơi khác');
    await openGate(db, `Cho ra thu cong boi ${req.user.username}`);
    res.json({ session: rows[0], fee });
  });

  // ĐT camera cổng ra nghe gate_events(open_cmd) qua Realtime rồi gửi lệnh MQTT cho ESP32.
  router.post('/gate/open', async (req, res) => {
    const { rows } = await openGate(db, `Lenh tu API boi ${req.user.username}`);
    res.status(201).json(rows[0]);
  });

  router.post('/cards', async (req, res) => {
    const row = cardRow(req.body, str(req.body?.uid).toUpperCase());
    const { rows } = await db.query(
      'insert into cards (uid, kind, plate, owner, active) values ($1, $2, $3, $4, $5) returning *', row);
    res.status(201).json(rows[0]);
  });

  router.patch('/cards/:uid', async (req, res) => {
    const uid = req.params.uid.toUpperCase();
    const [old] = (await db.query('select * from cards where uid = $1', [uid])).rows;
    if (!old) throw new HttpError(404, 'Không có thẻ này');
    const row = cardRow({ ...old, ...req.body }, uid);
    const { rows } = await db.query(
      'update cards set kind = $2, plate = $3, owner = $4, active = $5 where uid = $1 returning *', row);
    res.json(rows[0]);
  });

  router.delete('/cards/:uid', async (req, res) => {
    const { rowCount } = await db.query('delete from cards where uid = $1', [req.params.uid.toUpperCase()]);
    if (!rowCount) throw new HttpError(404, 'Không có thẻ này');
    res.status(204).end();
  });

  router.put('/settings', async (req, res) => {
    const [capacity, priceDay, priceNight] = ['capacity', 'priceDay', 'priceNight'].map((k) => req.body?.[k]);
    const nightMark = str(req.body?.nightMark);
    if (![capacity, priceDay, priceNight].every(Number.isInteger) || capacity <= 0 || priceDay < 0 || priceNight < 0) {
      throw new HttpError(400, 'Sức chứa > 0, giá ≥ 0 (số nguyên)');
    }
    if (!TIME_RE.test(nightMark)) throw new HttpError(400, 'Mốc đêm dạng HH:MM');
    const { rows } = await db.query(
      'update settings set capacity = $1, price_day = $2, price_night = $3, night_mark = $4 where id = 1 returning *',
      [capacity, priceDay, priceNight, nightMark]);
    res.json(rows[0]);
  });
  return router;
}
