import crypto from 'node:crypto';
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';

const OTP_TTL_MS = 5 * 60 * 1000;
const OTP_RESEND_MS = 30 * 1000; // chống spam email / đốt hạn mức 300 mail/ngày của Brevo
const OTP_MAX_ATTEMPTS = 5;
const TOKEN_TTL = '7d';
export const ROLES = ['admin', 'manager', 'guard', 'customer'];
export const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
export const USERNAME_RE = /^[a-z0-9_.]{3,30}$/;
export const MIN_PASSWORD = 6;
const MAX_FULLNAME = 100;

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');
const maskEmail = (email) => email.replace(/^(.).*(@.*)$/, '$1***$2');
export const str = (v) => (typeof v === 'string' ? v.trim() : '');
const pass = (v) => (typeof v === 'string' ? v : '');

/** Dữ liệu tài khoản trả cho client (không bao giờ kèm hash mật khẩu). */
export const publicUser = (u) => ({
  id: u.id, username: u.username, email: u.email, fullName: u.full_name, role: u.role,
  guardId: u.guard_id, active: u.active,
});

export const signToken = (user, jwtSecret) =>
  jwt.sign({ sub: user.id, role: user.role }, jwtSecret, { expiresIn: TOKEN_TTL });

/**
 * Kiểm token và nạp người dùng từ DB (đổi vai trò / khoá có hiệu lực ngay), kiểm vai trò nếu có truyền.
 * Ngoài JWT của API còn nhận token Supabase của điện thoại camera (vai trò staff) và coi là quản lý,
 * để ĐT camera đang đăng nhập Supabase gọi được API mà không phải đăng nhập lần nữa.
 */
