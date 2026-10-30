// API cho điện thoại camera ở cổng (đăng nhập tài khoản quản lý). Trước đây ĐT camera ghi thẳng Supabase;
// quyết định cho xe vào / ra vẫn tính trên điện thoại (logic.dart) để trả kết quả cho ESP32 nhanh nhất.
import express, { Router } from 'express';
import { HttpError, str } from './auth.js';
import { Attendance, Card, GateEvent, Guard, insert, PlateImage, row, Session } from './db.js';
import { findGuard } from './guards.js';
import { closeSession, feeNow, getSettings, parkingStatus } from './parking.js';
import { IMG_PATH_RE } from './plates.js';
import { normPlate } from './rules.js';

const MAX_IMAGE = '2mb';
const COMMAND_TTL_MS = 30_000; // lệnh mở cổng cũ hơn 30 giây thì bỏ (ĐT cổng ra mất mạng lúc đó)
const GATES = ['in', 'out'];
const KINDS = ['scan', 'override', 'emergency', 'open_cmd'];
const STATUSES = ['pending', 'ok', 'denied', 'done'];
const METHODS = ['finger', 'pin', 'auto'];

const intOrNull = (v) => (Number.isInteger(v) ? v : null);
const dateOrNull = (v) => (v ? new Date(v) : null);

export function gateRouter() {
  const router = Router();

  // Mọi thứ cần để quyết định một lượt quẹt thẻ, trong 1 lần gọi (chạy song song với chụp + OCR).
  router.get('/gate/context', async (req, res) => {
    const uid = str(req.query.uid).toUpperCase();
    const [card, open, status, settings, parked] = await Promise.all([
      Card.findOne({ uid }).lean(),
      Session.findOne({ card_uid: uid, parked: true }).lean(),
      parkingStatus(),
      getSettings(),
      Session.find({ parked: true, plate_in: { $type: 'string' } }, { plate_in: 1 }).lean(),
    ]);
    res.json({ card: row(card), open: row(open), status, settings, parked: parked.map((s) => s.plate_in) });
  });

  // Xe vào: mở lượt gửi. Bắt buộc có biển; thẻ / biển đang gửi rồi thì 409 (index unique).
  router.post('/gate/sessions', async (req, res) => {
    const plate = normPlate(req.body?.plate_in);
    const uid = str(req.body?.card_uid).toUpperCase();
    if (!plate) throw new HttpError(400, 'Lượt gửi mới bắt buộc có biển số');
    if (!(await Card.exists({ uid }))) throw new HttpError(400, 'Thẻ chưa đăng ký');
    res.status(201).json(await insert(Session, { card_uid: uid, plate_in: plate, img_in: str(req.body?.img_in) || null }));
  });

  // Xe ra: đóng lượt với phí điện thoại đã tính.
  router.post('/gate/sessions/:id/close', async (req, res) => {
    const b = req.body ?? {};
    const session = await closeSession(Number(req.params.id) || 0, {
      plate_out: normPlate(b.plate_out) || null, img_out: str(b.img_out) || null, fee: intOrNull(b.fee),
      override_by: intOrNull(b.override_by),
    });
    if (!session) throw new HttpError(409, 'Lượt gửi đã kết thúc hoặc không tồn tại');
    res.json(session);
  });

  // Bảo vệ mở tay sau lần bị từ chối: đóng lượt đang gửi của thẻ (nếu có), tính phí tới bây giờ.
  router.post('/gate/release-card', async (req, res) => {
    const s = await Session.findOne({ card_uid: str(req.body?.uid).toUpperCase(), parked: true }).lean();
    if (!s) return res.json({ session: null, fee: null });
    const fee = await feeNow(s);
    const session = await closeSession(s._id, {
      plate_out: normPlate(req.body?.plate) || null, img_out: str(req.body?.img) || null, fee,
      override_by: intOrNull(req.body?.guardId),
    });
    res.json({ session, fee: session ? fee : null });
  });

  router.post('/gate/events', async (req, res) => {
    const b = req.body ?? {};
    if (!GATES.includes(b.gate) || !KINDS.includes(b.kind)) throw new HttpError(400, 'gate / kind không hợp lệ');
    if (b.status !== undefined && !STATUSES.includes(b.status)) throw new HttpError(400, 'status không hợp lệ');
    res.status(201).json(await insert(GateEvent, {
      gate: b.gate, kind: b.kind, uid: str(b.uid).toUpperCase() || null, guard_id: intOrNull(b.guard_id),
      status: b.status ?? 'pending', plate: str(b.plate) || null, img: str(b.img) || null, message: str(b.message) || null,
      open: b.open === true,
    }));
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

  router.put('/gate/images', express.raw({ type: 'image/*', limit: MAX_IMAGE }), async (req, res) => {
    const path = str(req.query.path);
    if (!IMG_PATH_RE.test(path)) throw new HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    if (!Buffer.isBuffer(req.body) || !req.body.length) throw new HttpError(400, 'Gửi ảnh JPEG với Content-Type: image/jpeg');
    await PlateImage.updateOne({ path }, { data: req.body, created_at: new Date() }, { upsert: true });
    res.status(204).end();
  });

  // Bảo vệ theo PIN hoặc ô vân tay (thay cho RPC find_guard).
  router.post('/gate/guards/find', async (req, res) => {
    const g = await findGuard(req.body?.pin, req.body?.finger);
    res.json(g ? { id: g.id, name: g.name } : null);
  });

  // ESP32 vừa lưu vân tay vào ô id (= ID bảo vệ): gán cho bảo vệ đó, gỡ khỏi bảo vệ khác đang giữ số này.
  router.post('/gate/guards/:id/finger', async (req, res) => {
    const id = Number(req.params.id) || 0;
    if (!(await Guard.exists({ _id: id }))) throw new HttpError(404, 'Không có bảo vệ này');
    await Guard.updateMany({ finger_id: id, _id: { $ne: id } }, { finger_id: null });
    res.json(row(await Guard.findByIdAndUpdate(id, { finger_id: id }, { new: true, projection: { pin_hash: 0 } }).lean()));
  });

  // Chấm công: ca đang mở của bảo vệ, mở ca, đóng ca (quyết định vào / ra ca tính trên điện thoại).
  router.get('/gate/attendance/open', async (req, res) => {
    res.json(row(await Attendance.findOne({ guard_id: Number(req.query.guardId) || 0, on_duty: true }).lean()));
  });

  router.post('/gate/attendance', async (req, res) => {
    const b = req.body ?? {};
    if (!(await Guard.exists({ _id: intOrNull(b.guard_id) }))) throw new HttpError(400, 'Không có bảo vệ này');
    if (!METHODS.includes(b.method_in)) throw new HttpError(400, 'method_in là finger hoặc pin');
    res.status(201).json(await insert(Attendance, {
      guard_id: b.guard_id, shift_id: intOrNull(b.shift_id), shift_name: str(b.shift_name) || null,
      shift_start: dateOrNull(b.shift_start), shift_end: dateOrNull(b.shift_end), method_in: b.method_in,
    }));
  });

  router.post('/gate/attendance/:id/close', async (req, res) => {
    const b = req.body ?? {};
    if (!METHODS.includes(b.method_out)) throw new HttpError(400, 'method_out là finger, pin hoặc auto');
    const a = await Attendance.findOneAndUpdate({ _id: Number(req.params.id) || 0, on_duty: true },
      { time_out: dateOrNull(b.time_out) ?? new Date(), method_out: b.method_out, on_duty: false }, { new: true }).lean();
    if (!a) throw new HttpError(409, 'Ca này đã đóng');
    res.json(row(a));
  });
  return router;
}
