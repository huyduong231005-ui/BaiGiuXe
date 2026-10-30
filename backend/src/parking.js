// Bãi xe: số chỗ trống, lượt gửi, lịch sử + doanh thu, mở cổng, cho xe ra khi mất thẻ, thẻ, cài đặt.
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { HttpError, str } from './auth.js';
import { Card, contains, GateEvent, insert, row, Session, Settings, Slot, TicketRequest, User } from './db.js';
import { guardNames, IN_USE } from './guards.js';
import { freeByType, priceOf, vehicleTypes } from './lot.js';
import { calcFee, minutesOf, monthlyValid, nightsCrossed, normPlate, samePlate } from './rules.js';

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const UID_RE = /^[0-9A-F]{8,20}$/;
const MAX_ROWS = 1000;

/** "2026-10-30" -> [00:00, 24:00) giờ địa phương. */
export function dayRange(date) {
  if (!DATE_RE.test(date)) throw new HttpError(400, 'Ngày dạng YYYY-MM-DD');
  const [y, m, d] = date.split('-').map(Number);
  return [new Date(y, m - 1, d), new Date(y, m - 1, d + 1)];
}

/** Ngày YYYY-MM-DD theo giờ địa phương (TZ của tiến trình). */
export const ymd = (t) => `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
export const today = () => ymd(new Date());

export const getSettings = async () => row(await Settings.findById(1).lean());

/** Sức chứa / đang gửi / còn trống. Đã vẽ sơ đồ thì sức chứa = số ô đang dùng, kèm chỗ trống theo loại xe. */
export async function parkingStatus() {
  const [s, occupied, slots] = await Promise.all([
    getSettings(), Session.countDocuments({ parked: true }), Slot.countDocuments({ active: true }),
  ]);
  const capacity = slots || s.capacity;
  return { capacity, occupied, free: Math.max(0, capacity - occupied), ...(slots ? { byType: await freeByType() } : {}) };
}

/** Giá áp cho lượt gửi (theo loại xe của lượt). */
export const sessionPrice = async (session) => priceOf(await getSettings(), await vehicleTypes(), session.vehicle_type);

/** Doanh thu theo ngày ra (giờ địa phương) của các lượt ra trong [from, to). */
export async function revenueByDay(from, to) {
  const by = new Map();
  for (const s of await Session.find({ time_out: { $gte: from, $lt: to } }, { time_out: 1, fee: 1 }).lean()) {
    const day = ymd(s.time_out);
    const r = by.get(day) ?? { day, sessions: 0, revenue: 0 };
    r.sessions++;
    r.revenue += s.fee ?? 0;
    by.set(day, r);
  }
  return [...by.values()].sort((a, b) => a.day.localeCompare(b.day));
}

const CARD_COLS = { kind: 'card_kind', owner: 'card_owner', valid_until: 'card_valid_until', lost_at: 'card_lost_at' };

/** Gắn thông tin thẻ (card_kind, card_owner...) và tên bảo vệ mở tay (override_name) vào từng lượt gửi. */
export async function withJoins(sessions, cardCols = ['kind', 'owner'], overrideName = true) {
  const uids = [...new Set(sessions.map((s) => s.card_uid))];
  const [cards, names] = await Promise.all([
    Card.find({ uid: { $in: uids } }).lean(),
    overrideName ? guardNames(sessions.map((s) => s.override_by)) : new Map(),
  ]);
  const byUid = new Map(cards.map((c) => [c.uid, c]));
  return sessions.map((s) => ({
    ...row(s),
    ...Object.fromEntries(cardCols.map((k) => [CARD_COLS[k], byUid.get(s.card_uid)?.[k] ?? null])),
    ...(overrideName ? { override_name: names.get(s.override_by) ?? null } : {}),
  }));
}

/** Phí nếu cho lượt gửi này ra vào thời điểm now. */
export async function feeNow(session, now = new Date()) {
  const card = await Card.findOne({ uid: session.card_uid }).lean();
  return calcFee(session.time_in, now, await sessionPrice(session), monthlyValid(card, now));
}

/** Thêm phí nếu cho ra bây giờ vào mỗi lượt đang gửi (rows có card_kind, card_valid_until). */
async function withFee(rows, plate) {
  const [settings, types] = await Promise.all([getSettings(), vehicleTypes()]);
  const now = new Date();
  return rows.map((s) => ({
    ...s,
    exact: plate == null || normPlate(s.plate_in) === plate,
    feeNow: calcFee(s.time_in, now, priceOf(settings, types, s.vehicle_type),
      monthlyValid({ kind: s.card_kind, valid_until: s.card_valid_until }, now)),
  }));
}

/** Đóng lượt đang gửi (chỉ khi chưa ai đóng), trả về dòng mới hoặc null. */
export const closeSession = async (id, changes) => row(await Session.findOneAndUpdate(
  { _id: id, parked: true }, { ...changes, time_out: new Date(), parked: false }, { returnDocument: 'after' }).lean());

export const TICKET_AUDIENCE = 'bgx-ticket';

const openGate = (message) => insert(GateEvent, { gate: 'out', kind: 'open_cmd', message });

/** Các API công khai: trang chủ hiển thị số chỗ trống, máy tính phí. */
export function publicRouter() {
  const router = Router();
  router.get('/status', async (_req, res) => res.json(await parkingStatus()));

  // Thông tin bãi cho khách: tên, địa chỉ, toạ độ (bản đồ, chỉ đường), bảng giá, chỗ trống.
  router.get('/lot', async (_req, res) => {
    const s = await getSettings();
    const prices = Object.values(await vehicleTypes()).map((t) => ({ code: t.code, name: t.name, priceDay: t.price_day,
      priceNight: t.price_night, priceMonth: t.price_month }));
    res.json({ name: s.lot_name, address: s.address, lat: s.lat, lng: s.lng, prices, nightMark: s.night_mark.slice(0, 5),
      ...(await parkingStatus()) });
  });

  router.post('/fees/quote', async (req, res) => {
    const timeIn = new Date(req.body?.timeIn);
    const timeOut = req.body?.timeOut ? new Date(req.body.timeOut) : new Date();
    if (Number.isNaN(+timeIn) || Number.isNaN(+timeOut) || timeOut < timeIn) {
      throw new HttpError(400, 'timeIn / timeOut phải là thời điểm ISO 8601, giờ ra sau giờ vào');
    }
    const settings = priceOf(await getSettings(), await vehicleTypes(), str(req.body?.vehicleType) || 'motorbike');
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
export function viewRouter({ jwtSecret }) {
  const router = Router();

  router.get('/sessions', async (req, res) => {
    const filter = {};
    if (req.query.open === 'true') {
      filter.parked = true;
    } else {
      const [from, to] = dayRange(str(req.query.date) || today());
      filter.time_in = { $gte: from, $lt: to };
    }
    const plate = normPlate(req.query.plate);
    if (plate) filter.$or = [{ plate_in: contains(plate) }, { plate_out: contains(plate) }];
    const rows = await withJoins(await Session.find(filter).sort({ time_in: -1 }).limit(MAX_ROWS).lean());
    res.json({ count: rows.length, revenue: rows.reduce((a, s) => a + (s.fee ?? 0), 0), sessions: rows });
  });

  // Tra cứu xe đang trong bãi theo biển (quản lý chụp biển bằng điện thoại hoặc gõ tay).
  // So khớp như ở cổng: lệch tối đa 1 ký tự, xét cả các phương án đọc khác (candidates=a,b,c) của OCR.
  router.get('/sessions/lookup', async (req, res) => {
    const reads = [req.query.plate, ...str(req.query.candidates).split(',')].map(normPlate).filter(Boolean);
    if (!reads.length) throw new HttpError(400, 'Cần biển số cần tra');
    const parked = await Session.find({ parked: true }).sort({ time_in: -1 }).lean();
    const hits = parked.filter((s) => reads.some((p) => samePlate(s.plate_in, p)));
    const rows = await withJoins(hits, ['kind', 'owner', 'valid_until', 'lost_at'], false);
    res.json({ plate: reads[0], matches: await withFee(rows, reads[0]) });
  });

  // Quét mã QR vé xe trên app của khách (mã ký, hết hạn sau 10 phút): ra lượt đang gửi của thẻ đó.
  router.get('/sessions/by-ticket', async (req, res) => {
    let uid;
    try {
      ({ uid } = jwt.verify(str(req.query.qr), jwtSecret, { audience: TICKET_AUDIENCE }));
    } catch {
      throw new HttpError(400, 'Mã QR vé không hợp lệ hoặc đã hết hạn, nhờ khách mở lại mã');
    }
    const card = await Card.findOne({ uid }).lean();
    if (!card) throw new HttpError(404, 'Thẻ của mã QR không còn trong hệ thống');
    const parked = await withJoins(await Session.find({ card_uid: uid, parked: true }).lean(),
      ['kind', 'owner', 'valid_until', 'lost_at'], false);
    res.json({ cardUid: uid, owner: card.owner, validUntil: card.valid_until, lost: Boolean(card.lost_at),
      matches: await withFee(parked, null) });
  });

  router.get('/sessions/:id/fee', async (req, res) => {
    const s = await Session.findById(Number(req.params.id) || 0).lean();
    if (!s) throw new HttpError(404, 'Không có lượt gửi này');
    if (s.time_out) return res.json({ fee: s.fee, closed: true });
    res.json({ fee: await feeNow(s), closed: false });
  });

  router.get('/events', async (req, res) => {
    const limit = Math.min(Math.max(Number(req.query.limit) || 20, 1), 200);
    const events = await GateEvent.find().sort({ _id: -1 }).limit(limit).lean();
    const names = await guardNames(events.map((e) => e.guard_id));
    res.json(events.map((e) => ({ ...row(e), guard_name: names.get(e.guard_id) ?? null })));
  });

  // Màn thêm thẻ hỏi định kỳ: thẻ vừa quẹt ở cổng bất kỳ sau mốc since (thay cho Realtime).
  router.get('/scans/latest', async (req, res) => {
    const since = new Date(str(req.query.since) || 0);
    if (Number.isNaN(+since)) throw new HttpError(400, 'since phải là thời điểm ISO 8601');
    const e = await GateEvent.findOne({ kind: 'scan', uid: { $type: 'string' }, created_at: { $gt: since } })
      .sort({ _id: -1 }).lean();
    res.json(e ? { uid: e.uid, gate: e.gate, created_at: e.created_at, registered: Boolean(await Card.exists({ uid: e.uid })) }
      : null);
  });

  router.get('/cards', async (req, res) => {
    const q = contains(str(req.query.q));
    const cards = await Card.find({ $or: [{ uid: q }, { plate: q }, { owner: q }] }).sort({ created_at: -1 }).lean();
    const users = await User.find({ _id: { $in: cards.map((c) => c.user_id).filter(Boolean) } }, { username: 1 }).lean();
    const names = new Map(users.map((u) => [u._id, u.username]));
    const slots = new Map((await Slot.find({ card_uid: { $in: cards.map((c) => c.uid) } }).lean()).map((sl) => [sl.card_uid, sl.code]));
    res.json(cards.map((c) => ({ ...row(c), user_name: names.get(c.user_id) ?? null, slot_code: slots.get(c.uid) ?? null })));
  });

  router.get('/settings', async (_req, res) => res.json(await getSettings()));
  return router;
}

/** Dữ liệu thẻ từ body. Nhận cả tên cột (valid_until) lẫn tên API (validUntil). */
function cardInput(body, uid, types) {
  const kind = body?.kind ?? 'guest';
  const vehicleType = (body?.vehicleType !== undefined ? body.vehicleType : body?.vehicle_type) || (kind === 'monthly' ? 'motorbike' : null);
  if (vehicleType && !types[vehicleType]) throw new HttpError(400, 'Loại xe không hợp lệ');
  if (!['guest', 'monthly'].includes(kind)) throw new HttpError(400, 'Loại vé là guest hoặc monthly');
  const plate = normPlate(body?.plate) || null;
  if (kind === 'monthly' && !plate) throw new HttpError(400, 'Vé tháng cần biển số');
  if (!UID_RE.test(uid)) throw new HttpError(400, 'UID phải là 8-20 ký tự hex (0-9, A-F)');
  const until = body?.validUntil !== undefined ? body.validUntil : body?.valid_until;
  if (until != null && !DATE_RE.test(String(until).slice(0, 10))) throw new HttpError(400, 'Hạn vé dạng YYYY-MM-DD');
  return { uid, kind, plate, owner: str(body?.owner) || null, active: body?.active !== false,
    valid_until: kind === 'monthly' && until ? String(until).slice(0, 10) : null,
    vehicle_type: kind === 'monthly' ? vehicleType : null, apartment: str(body?.apartment).toUpperCase() || null };
}

export function manageRouter() {
  const router = Router();

  // Mất thẻ / xử lý tay: tính phí tới bây giờ, đóng lượt gửi, ra lệnh mở barrier cổng ra.
  router.post('/sessions/:id/release', async (req, res) => {
    const s = await Session.findById(Number(req.params.id) || 0).lean();
    if (!s) throw new HttpError(404, 'Không có lượt gửi này');
    if (s.time_out) throw new HttpError(409, 'Lượt gửi đã kết thúc');
    const fee = await feeNow(s);
    const session = await closeSession(s._id, { fee });
    if (!session) throw new HttpError(409, 'Lượt gửi vừa được đóng ở nơi khác');
    await openGate(`Cho ra thu cong boi ${req.user.username}`);
    res.json({ session, fee });
  });

  // ĐT camera cổng ra hỏi định kỳ GET /gate/commands rồi gửi lệnh mở barrier cho ESP32.
  router.post('/gate/open', async (req, res) => {
    res.status(201).json(await openGate(`Lenh tu API boi ${req.user.username}`));
  });

  router.post('/cards', async (req, res) => {
    const card = await Card.create(cardInput(req.body, str(req.body?.uid).toUpperCase(), await vehicleTypes()));
    res.status(201).json(row(card.toObject()));
  });

  // Mở lại thẻ đã báo mất (khách tìm lại được thẻ): gửi { lost: false }.
  router.patch('/cards/:uid', async (req, res) => {
    const uid = req.params.uid.toUpperCase();
    const old = await Card.findOne({ uid }).lean();
    if (!old) throw new HttpError(404, 'Không có thẻ này');
    const changes = { ...cardInput({ ...old, ...req.body }, uid, await vehicleTypes()), ...(req.body?.lost === false ? { lost_at: null } : {}) };
    // Thẻ thôi là vé tháng hoặc đổi loại xe thì trả ô riêng về cho khách vãng lai.
    if (changes.kind !== 'monthly' || changes.vehicle_type !== old.vehicle_type) await Slot.updateMany({ card_uid: uid }, { card_uid: null });
    res.json(row(await Card.findOneAndUpdate({ uid }, changes, { returnDocument: 'after' }).lean()));
  });

  // Xoá thẻ bất cứ lúc nào, trừ khi xe của thẻ đang trong bãi. Lịch sử ra vào cũ vẫn giữ (lượt gửi lưu UID thẻ).
  router.delete('/cards/:uid', async (req, res) => {
    const uid = req.params.uid.toUpperCase();
    if (!(await Card.exists({ uid }))) throw new HttpError(404, 'Không có thẻ này');
    if (await Session.exists({ card_uid: uid, parked: true })) {
      throw new HttpError(409, 'Xe của thẻ này đang trong bãi: cho xe ra (Tổng quan → chạm vào xe) rồi mới xoá thẻ');
    }
    await Card.deleteOne({ uid });
    await TicketRequest.updateMany({ card_uid: uid }, { card_uid: null });
    await Slot.updateMany({ card_uid: uid }, { card_uid: null });
    res.status(204).end();
  });

  router.put('/settings', async (req, res) => {
    // Giá theo loại xe sửa ở /vehicle-types; ở đây là sức chứa (khi chưa vẽ sơ đồ), mốc đêm, thông tin bãi.
    const capacity = req.body?.capacity;
    const nightMark = str(req.body?.nightMark);
    if (!Number.isInteger(capacity) || capacity <= 0) throw new HttpError(400, 'Sức chứa là số nguyên > 0');
    if (!TIME_RE.test(nightMark)) throw new HttpError(400, 'Mốc đêm dạng HH:MM');
    // Vị trí bãi (không bắt buộc): gửi kèm thì phải đủ cặp toạ độ hợp lệ.
    const b = req.body;
    const old = await getSettings();
    const lat = b.lat !== undefined ? b.lat : old.lat, lng = b.lng !== undefined ? b.lng : old.lng;
    if ((lat == null) !== (lng == null) || (lat != null && (Math.abs(lat) > 90 || Math.abs(lng) > 180))) {
      throw new HttpError(400, 'Toạ độ bãi không hợp lệ');
    }
    res.json(row(await Settings.findByIdAndUpdate(1, {
      capacity, night_mark: `${nightMark}:00`,
      lot_name: str(b.lotName) || old.lot_name, address: b.address !== undefined ? str(b.address) || null : old.address, lat, lng,
    }, { returnDocument: 'after' }).lean()));
  });
  return router;
}
