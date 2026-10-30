// Bảo vệ (PIN băm bcrypt trong Postgres), ca trực, bảng công.
import { Router } from 'express';
import { HttpError, str } from './auth.js';
import { attStat, summarize } from './rules.js';

const PIN_RE = /^\d{4,8}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const MONTH_RE = /^\d{4}-\d{2}$/;
const MAX_FINGER_ID = 300;

/** "2026-10" -> [đầu tháng, đầu tháng sau) giờ địa phương; mặc định tháng hiện tại. */
function monthRange(month) {
  const now = new Date();
  const m = str(month) || `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  if (!MONTH_RE.test(m)) throw new HttpError(400, 'Tháng dạng YYYY-MM');
  const [y, mo] = m.split('-').map(Number);
  return { month: m, from: new Date(y, mo - 1, 1), to: new Date(y, mo, 1) };
}

/** Bảng công một tháng; truyền guardId để chỉ lấy của một bảo vệ. */
async function attendanceReport(db, month, guardId = null) {
  const { from, to, month: m } = monthRange(month);
  const { rows } = await db.query(
    `select a.*, g.name as guard_name from attendance a join guards g on g.id = a.guard_id
     where a.time_in >= $1 and a.time_in < $2 and ($3::int is null or a.guard_id = $3) order by a.time_in desc`,
    [from, to, guardId]);
  return { month: m, summary: summarize(rows), records: rows.map((r) => ({ ...r, ...attStat(r) })) };
}

export function meAttendance({ db }) {
  return async (req, res) => {
    if (!req.user.guard_id) throw new HttpError(404, 'Tài khoản chưa được gắn với hồ sơ bảo vệ');
    res.json(await attendanceReport(db, req.query.month, req.user.guard_id));
  };
}

function guardInput(body, isNew) {
  const name = str(body?.name);
  const pin = typeof body?.pin === 'string' ? body.pin : '';
  if (isNew && !name) throw new HttpError(400, 'Cần nhập tên bảo vệ');
  // Không có PIN thì không mở cổng bằng phím A và không đăng ký vân tay được (phím B cần PIN).
  if ((isNew || pin) && !PIN_RE.test(pin)) throw new HttpError(400, 'PIN phải gồm 4-8 chữ số');
  const finger = body?.fingerId;
  if (finger != null && !(Number.isInteger(finger) && finger >= 1 && finger <= MAX_FINGER_ID)) {
    throw new HttpError(400, `ID vân tay là số 1-${MAX_FINGER_ID}`);
  }
  return { name, pin, finger };
}

const publicGuard = ({ pin_hash: pinHash, ...g }) => ({ ...g, has_pin: Boolean(pinHash) });

export function guardsRouter({ db }) {
  const router = Router();

  router.get('/guards', async (_req, res) => {
    const { rows } = await db.query(
      `select g.*, a.shift_name as on_duty_shift, a.time_in as on_duty_since from guards g
       left join attendance a on a.guard_id = g.id and a.time_out is null order by g.id`);
    res.json(rows.map(publicGuard));
  });

  router.post('/guards', async (req, res) => {
    const { name, pin, finger } = guardInput(req.body, true);
    const { rows } = await db.query(
      `insert into guards (name, finger_id, pin_hash) values ($1, $2, extensions.crypt($3, extensions.gen_salt('bf')))
       returning *`, [name, finger ?? null, pin]);
    res.status(201).json(publicGuard(rows[0]));
  });

  router.patch('/guards/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    const { name, pin, finger } = guardInput(req.body, false);
    const { rows } = await db.query(
      `update guards set name = coalesce(nullif($2, ''), name),
         finger_id = case when $3 then $4 else finger_id end,
         pin_hash = case when $5 = '' then pin_hash else extensions.crypt($5, extensions.gen_salt('bf')) end
       where id = $1 returning *`, [id, name, req.body && 'fingerId' in req.body, finger ?? null, pin]);
    if (!rows.length) throw new HttpError(404, 'Không có bảo vệ này');
    res.json(publicGuard(rows[0]));
  });

  router.delete('/guards/:id', async (req, res) => {
    const { rowCount } = await db.query('delete from guards where id = $1', [Number(req.params.id) || 0]);
    if (!rowCount) throw new HttpError(404, 'Không có bảo vệ này');
    res.status(204).end();
  });

  // Ca trực: end_time <= start_time là ca qua đêm.
  router.get('/shifts', async (_req, res) => res.json((await db.query('select * from shift_defs order by start_time')).rows));

  const shiftInput = (body) => {
    const [name, start, end] = [str(body?.name), str(body?.startTime), str(body?.endTime)];
    if (!name) throw new HttpError(400, 'Cần nhập tên ca');
    if (!TIME_RE.test(start) || !TIME_RE.test(end)) throw new HttpError(400, 'Giờ bắt đầu / kết thúc dạng HH:MM');
    return [name, start, end];
  };

  router.post('/shifts', async (req, res) => {
    const { rows } = await db.query(
      'insert into shift_defs (name, start_time, end_time) values ($1, $2, $3) returning *', shiftInput(req.body));
    res.status(201).json(rows[0]);
  });

  router.put('/shifts/:id', async (req, res) => {
    const { rows } = await db.query(
      'update shift_defs set name = $2, start_time = $3, end_time = $4 where id = $1 returning *',
      [Number(req.params.id) || 0, ...shiftInput(req.body)]);
    if (!rows.length) throw new HttpError(404, 'Không có ca này');
    res.json(rows[0]);
  });

  router.delete('/shifts/:id', async (req, res) => {
    // Bảng công cũ vẫn giữ tên ca đã chép (shift_name), shift_id về null.
    const { rowCount } = await db.query('delete from shift_defs where id = $1', [Number(req.params.id) || 0]);
    if (!rowCount) throw new HttpError(404, 'Không có ca này');
    res.status(204).end();
  });

  router.get('/attendance', async (req, res) => res.json(await attendanceReport(db, req.query.month)));
  return router;
}
