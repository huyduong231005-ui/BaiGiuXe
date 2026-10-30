import { fileURLToPath } from 'node:url';
import express from 'express';
import rateLimit from 'express-rate-limit';
import { authRouter, HttpError, publicUser, requireAuth, updateProfile } from './auth.js';
import { adminRouter } from './admin.js';
import { customerRouter, requestsRouter } from './customer.js';
import { gateRouter } from './gate.js';
import { lotMap, lotRouter, routeHandler } from './lot.js';
import { statsRouter } from './stats.js';
import { guardsRouter, meAttendance } from './guards.js';
import { openapi } from './openapi.js';
import { manageRouter, publicRouter, viewRouter } from './parking.js';
import { imageRouter, platesRouter } from './plates.js';
import { reportsRouter } from './reports.js';

const PUBLIC_DIR = fileURLToPath(new URL('../public', import.meta.url));
const AUTH_WINDOW_MS = 15 * 60 * 1000;
const AUTH_MAX_REQUESTS = 100;

const DUPLICATE_KEY = 11000; // MongoDB: trùng index unique

/**
 * @param deps jwtSecret, sendMail, verifyGoogle, plateToken, fetchFn (gọi Plate Recognizer, test thay được).
 *   MongoDB kết nối sẵn qua mongoose trước khi gọi.
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
  app.use(publicRouter(deps), imageRouter(deps));

  app.get('/me', auth(), (req, res) => res.json(publicUser(req.user)));
  app.patch('/me', auth(), updateProfile());
  app.get('/me/attendance', auth(), meAttendance());
  // Sơ đồ bãi không kèm biển số / chủ xe: cư dân xem ô của mình, khách xem chỗ trống.
  app.get('/lot/map/public', auth(), async (_req, res) => res.json(await lotMap({ withPlates: false })));
  app.get('/lot/route', auth(), routeHandler);

  app.use('/admin', auth('admin'), adminRouter(deps));
  app.use('/me', auth('customer')); // các API /me/... còn lại là của khách hàng (chủ vé tháng)
  app.use(customerRouter(deps));
  app.use(staff, viewRouter(deps), manageRouter(deps), guardsRouter(deps), platesRouter(deps), reportsRouter(deps),
    requestsRouter(deps), gateRouter(deps), lotRouter(deps), statsRouter(deps));

  app.use((_req, _res, next) => next(new HttpError(404, 'Không tìm thấy API')));
  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    const invalid = ['CastError', 'ValidationError'].includes(err.name) || err.type === 'entity.parse.failed';
    const status = err.status ?? (err.code === DUPLICATE_KEY ? 409 : invalid ? 400 : 500);
    if (status >= 500) console.error(err);
    const message =
      err instanceof HttpError ? err.message
      : status === 409 ? 'Dữ liệu bị trùng (đã tồn tại)'
      : status === 413 ? 'Dữ liệu gửi lên quá lớn' : status < 500 ? 'Dữ liệu không hợp lệ' : 'Lỗi máy chủ';
    res.status(status).json({ message });
  });
  return app;
}
