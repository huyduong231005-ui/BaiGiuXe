// Khách hàng = chủ vé tháng: thẻ của tôi, báo mất thẻ, mã QR vé, lịch sử ra vào kèm ảnh, đơn đăng ký / gia hạn vé tháng.
// Quản lý: duyệt / từ chối đơn, gán thẻ RFID cho khách.
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { HttpError, str } from './auth.js';
import { Card, insert, row, Session, TicketRequest, User } from './db.js';
import { getSettings, TICKET_AUDIENCE, withJoins } from './parking.js';
import { IMG_PATH_RE, imageUrl } from './plates.js';
import { calcFee, extendUntil, monthlyValid, normPlate } from './rules.js';

const UID_RE = /^[0-9A-F]{8,20}$/;
const PLATE_RE = /^[A-Z0-9]{5,12}$/;
const TICKET_TTL = '10m';
const MAX_PENDING = 3; // chống gửi đơn tràn lan
const MAX_HISTORY = 100;

const myCard = (uid, userId) => Card.findOne({ uid: String(uid).toUpperCase(), user_id: userId }).lean();

function requestInput(body) {
  const plate = normPlate(body?.plate);
  const ownerName = str(body?.ownerName);
  const months = body?.months;
  if (!PLATE_RE.test(plate)) throw new HttpError(400, 'Biển số 5-12 ký tự chữ và số');
  if (!ownerName) throw new HttpError(400, 'Cần nhập tên chủ xe');
  if (!Number.isInteger(months) || months < 1 || months > 12) throw new HttpError(400, 'Số tháng từ 1 đến 12');
  return { plate, owner_name: ownerName, months, note: str(body?.note).slice(0, 300) || null };
}

export function customerRouter({ jwtSecret }) {
  const router = Router();

  // Thẻ của tôi, kèm xe đang gửi (nếu có) và phí nếu ra bây giờ.
  router.get('/me/cards', async (req, res) => {
    const cards = await Card.find({ user_id: req.user.id }).sort({ created_at: 1 }).lean();
    const parked = await Session.find({ card_uid: { $in: cards.map((c) => c.uid) }, parked: true }).lean();
    const byUid = new Map(parked.map((s) => [s.card_uid, s]));
    const settings = await getSettings();
    const now = new Date();
    res.json(cards.map((c) => {
      const s = byUid.get(c.uid);
      return {
        ...row(c),
        session_id: s?._id ?? null, parked_plate: s?.plate_in ?? null, parked_since: s?.time_in ?? null, parked_img: s?.img_in ?? null,
        valid: c.kind !== 'monthly' || monthlyValid(c, now),
        fee_now: s ? calcFee(s.time_in, now, settings, monthlyValid(c, now)) : null,
      };
    }));
  });

  // Báo mất thẻ: khoá ngay, cổng từ chối cả lúc vào lẫn lúc ra (người nhặt được không lấy được xe).
  router.post('/me/cards/:uid/lost', async (req, res) => {
    const filter = { uid: req.params.uid.toUpperCase(), user_id: req.user.id };
    const card = await Card.findOne(filter).lean();
    if (!card) throw new HttpError(404, 'Không có thẻ này trong tài khoản của bạn');
    res.json(row(await Card.findOneAndUpdate(filter, { lost_at: card.lost_at ?? new Date(), active: false }, { new: true }).lean()));
  });

  // Mã QR vé xe: ký bằng JWT, hết hạn sau 10 phút, không lộ UID thẻ (UID lộ ra thì sao chép được thẻ RFID).
  router.get('/me/cards/:uid/qr', async (req, res) => {
    const card = await myCard(req.params.uid, req.user.id);
    if (!card) throw new HttpError(404, 'Không có thẻ này trong tài khoản của bạn');
    res.json({ qr: jwt.sign({ uid: card.uid }, jwtSecret, { audience: TICKET_AUDIENCE, expiresIn: TICKET_TTL }), expiresInSec: 600 });
  });

  router.get('/me/sessions', async (req, res) => {
    const uids = (await Card.find({ user_id: req.user.id }, { uid: 1 }).lean()).map((c) => c.uid);
    const sessions = await Session.find({ card_uid: { $in: uids } }).sort({ time_in: -1 }).limit(MAX_HISTORY).lean();
    res.json(await withJoins(sessions, []));
  });

  // Ảnh xe của chính mình (lúc vào / ra) để đối chiếu khi nghi bị lấy xe.
  router.get('/me/plates/url', async (req, res) => {
    const path = str(req.query.path);
    if (!IMG_PATH_RE.test(path)) throw new HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    const uids = (await Card.find({ user_id: req.user.id }, { uid: 1 }).lean()).map((c) => c.uid);
    if (!(await Session.exists({ card_uid: { $in: uids }, $or: [{ img_in: path }, { img_out: path }] }))) {
      throw new HttpError(403, 'Ảnh này không thuộc xe của bạn');
    }
    res.json({ url: imageUrl(req, path, jwtSecret) });
  });

  router.get('/me/requests', async (req, res) => {
    res.json((await TicketRequest.find({ user_id: req.user.id }).sort({ created_at: -1 }).lean()).map(row));
  });

  router.post('/me/requests', async (req, res) => {
    const r = requestInput(req.body);
    const cardUid = req.body?.cardUid ? String(req.body.cardUid).toUpperCase() : null;
    if (cardUid && !(await myCard(cardUid, req.user.id))) throw new HttpError(400, 'Chỉ gia hạn được thẻ của chính bạn');
    const n = await TicketRequest.countDocuments({ user_id: req.user.id, status: 'pending' });
    if (n >= MAX_PENDING) throw new HttpError(429, `Đã có ${n} đơn đang chờ duyệt, hãy đợi quản lý xử lý`);
    res.status(201).json(await insert(TicketRequest, { user_id: req.user.id, card_uid: cardUid, ...r }));
  });

  router.patch('/me/requests/:id', async (req, res) => {
    const r = requestInput(req.body);
    const saved = await TicketRequest.findOneAndUpdate(
      { _id: Number(req.params.id) || 0, user_id: req.user.id, status: 'pending' }, r, { new: true }).lean();
    if (!saved) throw new HttpError(409, 'Chỉ sửa được đơn đang chờ duyệt của bạn');
    res.json(row(saved));
  });

  router.delete('/me/requests/:id', async (req, res) => {
    const { deletedCount } = await TicketRequest.deleteOne(
      { _id: Number(req.params.id) || 0, user_id: req.user.id, status: 'pending' });
    if (!deletedCount) throw new HttpError(409, 'Chỉ huỷ được đơn đang chờ duyệt của bạn');
    res.status(204).end();
  });
  return router;
}

