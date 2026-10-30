// Khách hàng = chủ vé tháng: thẻ của tôi, báo mất thẻ, mã QR vé, lịch sử ra vào kèm ảnh, đơn đăng ký / gia hạn vé tháng.
// Quản lý: duyệt / từ chối đơn, gán thẻ RFID cho khách.
import { Router } from 'express';
import jwt from 'jsonwebtoken';
import { HttpError, str } from './auth.js';
import { TICKET_AUDIENCE } from './parking.js';
import { calcFee, extendUntil, monthlyValid, normPlate } from './rules.js';

const UID_RE = /^[0-9A-F]{8,20}$/;
const PLATE_RE = /^[A-Z0-9]{5,12}$/;
const IMG_PATH_RE = /^(in|out)\/\d{4}-\d{2}-\d{2}\/\d+_[0-9A-F]+\.jpg$/;
const TICKET_TTL = '10m';
const MAX_PENDING = 3; // chống gửi đơn tràn lan
const MAX_HISTORY = 100;

const myCard = async (db, uid, userId) =>
  (await db.query('select * from cards where uid = $1 and user_id = $2', [String(uid).toUpperCase(), userId])).rows[0];

function requestInput(body) {
  const plate = normPlate(body?.plate);
  const ownerName = str(body?.ownerName);
  const months = body?.months;
  if (!PLATE_RE.test(plate)) throw new HttpError(400, 'Biển số 5-12 ký tự chữ và số');
  if (!ownerName) throw new HttpError(400, 'Cần nhập tên chủ xe');
  if (!Number.isInteger(months) || months < 1 || months > 12) throw new HttpError(400, 'Số tháng từ 1 đến 12');
  return { plate, ownerName, months, note: str(body?.note).slice(0, 300) || null };
}

export function customerRouter({ db, jwtSecret, signImage }) {
  const router = Router();

  // Thẻ của tôi, kèm xe đang gửi (nếu có) và phí nếu ra bây giờ.
  router.get('/me/cards', async (req, res) => {
    const { rows } = await db.query(
      `select c.*, s.id as session_id, s.plate_in as parked_plate, s.time_in as parked_since, s.img_in as parked_img
       from cards c left join sessions s on s.card_uid = c.uid and s.time_out is null
       where c.user_id = $1 order by c.created_at`, [req.user.id]);
    const settings = (await db.query('select * from settings where id = 1')).rows[0];
    const now = new Date();
    res.json(rows.map((c) => ({
      ...c,
      valid: c.kind !== 'monthly' || monthlyValid(c, now),
      fee_now: c.session_id ? calcFee(c.parked_since, now, settings, monthlyValid(c, now)) : null,
    })));
  });

  // Báo mất thẻ: khoá ngay, cổng từ chối cả lúc vào lẫn lúc ra (người nhặt được không lấy được xe).
  router.post('/me/cards/:uid/lost', async (req, res) => {
    const { rows } = await db.query(
      `update cards set lost_at = coalesce(lost_at, now()), active = false
       where uid = $1 and user_id = $2 returning *`, [req.params.uid.toUpperCase(), req.user.id]);
    if (!rows.length) throw new HttpError(404, 'Không có thẻ này trong tài khoản của bạn');
    res.json(rows[0]);
  });

  // Mã QR vé xe: ký bằng JWT, hết hạn sau 10 phút, không lộ UID thẻ (UID lộ ra thì sao chép được thẻ RFID).
  router.get('/me/cards/:uid/qr', async (req, res) => {
    const card = await myCard(db, req.params.uid, req.user.id);
    if (!card) throw new HttpError(404, 'Không có thẻ này trong tài khoản của bạn');
    res.json({ qr: jwt.sign({ uid: card.uid }, jwtSecret, { audience: TICKET_AUDIENCE, expiresIn: TICKET_TTL }), expiresInSec: 600 });
  });

  router.get('/me/sessions', async (req, res) => {
    const { rows } = await db.query(
      `select s.*, g.name as override_name from sessions s join cards c on c.uid = s.card_uid
       left join guards g on g.id = s.override_by
       where c.user_id = $1 order by s.time_in desc limit ${MAX_HISTORY}`, [req.user.id]);
    res.json(rows);
  });

  // Ảnh xe của chính mình (lúc vào / ra) để đối chiếu khi nghi bị lấy xe.
  router.get('/me/plates/url', async (req, res) => {
    const path = str(req.query.path);
    if (!IMG_PATH_RE.test(path)) throw new HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    const { rows } = await db.query(
      `select 1 from sessions s join cards c on c.uid = s.card_uid
       where c.user_id = $1 and (s.img_in = $2 or s.img_out = $2) limit 1`, [req.user.id, path]);
    if (!rows.length) throw new HttpError(403, 'Ảnh này không thuộc xe của bạn');
    res.json({ url: await signImage(path) });
  });

  router.get('/me/requests', async (req, res) => {
    const { rows } = await db.query('select * from ticket_requests where user_id = $1 order by created_at desc', [req.user.id]);
    res.json(rows);
  });

  router.post('/me/requests', async (req, res) => {
    const r = requestInput(req.body);
    const cardUid = req.body?.cardUid ? String(req.body.cardUid).toUpperCase() : null;
    if (cardUid && !(await myCard(db, cardUid, req.user.id))) throw new HttpError(400, 'Chỉ gia hạn được thẻ của chính bạn');
    const { rows: [{ n }] } = await db.query(
      "select count(*)::int as n from ticket_requests where user_id = $1 and status = 'pending'", [req.user.id]);
    if (n >= MAX_PENDING) throw new HttpError(429, `Đã có ${n} đơn đang chờ duyệt, hãy đợi quản lý xử lý`);
    const { rows } = await db.query(
      `insert into ticket_requests (user_id, card_uid, plate, owner_name, months, note) values ($1, $2, $3, $4, $5, $6)
       returning *`, [req.user.id, cardUid, r.plate, r.ownerName, r.months, r.note]);
    res.status(201).json(rows[0]);
  });

  router.patch('/me/requests/:id', async (req, res) => {
    const r = requestInput(req.body);
    const { rows } = await db.query(
      `update ticket_requests set plate = $3, owner_name = $4, months = $5, note = $6
       where id = $1 and user_id = $2 and status = 'pending' returning *`,
      [Number(req.params.id) || 0, req.user.id, r.plate, r.ownerName, r.months, r.note]);
    if (!rows.length) throw new HttpError(409, 'Chỉ sửa được đơn đang chờ duyệt của bạn');
    res.json(rows[0]);
  });

  router.delete('/me/requests/:id', async (req, res) => {
    const { rowCount } = await db.query(
      "delete from ticket_requests where id = $1 and user_id = $2 and status = 'pending'", [Number(req.params.id) || 0, req.user.id]);
    if (!rowCount) throw new HttpError(409, 'Chỉ huỷ được đơn đang chờ duyệt của bạn');
    res.status(204).end();
  });
  return router;
}

