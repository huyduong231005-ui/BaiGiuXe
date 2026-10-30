// API cho điện thoại camera ở cổng (đăng nhập tài khoản quản lý). ĐT camera chỉ nhận sự kiện ESP32, chụp + đọc
// biển rồi gọi API; mọi kiểm tra và ghi dữ liệu (lượt gửi, nhật ký, chấm công) nằm ở đây. Kết quả trả về có sẵn
// 2 dòng chữ cho OLED (ASCII không dấu, tối đa 21 ký tự) để ĐT gửi thẳng cho ESP32.
import express, { Router } from 'express';
import { HttpError, str } from './auth.js';
import { Attendance, Card, GateEvent, Guard, insert, PlateImage, row, Session, ShiftDef } from './db.js';
import { findGuard } from './guards.js';
import { closeSession, feeNow, getSettings, parkingStatus } from './parking.js';
import { IMG_PATH_RE } from './plates.js';
import { decideEntry, decideExit, hm, MAX_SHIFT_MS, nearestShift, normPlate, oledName } from './rules.js';

const MAX_IMAGE = '2mb';
const COMMAND_TTL_MS = 30_000; // lệnh mở cổng cũ hơn 30 giây thì bỏ (ĐT cổng ra mất mạng lúc đó)
const DUPLICATE_KEY = 11000;

const log = (data) => insert(GateEvent, { gate: 'out', status: 'done', ...data });
const plateRead = (b) => ({
  plate: normPlate(b?.plate) || null,
  score: typeof b?.score === 'number' ? b.score : 0,
  candidates: Array.isArray(b?.candidates) ? b.candidates.map(normPlate).filter(Boolean) : [],
  img: IMG_PATH_RE.test(str(b?.img)) ? str(b.img) : null,
});

/** Xe vào: kiểm tra rồi mở lượt gửi. Trùng index (2 lượt quẹt cùng lúc) thì coi như xe đã trong bãi. */
async function enter(uid, read, now) {
  const [card, open, status, parked] = await Promise.all([
    Card.findOne({ uid }).lean(),
    Session.exists({ card_uid: uid, parked: true }),
    parkingStatus(),
    Session.find({ parked: true, plate_in: { $type: 'string' } }, { plate_in: 1 }).lean(),
  ]);
  const d = decideEntry({ card, hasOpenSession: Boolean(open), free: status.free, ...read,
    parkedPlates: parked.map((s) => s.plate_in), now });
  if (!d.ok) return d;
  try {
    await insert(Session, { card_uid: uid, plate_in: read.plate, img_in: read.img, time_in: now });
  } catch (err) {
    if (err.code !== DUPLICATE_KEY) throw err;
    return { ok: false, open: false, message: 'Xe da o trong bai' };
  }
  return d;
}

/** Xe ra: biển ra phải khớp biển lúc vào, đóng lượt kèm phí. */
async function leave(uid, read, now) {
  const [card, session, settings] = await Promise.all([
    Card.findOne({ uid }).lean(), Session.findOne({ card_uid: uid, parked: true }).lean(), getSettings(),
  ]);
  const d = decideExit({ card, session, ...read, now, settings });
  if (!d.ok) return d;
  const closed = await closeSession(session._id, { plate_out: read.plate, img_out: read.img, fee: d.fee });
  return closed ? d : { ok: false, open: false, message: 'Luot gui da dong' };
}

