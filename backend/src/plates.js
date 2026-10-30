// Nhận diện biển số qua API: token Plate Recognizer nằm trên máy chủ, không còn nằm trong file cài app.
import express, { Router } from 'express';
import { HttpError, str } from './auth.js';
import { normPlate } from './rules.js';

const PLATE_URL = 'https://api.platerecognizer.com/v1/plate-reader/';
const MAX_IMAGE = '5mb'; // app gửi ảnh đã thu về cạnh dài 1280px (~150KB)
const UPSTREAM_TIMEOUT_MS = 8000;
// Đường dẫn ảnh do ĐT camera đặt: <cổng>/<ngày>/<mili giây>_<uid>.jpg
const IMG_PATH_RE = /^(in|out)\/\d{4}-\d{2}-\d{2}\/\d+_[0-9A-F]+\.jpg$/;

/** Kết quả Plate Recognizer -> biển có độ tin cậy cao nhất + các phương án đọc khác (giống recognize() trong app). */
export function bestPlate(results) {
  if (!results?.length) return { plate: null, score: 0, candidates: [] };
  const best = results.reduce((a, b) => (a.score >= b.score ? a : b));
  const plate = normPlate(best.plate);
  const candidates = (best.candidates ?? []).map((c) => normPlate(c.plate));
  return { plate, score: best.score, candidates: candidates.length ? candidates : [plate] };
}

export function platesRouter({ plateToken, fetchFn = fetch, signImage }) {
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

  // Ảnh biển số trong bucket private: trả đường dẫn ký có hạn 1 giờ.
  router.get('/plates/url', async (req, res) => {
    const path = str(req.query.path);
    if (!IMG_PATH_RE.test(path)) throw new HttpError(400, 'Đường dẫn ảnh không hợp lệ');
    res.json({ url: await signImage(path) });
  });
  return router;
}