export function requestsRouter({ db }) {
  const router = Router();

  router.get('/requests', async (req, res) => {
    const status = str(req.query.status);
    const { rows } = await db.query(
      `select r.*, u.username, u.email, c.valid_until as card_valid_until from ticket_requests r
       join app_users u on u.id = r.user_id left join cards c on c.uid = r.card_uid
       where ($1 = '' or r.status = $1) order by r.status = 'pending' desc, r.created_at desc limit 200`, [status]);
    res.json(rows);
  });

  const pending = async (id) => {
    const [r] = (await db.query('select * from ticket_requests where id = $1', [Number(id) || 0])).rows;
    if (!r) throw new HttpError(404, 'Không có đơn này');
    if (r.status !== 'pending') throw new HttpError(409, 'Đơn đã được xử lý');
    return r;
  };

  // Duyệt: gia hạn thẻ cũ, hoặc gán thẻ RFID mới (cardUid quẹt / NFC / gõ) thành vé tháng của khách.
  router.post('/requests/:id/approve', async (req, res) => {
    const r = await pending(req.params.id);
    const uid = r.card_uid ?? String(req.body?.cardUid ?? '').toUpperCase();
    if (!UID_RE.test(uid)) throw new HttpError(400, 'Cần UID thẻ RFID để cấp vé tháng mới');
    const [card] = (await db.query('select * from cards where uid = $1', [uid])).rows;
    if (card?.user_id && card.user_id !== r.user_id) throw new HttpError(409, 'Thẻ này đang thuộc khách khác');
    const until = extendUntil(card?.kind === 'monthly' ? card.valid_until : null, r.months);
    const { rows: [saved] } = await db.query(
      `insert into cards (uid, kind, plate, owner, active, user_id, valid_until) values ($1, 'monthly', $2, $3, true, $4, $5)
       on conflict (uid) do update set kind = 'monthly', plate = $2, owner = $3, active = true, user_id = $4,
         valid_until = $5, lost_at = null
       returning *`, [uid, r.plate, r.owner_name, r.user_id, until]);
    const { rows: [done] } = await db.query(
      `update ticket_requests set status = 'approved', card_uid = $2, reply = $3, handled_by = $4, handled_at = now()
       where id = $1 returning *`, [r.id, uid, str(req.body?.reply) || null, req.user.id]);
    res.json({ request: done, card: saved });
  });

  router.post('/requests/:id/reject', async (req, res) => {
    const r = await pending(req.params.id);
    const reply = str(req.body?.reply);
    if (!reply) throw new HttpError(400, 'Cần ghi lý do từ chối để khách biết');
    const { rows } = await db.query(
      `update ticket_requests set status = 'rejected', reply = $2, handled_by = $3, handled_at = now()
       where id = $1 returning *`, [r.id, reply, req.user.id]);
    res.json(rows[0]);
  });
  return router;
}