export function gateRouter() {
  const router = Router();

  // Một lượt quẹt thẻ: { gate: in|out, uid, plate, score, candidates, img } -> quyết định + 2 dòng OLED + chỗ trống.
  router.post('/gate/scan', async (req, res) => {
    const gate = req.body?.gate;
    if (!['in', 'out'].includes(gate)) throw new HttpError(400, 'gate là in hoặc out');
    const uid = str(req.body?.uid).toUpperCase();
    if (!uid) throw new HttpError(400, 'Thiếu UID thẻ');
    const read = plateRead(req.body);
    const now = new Date();
    const d = await (gate === 'in' ? enter : leave)(uid, read, now);
    await insert(GateEvent, { gate, kind: 'scan', uid, status: d.ok ? 'ok' : 'denied', plate: read.plate, img: read.img,
      message: d.message, open: d.open });
    res.json({ ...d, l1: read.plate ?? (d.ok ? 'OK' : 'TU CHOI'), l2: d.message, status: await parkingStatus() });
  });

  // Bảo vệ ở cổng ra: PIN (phím A) hoặc vân tay. enroll = phím B (PIN đúng thì ESP32 đăng ký vân tay vào ô = ID).
  // denied = lượt bị từ chối gần đây (ĐT giữ 60 giây): mở tay thì đóng lượt gửi đó, ghi tên bảo vệ.
  router.post('/gate/auth', async (req, res) => {
    const { pin, finger, enroll, denied } = req.body ?? {};
    const guard = await findGuard(pin, finger);
    if (pin != null && !guard) {
      await log({ kind: 'override', status: 'denied', message: enroll ? 'Sai PIN (dang ky van tay)' : 'Sai PIN' });
      return res.json({ ok: false, guardId: null, message: 'Sai PIN bao ve' });
    }
    if (enroll) return res.json({ ok: true, guardId: guard.id, message: `Bao ve #${guard.id} dang ky van tay` });
    let message = pin != null ? `PIN bao ve #${guard.id}` : `Van tay #${finger}${guard ? '' : ' (chua gan bao ve)'}`;
    const uid = str(denied?.uid).toUpperCase();
    const s = uid && (await Session.findOne({ card_uid: uid, parked: true }).lean());
    if (s) {
      const fee = await feeNow(s);
      const read = plateRead(denied);
      if (await closeSession(s._id, { plate_out: read.plate, img_out: read.img, fee, override_by: guard?.id ?? null })) {
        message += ` | the ${uid} | Phi: ${fee}d`;
      }
    }
    await log({ kind: 'override', guard_id: guard?.id ?? null, message });
    res.json({ ok: true, guardId: guard?.id ?? null, message });
  });

  // ESP32 vừa lưu vân tay vào ô id (= ID bảo vệ): gán cho bảo vệ đó, gỡ khỏi bảo vệ khác đang giữ số này.
  router.post('/gate/enrolled', async (req, res) => {
    const id = Number(req.body?.id) || 0;
    if (!(await Guard.exists({ _id: id }))) throw new HttpError(404, 'Không có bảo vệ này');
    await Guard.updateMany({ finger_id: id, _id: { $ne: id } }, { finger_id: null });
    await Guard.updateOne({ _id: id }, { finger_id: id });
    await log({ kind: 'override', guard_id: id, message: `Dang ky van tay #${id}` });
    res.json({ ok: true, message: `Da dang ky van tay cho bao ve #${id}` });
  });

  // Chấm công (phím C): chưa trong ca -> vào ca gần nhất theo lịch; đang trong ca -> ra ca.
  // Ca mở quá 16 giờ coi như quên chấm ra: đóng ở giờ hết ca (method_out = auto) rồi mở ca mới.
  router.post('/gate/punch', async (req, res) => {
    const { pin, finger } = req.body ?? {};
    const guard = await findGuard(pin, finger);
    if (!guard) {
      if (pin != null) await log({ kind: 'override', status: 'denied', message: 'Sai PIN (cham cong)' });
      return res.json({ ok: false, pinWrong: pin != null, l1: 'KHONG RO', l2: pin != null ? 'Sai PIN' : `Van tay #${finger} chua gan` });
    }
    const now = new Date();
    const method = pin != null ? 'pin' : 'finger';
    const name = oledName(guard.name);
    const open = await Attendance.findOne({ guard_id: guard.id, on_duty: true }).lean();
    let l1, l2, message;
    if (open && now - open.time_in < MAX_SHIFT_MS) {
      await Attendance.updateOne({ _id: open._id }, { time_out: now, method_out: method, on_duty: false });
      const early = open.shift_end ? Math.floor((open.shift_end - now) / 60e3) : 0;
      [l1, l2] = ['RA CA', `${name} ${hm(now)}${early > 0 ? ` som ${early}p` : ''}`];
      message = `Ra ca: ${open.shift_name ?? '-'}${early > 0 ? ` (ve som ${early}p)` : ''}`;
    } else {
      if (open) {
        await Attendance.updateOne({ _id: open._id }, { time_out: open.shift_end ?? open.time_in, method_out: 'auto', on_duty: false });
      }
      const s = nearestShift(await ShiftDef.find().lean(), now);
      await insert(Attendance, { guard_id: guard.id, shift_id: s?.def._id ?? null, shift_name: s?.def.name ?? null,
        shift_start: s?.start ?? null, shift_end: s?.end ?? null, time_in: now, method_in: method });
      const late = s ? Math.floor((now - s.start) / 60e3) : 0;
      [l1, l2] = ['VAO CA', `${name} ${hm(now)}${late > 0 ? ` tre ${late}p` : ''}`];
      message = `Vao ca: ${s?.def.name ?? '-'}${late > 0 ? ` (tre ${late}p)` : ''}`;
    }
    await log({ kind: 'override', guard_id: guard.id, message });
    res.json({ ok: true, l1, l2, message: `${guard.name} | ${message}` });
  });

  router.post('/gate/emergency', async (req, res) => {
    res.status(201).json(await log({ kind: 'emergency', message: req.body?.on === true ? 'Bat khan cap' : 'Tat khan cap' }));
  });

  // Lệnh "Mở cổng ra" từ app quản lý: ĐT cổng ra hỏi định kỳ (thay cho Realtime của Supabase).
  router.get('/gate/commands', async (_req, res) => {
    const list = await GateEvent.find({ kind: 'open_cmd', status: 'pending', created_at: { $gt: new Date(Date.now() - COMMAND_TTL_MS) } })
      .sort({ _id: 1 }).lean();
    res.json(list.map(row));
  });

  router.post('/gate/commands/:id/done', async (req, res) => {
    const e = await GateEvent.findOneAndUpdate({ _id: Number(req.params.id) || 0, kind: 'open_cmd' }, { status: 'done' }, { new: true }).lean();
    if (!e) throw new HttpError(404, 'Không có lệnh này');
    res.json(row(e));
  });

  // Ảnh lượt quẹt (đã thu nhỏ), tải lên sau khi cổng đã có kết quả.
  router.put('/gate/images', express.raw({ type: 'image/*', limit: MAX_IMAGE }), async (req, res) => {
    const path = str(req.query.path);
    if (!IMG_PATH_RE.test(path)) throw new HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    if (!Buffer.isBuffer(req.body) || !req.body.length) throw new HttpError(400, 'Gửi ảnh JPEG với Content-Type: image/jpeg');
    await PlateImage.updateOne({ path }, { data: req.body, created_at: new Date() }, { upsert: true });
    res.status(204).end();
  });
  return router;
}
