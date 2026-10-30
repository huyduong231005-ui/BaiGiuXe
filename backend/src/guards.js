// Bảo vệ (PIN băm bcrypt), ca trực, bảng công.
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { HttpError, str } from './auth.js';
import { Attendance, GateEvent, Guard, insert, row, Session, ShiftDef, User } from './db.js';
import { attStat, summarize } from './rules.js';

const PIN_RE = /^\d{4,8}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const MONTH_RE = /^\d{4}-\d{2}$/;
const MAX_FINGER_ID = 300;

export const IN_USE = 'Dữ liệu đang được dùng ở nơi khác (đã có lịch sử), không xoá được';

/** "2026-10" -> [đầu tháng, đầu tháng sau) giờ địa phương; mặc định tháng hiện tại. */
function monthRange(month) {
  const now = new Date();
  const m = str(month) || `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  if (!MONTH_RE.test(m)) throw new HttpError(400, 'Tháng dạng YYYY-MM');
  const [y, mo] = m.split('-').map(Number);
  return { month: m, from: new Date(y, mo - 1, 1), to: new Date(y, mo, 1) };
}

/** Lượt chấm công trong [from, to) kèm guard_name, mới nhất trước (sort = -1) hoặc cũ nhất trước (1). */
export async function attendanceRows(from, to, guardId = null, sort = -1) {
  const list = await Attendance.find({ time_in: { $gte: from, $lt: to }, ...(guardId ? { guard_id: guardId } : {}) })
    .sort({ time_in: sort }).lean();
  const names = await guardNames(list.map((a) => a.guard_id));
  return list.filter((a) => names.has(a.guard_id)).map((a) => ({ ...row(a), guard_name: names.get(a.guard_id) }));
}

/** id bảo vệ -> tên (bỏ qua id null). */
export async function guardNames(ids) {
  const wanted = [...new Set(ids.filter((id) => id != null))];
  const guards = wanted.length ? await Guard.find({ _id: { $in: wanted } }, { name: 1 }).lean() : [];
  return new Map(guards.map((g) => [g._id, g.name]));
}

/** Bảng công một tháng; truyền guardId để chỉ lấy của một bảo vệ. */
async function attendanceReport(month, guardId = null) {
  const { from, to, month: m } = monthRange(month);
  const rows = await attendanceRows(from, to, guardId);
  return { month: m, summary: summarize(rows), records: rows.map((r) => ({ ...r, ...attStat(r) })) };
}

export function meAttendance() {
  return async (req, res) => {
    if (!req.user.guard_id) throw new HttpError(404, 'Tài khoản chưa được gắn với hồ sơ bảo vệ');
    res.json(await attendanceReport(req.query.month, req.user.guard_id));
  };
}

/** Bảo vệ theo id vân tay trên AS608 hoặc PIN; null nếu không khớp. */
export async function findGuard(pin, finger) {
  if (Number.isInteger(finger)) return row(await Guard.findOne({ finger_id: finger }).lean());
  if (typeof pin !== 'string' || !pin) return null;
  // ponytail: so bcrypt lần lượt từng bảo vệ, đủ nhanh với vài chục người; khoá sai PIN nằm ở ESP32.
  for (const g of await Guard.find({ pin_hash: { $type: 'string' } }).lean()) {
    if (await bcrypt.compare(pin, g.pin_hash)) return row(g);
  }
  return null;
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

export function guardsRouter() {
  const router = Router();

  router.get('/guards', async (_req, res) => {
    const [guards, onDuty] = await Promise.all([
      Guard.find().sort({ _id: 1 }).lean(),
      Attendance.find({ on_duty: true }).lean(),
    ]);
    const duty = new Map(onDuty.map((a) => [a.guard_id, a]));
    res.json(guards.map((g) => publicGuard({
      ...row(g), on_duty_shift: duty.get(g._id)?.shift_name ?? null, on_duty_since: duty.get(g._id)?.time_in ?? null,
    })));
  });

  router.post('/guards', async (req, res) => {
    const { name, pin, finger } = guardInput(req.body, true);
    const guard = await insert(Guard, { name, finger_id: finger ?? null, pin_hash: await bcrypt.hash(pin, 10) });
    res.status(201).json(publicGuard(guard));
  });

  router.patch('/guards/:id', async (req, res) => {
    const { name, pin, finger } = guardInput(req.body, false);
    const changes = {
      ...(name ? { name } : {}),
      ...(req.body && 'fingerId' in req.body ? { finger_id: finger ?? null } : {}),
      ...(pin ? { pin_hash: await bcrypt.hash(pin, 10) } : {}),
    };
    const guard = row(await Guard.findByIdAndUpdate(Number(req.params.id) || 0, changes, { new: true }).lean());
    if (!guard) throw new HttpError(404, 'Không có bảo vệ này');
    res.json(publicGuard(guard));
  });

  // Còn lịch sử (lượt mở tay, chấm công, nhật ký cổng) thì không xoá được, như khoá ngoại cũ.
  router.delete('/guards/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    if (!(await Guard.exists({ _id: id }))) throw new HttpError(404, 'Không có bảo vệ này');
    const used = await Promise.all([
      Session.exists({ override_by: id }), Attendance.exists({ guard_id: id }), GateEvent.exists({ guard_id: id }),
    ]);
    if (used.some(Boolean)) throw new HttpError(409, IN_USE);
    await Guard.deleteOne({ _id: id });
    await User.updateMany({ guard_id: id }, { guard_id: null });
    res.status(204).end();
  });

  // Ca trực: end_time <= start_time là ca qua đêm. Giờ lưu dạng HH:MM:SS như cột time của Postgres.
  router.get('/shifts', async (_req, res) =>
    res.json((await ShiftDef.find().sort({ start_time: 1 }).lean()).map(row)));

  const shiftInput = (body) => {
    const [name, start, end] = [str(body?.name), str(body?.startTime), str(body?.endTime)];
    if (!name) throw new HttpError(400, 'Cần nhập tên ca');
    if (!TIME_RE.test(start) || !TIME_RE.test(end)) throw new HttpError(400, 'Giờ bắt đầu / kết thúc dạng HH:MM');
    return { name, start_time: `${start}:00`, end_time: `${end}:00` };
  };

  router.post('/shifts', async (req, res) => res.status(201).json(await insert(ShiftDef, shiftInput(req.body))));

  router.put('/shifts/:id', async (req, res) => {
    const shift = row(await ShiftDef.findByIdAndUpdate(Number(req.params.id) || 0, shiftInput(req.body), { new: true }).lean());
    if (!shift) throw new HttpError(404, 'Không có ca này');
    res.json(shift);
  });

  router.delete('/shifts/:id', async (req, res) => {
    // Bảng công cũ vẫn giữ tên ca đã chép (shift_name), shift_id về null.
    const id = Number(req.params.id) || 0;
    if (!(await ShiftDef.findByIdAndDelete(id))) throw new HttpError(404, 'Không có ca này');
    await Attendance.updateMany({ shift_id: id }, { shift_id: null });
    res.status(204).end();
  });

  router.get('/attendance', async (req, res) => res.json(await attendanceReport(req.query.month)));
  return router;
}