export function requestsRouter() {
  const router = Router();

  // Đơn đang chờ lên đầu, rồi mới nhất trước.
  router.get('/requests', async (req, res) => {
    const status = str(req.query.status);
    const list = await TicketRequest.find(status ? { status } : {}).sort({ created_at: -1 }).lean();
    list.sort((a, b) => (b.status === 'pending') - (a.status === 'pending'));
    const [users, cards] = await Promise.all([
      User.find({ _id: { $in: list.map((r) => r.user_id) } }, { username: 1, email: 1 }).lean(),
      Card.find({ uid: { $in: list.map((r) => r.card_uid).filter(Boolean) } }, { uid: 1, valid_until: 1 }).lean(),
    ]);
    const byUser = new Map(users.map((u) => [u._id, u]));
    const until = new Map(cards.map((c) => [c.uid, c.valid_until]));
    res.json(list.filter((r) => byUser.has(r.user_id)).slice(0, 200).map((r) => ({
      ...row(r), username: byUser.get(r.user_id).username, email: byUser.get(r.user_id).email,
      card_valid_until: until.get(r.card_uid) ?? null,
    })));
  });

  const pending = async (id) => {
    const r = await TicketRequest.findById(Number(id) || 0).lean();
    if (!r) throw new HttpError(404, 'Không có đơn này');
    if (r.status !== 'pending') throw new HttpError(409, 'Đơn đã được xử lý');
    return row(r);
  };

  // Duyệt: gia hạn thẻ cũ, hoặc gán thẻ RFID mới (cardUid quẹt / NFC / gõ) thành vé tháng của khách.
  router.post('/requests/:id/approve', async (req, res) => {
    const r = await pending(req.params.id);
    const uid = r.card_uid ?? String(req.body?.cardUid ?? '').toUpperCase();
    if (!UID_RE.test(uid)) throw new HttpError(400, 'Cần UID thẻ RFID để cấp vé tháng mới');
    const card = await Card.findOne({ uid }).lean();
    if (card?.user_id && card.user_id !== r.user_id) throw new HttpError(409, 'Thẻ này đang thuộc khách khác');
    const until = extendUntil(card?.kind === 'monthly' ? card.valid_until : null, r.months);
    const saved = await Card.findOneAndUpdate({ uid }, {
      kind: 'monthly', plate: r.plate, owner: r.owner_name, active: true, user_id: r.user_id, valid_until: until, lost_at: null,
    }, { new: true, upsert: true, setDefaultsOnInsert: true }).lean();
    const done = await TicketRequest.findByIdAndUpdate(r.id, {
      status: 'approved', card_uid: uid, reply: str(req.body?.reply) || null, handled_by: req.user.id, handled_at: new Date(),
    }, { new: true }).lean();
    res.json({ request: row(done), card: row(saved) });
  });

  router.post('/requests/:id/reject', async (req, res) => {
    const r = await pending(req.params.id);
    const reply = str(req.body?.reply);
    if (!reply) throw new HttpError(400, 'Cần ghi lý do từ chối để khách biết');
    res.json(row(await TicketRequest.findByIdAndUpdate(r.id,
      { status: 'rejected', reply, handled_by: req.user.id, handled_at: new Date() }, { new: true }).lean()));
  });
  return router;
}
