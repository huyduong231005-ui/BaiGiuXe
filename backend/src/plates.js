// Nhận diện biển số qua API: token Plate Recognizer nằm trên máy chủ, không còn nằm trong file cài app.
import express, { Router } from 'express';
import jwt from 'jsonwebtoken';
import { HttpError, str } from './auth.js';
import { PlateImage } from './db.js';
import { normPlate } from './rules.js';

const PLATE_URL = 'https://api.platerecognizer.com/v1/plate-reader/';
const MAX_IMAGE = '5mb'; // app gửi ảnh đã thu về cạnh dài 1280px (~150KB)
const UPSTREAM_TIMEOUT_MS = 8000;
// Đường dẫn ảnh do ĐT camera đặt: <cổng>/<ngày>/<mili giây>_<uid>.jpg
export const IMG_PATH_RE = /^(in|out)\/\d{4}-\d{2}-\d{2}\/\d+_[0-9A-F]+\.jpg$/;
const IMG_AUDIENCE = 'bgx-img';
const IMG_TTL = '1h';

/** Link xem ảnh có chữ ký, hết hạn sau 1 giờ (Image.network trong app không gửi kèm token đăng nhập). */
export function imageUrl(req, path, jwtSecret) {
  const t = jwt.sign({ path }, jwtSecret, { audience: IMG_AUDIENCE, expiresIn: IMG_TTL });
  return `${req.protocol}://${req.get('host')}/plates/img?${new URLSearchParams({ path, t })}`;
}

/** GET /plates/img: trả ảnh JPEG nếu chữ ký còn hạn và đúng đường dẫn (không cần đăng nhập). */
export function imageRouter({ jwtSecret }) {
  const router = Router();
  router.get('/plates/img', async (req, res) => {
    const path = str(req.query.path);
    try {
      if (jwt.verify(str(req.query.t), jwtSecret, { audience: IMG_AUDIENCE }).path !== path) throw new Error();
    } catch {
      throw new HttpError(403, 'Link ảnh không hợp lệ hoặc đã hết hạn');
    }
    const img = await PlateImage.findOne({ path }).lean();
    if (!img) throw new HttpError(404, 'Không có ảnh này');
    res.set({ 'content-type': 'image/jpeg', 'cache-control': 'private, max-age=3600' }).send(img.data.buffer ?? img.data);
  });
  return router;
}

/** Kết quả Plate Recognizer -> biển có độ tin cậy cao nhất + các phương án đọc khác + loại phương tiện. */
export function bestPlate(results) {
  if (!results?.length) return { plate: null, score: 0, candidates: [], vehicle: null };
  const best = results.reduce((a, b) => (a.score >= b.score ? a : b));
  const plate = normPlate(best.plate);
  const candidates = (best.candidates ?? []).map((c) => normPlate(c.plate));
  return { plate, score: best.score, candidates: candidates.length ? candidates : [plate], vehicle: best.vehicle?.type ?? null };
}

export function platesRouter({ plateToken, fetchFn = fetch, jwtSecret }) {
  const router = Router();

  router.post('/plates/recognize', express.raw({ type: 'image/*', limit: MAX_IMAGE }), async (req, res) => {
    if (!Buffer.isBuffer(req.body) || !req.body.length) {
      throw new HttpError(400, 'Gửi ảnh JPEG trong body với Content-Type: image/jpeg');
    }
    const form = new FormData();
    form.append('regions', 'vn');
    form.append('config', '{"region":"strict"}'); // chỉ nhận kết quả đúng mẫu biển Việt Nam
    form.append('upload', new Blob([req.body], { type: 'image/jpeg' }), 'shot.jpg');
    let upstream;
    try {
      upstream = await fetchFn(PLATE_URL, {
        method: 'POST', headers: { authorization: `Token ${plateToken}` }, body: form,
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
    } catch (err) {
      throw new HttpError(504, `Không gọi được dịch vụ nhận diện: ${err.message}`);
    }
    if (!upstream.ok) {
      console.error('Plate Recognizer', upstream.status, await upstream.text());
      throw new HttpError(502, `Dịch vụ nhận diện lỗi ${upstream.status}`);
    }
    res.json(bestPlate((await upstream.json()).results));
  });

  // Ảnh biển số lưu trong MongoDB: trả đường dẫn ký có hạn 1 giờ.
  router.get('/plates/url', async (req, res) => {
    const path = str(req.query.path);
    if (!IMG_PATH_RE.test(path)) throw new HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    res.json({ url: imageUrl(req, path, jwtSecret) });
  });
  return router;
}