export function requireAuth({ db, jwtSecret, verifySupabase }, ...roles) {
  return async (req, _res, next) => {
    const token = req.get('authorization')?.replace(/^Bearer /, '') ?? '';
    let user;
    try {
      const { sub } = jwt.verify(token, jwtSecret);
      [user] = (await db.query('select * from app_users where id = $1', [sub])).rows;
      if (!user?.active) throw new HttpError(401, 'Tài khoản không còn hoạt động');
    } catch (err) {
      if (err instanceof HttpError) throw err;
      const staff = token && (await verifySupabase(token));
      if (!staff) throw new HttpError(401, 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn');
      user = { id: null, username: staff.email, email: staff.email, full_name: 'Thiết bị camera', role: 'manager',
        guard_id: null, active: true, device: true };
    }
    if (roles.length && !roles.includes(user.role)) throw new HttpError(403, 'Bạn không có quyền làm việc này');
    req.user = user;
    next();
  };
}

/** PATCH /me: tự đổi họ tên và mật khẩu (phải nhập đúng mật khẩu hiện tại). */
export function updateProfile(db) {
  return async (req, res) => {
    const { user } = req;
    if (!user.id) throw new HttpError(400, 'Thiết bị camera không có hồ sơ để sửa');
    let { full_name: fullName, password_hash: hash } = user;
    if (req.body?.fullName !== undefined) {
      fullName = str(req.body.fullName);
      if (!fullName || fullName.length > MAX_FULLNAME) throw new HttpError(400, `Họ tên 1–${MAX_FULLNAME} ký tự`);
    }
    const newPassword = pass(req.body?.newPassword);
    if (newPassword) {
      if (newPassword.length < MIN_PASSWORD) throw new HttpError(400, `Mật khẩu mới tối thiểu ${MIN_PASSWORD} ký tự`);
      // Tài khoản tạo bằng Google chưa có mật khẩu thì cho đặt mới luôn
      if (hash && !(await bcrypt.compare(pass(req.body?.currentPassword), hash))) {
        throw new HttpError(400, 'Mật khẩu hiện tại không đúng');
      }
      hash = await bcrypt.hash(newPassword, 10);
    }
    const { rows } = await db.query(
      'update app_users set full_name = $2, password_hash = $3 where id = $1 returning *', [user.id, fullName, hash]);
    res.json(publicUser(rows[0]));
  };
}

export function authRouter({ db, sendMail, verifyGoogle, jwtSecret }) {
  const router = Router();
  const session = (user) => ({ token: signToken(user, jwtSecret), user: publicUser(user) });
  const one = async (sql, params) => (await db.query(sql, params)).rows[0];

  async function issueOtp(user, purpose) {
    const last = await one('select expires_at from otps where user_id = $1 and purpose = $2', [user.id, purpose]);
    const waitMs = last ? new Date(last.expires_at) - OTP_TTL_MS + OTP_RESEND_MS - Date.now() : 0;
    if (waitMs > 0) throw new HttpError(429, `Vui lòng đợi ${Math.ceil(waitMs / 1000)} giây rồi gửi lại mã`);
    const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, '0');
    await db.query(
      `insert into otps (user_id, purpose, code_hash, expires_at) values ($1, $2, $3, $4)
       on conflict (user_id, purpose) do update set code_hash = $3, attempts = 0, expires_at = $4`,
      [user.id, purpose, sha256(code), new Date(Date.now() + OTP_TTL_MS)]);
    try {
      await sendMail(user.email, code, purpose);
    } catch (err) {
      console.error('Gửi email OTP lỗi:', err);
      throw new HttpError(502, 'Không gửi được email OTP, hãy thử lại');
    }
  }

  async function consumeOtp(user, purpose, code) {
    const otp = await one('select * from otps where user_id = $1 and purpose = $2', [user.id, purpose]);
    if (!otp || new Date(otp.expires_at) < new Date()) throw new HttpError(400, 'Mã OTP đã hết hạn, hãy gửi lại mã mới');
    if (otp.code_hash !== sha256(str(code))) {
      if (otp.attempts + 1 >= OTP_MAX_ATTEMPTS) {
        await db.query('delete from otps where user_id = $1 and purpose = $2', [user.id, purpose]);
        throw new HttpError(400, 'Nhập sai quá nhiều lần, hãy gửi lại mã mới');
      }
      await db.query('update otps set attempts = attempts + 1 where user_id = $1 and purpose = $2', [user.id, purpose]);
      throw new HttpError(400, 'Mã OTP không đúng');
    }
    await db.query('delete from otps where user_id = $1 and purpose = $2', [user.id, purpose]);
  }

  // Tài khoản tự đăng ký là khách hàng (chủ vé tháng); quản lý / bảo vệ do admin cấp quyền.
  router.post('/register', async (req, res) => {
    const email = str(req.body?.email).toLowerCase();
    const username = str(req.body?.username).toLowerCase();
    const fullName = str(req.body?.fullName).slice(0, MAX_FULLNAME);
    const password = pass(req.body?.password);
    if (!EMAIL_RE.test(email)) throw new HttpError(400, 'Email không hợp lệ');
    if (!USERNAME_RE.test(username)) throw new HttpError(400, 'Tên đăng nhập 3–30 ký tự: chữ thường, số, dấu _ hoặc .');
    if (password.length < MIN_PASSWORD) throw new HttpError(400, `Mật khẩu tối thiểu ${MIN_PASSWORD} ký tự`);

    const existing = await one('select * from app_users where email = $1 or username = $2', [email, username]);
    // Đăng ký lại khi chưa xác minh (VD: mất mã OTP) thì cho cập nhật và gửi mã mới.
    const isRetry = existing && !existing.active && existing.email === email && existing.username === username;
    if (existing && !isRetry) throw new HttpError(409, 'Tên đăng nhập hoặc email đã được dùng');
    const hash = await bcrypt.hash(password, 10);
    const user = isRetry
      ? await one('update app_users set full_name = $2, password_hash = $3 where id = $1 returning *',
        [existing.id, fullName, hash])
      : await one('insert into app_users (email, username, full_name, password_hash) values ($1, $2, $3, $4) returning *',
        [email, username, fullName, hash]);
    await issueOtp(user, 'register');
    res.status(201).json({ message: 'Đã gửi mã OTP tới email', email: maskEmail(email) });
  });

  router.post('/register/verify', async (req, res) => {
    const user = await one('select * from app_users where email = $1', [str(req.body?.email).toLowerCase()]);
    if (!user || user.active) throw new HttpError(400, 'Không có tài khoản nào đang chờ xác minh với email này');
    await consumeOtp(user, 'register', req.body?.code);
    res.json(session(await one('update app_users set active = true where id = $1 returning *', [user.id])));
  });

  router.post('/login', async (req, res) => {
    const user = await one('select * from app_users where username = $1', [str(req.body?.username).toLowerCase()]);
    const ok = user?.password_hash && (await bcrypt.compare(pass(req.body?.password), user.password_hash));
    if (!ok) throw new HttpError(401, 'Sai tên đăng nhập hoặc mật khẩu');
    if (!user.active) throw new HttpError(403, 'Tài khoản chưa xác minh email');
    await issueOtp(user, 'login');
    res.json({ message: 'Đã gửi mã OTP tới email', email: maskEmail(user.email) });
  });

  router.post('/login/verify', async (req, res) => {
    const user = await one('select * from app_users where username = $1', [str(req.body?.username).toLowerCase()]);
    if (!user?.active) throw new HttpError(400, 'Tài khoản không hợp lệ');
    await consumeOtp(user, 'login', req.body?.code);
    res.json(session(user));
  });

  // OAuth2: app gửi idToken lấy từ Google Sign-In, backend tự xác thực với Google.
  router.post('/google', async (req, res) => {
    let payload;
    try {
      payload = await verifyGoogle(str(req.body?.idToken));
    } catch {
      throw new HttpError(401, 'Token Google không hợp lệ');
    }
    if (!payload?.email_verified) throw new HttpError(400, 'Email Google chưa được xác minh');
    const email = payload.email.toLowerCase();
    let user = await one('select * from app_users where google_id = $1 or email = $2', [payload.sub, email]);
    if (!user) {
      const base = email.split('@')[0].toLowerCase().replace(/[^a-z0-9_.]/g, '').slice(0, 24).padEnd(3, '0');
      const taken = await one('select 1 from app_users where username = $1', [base]);
      user = await one('insert into app_users (email, username) values ($1, $2) returning *',
        [email, taken ? `${base}_${crypto.randomInt(1000, 10000)}` : base]);
    }
    // Google đã xác minh email nên kích hoạt luôn
    user = await one(
      `update app_users set google_id = $2, active = true, full_name = coalesce(nullif(full_name, ''), $3)
       where id = $1 returning *`, [user.id, payload.sub, payload.name ?? '']);
    res.json(session(user));
  });

  return router;
}
