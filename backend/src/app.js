import { fileURLToPath } from 'node:url';
import express from 'express';
import rateLimit from 'express-rate-limit';
import { authRouter, HttpError, publicUser, requireAuth, updateProfile } from './auth.js';
import { adminRouter } from './admin.js';
import { guardsRouter, meAttendance } from './guards.js';
import { openapi } from './openapi.js';
import { manageRouter, publicRouter, viewRouter } from './parking.js';
import { platesRouter } from './plates.js';
import { reportsRouter } from './reports.js';

const PUBLIC_DIR = fileURLToPath(new URL('../public', import.meta.url));
const AUTH_WINDOW_MS = 15 * 60 * 1000;
const AUTH_MAX_REQUESTS = 100;

// Mã lỗi Postgres -> HTTP
const PG_STATUS = { 23505: 409, 23503: 409, 23514: 400, '22P02': 400, 22007: 400, 22008: 400, 23502: 400 };
const PG_MESSAGE = {
  23505: 'Dữ liệu bị trùng (đã tồn tại)',
  23503: 'Dữ liệu đang được dùng ở nơi khác (đã có lịch sử), không xoá được',
};

/**
 * @param deps db ({ query(sql, params) -> { rows, rowCount } }: pg.Pool hoặc PGlite), jwtSecret, sendMail,
 *   verifyGoogle, verifySupabase (token -> { email } | null), plateToken, signImage (path -> url), fetchFn
 */
export function createApp(deps) {
  const app = express();
  const auth = (...roles) => requireAuth(deps, ...roles);
  const staff = auth('admin', 'manager');
  app.set('trust proxy', 1); // Render đứng sau proxy, cần để rate limit lấy đúng IP
  app.use(express.json({ limit: '100kb' }));

  app.get('/health', (_req, res) => res.json({ ok: true }));
  app.get('/openapi.json', (_req, res) => res.json(openapi));
  // Trang chủ (danh sách API, số chỗ trống trực tiếp) + /docs (Swagger UI)
  app.use(express.static(PUBLIC_DIR, { extensions: ['html'] }));
  app.use('/auth', rateLimit({ windowMs: AUTH_WINDOW_MS, limit: AUTH_MAX_REQUESTS }), authRouter(deps));
  app.use(publicRouter(deps));

  app.get('/me', auth(), (req, res) => res.json(req.user.device ? { ...publicUser(req.user), device: true }
    : publicUser(req.user)));
  app.patch('/me', auth(), updateProfile(deps.db));
  app.get('/me/attendance', auth(), meAttendance(deps));

  app.use('/admin', auth('admin'), adminRouter(deps));
  app.use(staff, viewRouter(deps), manageRouter(deps), guardsRouter(deps), platesRouter(deps), reportsRouter(deps));

  app.use((_req, _res, next) => next(new HttpError(404, 'Không tìm thấy API')));
  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    const status = err.status ?? PG_STATUS[err.code] ?? (err.type === 'entity.parse.failed' ? 400 : 500);
    if (status >= 500) console.error(err);
    const message =
      err instanceof HttpError ? err.message
      : PG_MESSAGE[err.code] ?? (status === 413 ? 'Dữ liệu gửi lên quá lớn' : status < 500 ? 'Dữ liệu không hợp lệ' : 'Lỗi máy chủ');
    res.status(status).json({ message });
  });
  return app;
}
