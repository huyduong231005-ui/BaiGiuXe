import crypto from 'node:crypto';
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { insert, Otp, row, User } from './db.js';

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
 */
export function requireAuth({ jwtSecret }, ...roles) {
  return async (req, _res, next) => {
    const token = req.get('authorization')?.replace(/^Bearer /, '') ?? '';
    let sub;
    try {
      ({ sub } = jwt.verify(token, jwtSecret));
    } catch {
      throw new HttpError(401, 'Phiên đăng nhập không hợp lệ hoặc đã hết hạn');
    }
    const user = row(await User.findById(Number(sub) || 0).lean());
    if (!user?.active) throw new HttpError(401, 'Tài khoản không còn hoạt động');
    if (roles.length && !roles.includes(user.role)) throw new HttpError(403, 'Bạn không có quyền làm việc này');
    req.user = user;
    next();
  };
}

/** PATCH /me: tự đổi họ tên và mật khẩu (phải nhập đúng mật khẩu hiện tại). */
export function updateProfile() {
  return async (req, res) => {
    const { user } = req;
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
    res.json(publicUser(await setUser(user.id, { full_name: fullName, password_hash: hash })));
  };
}

/** Sửa tài khoản, trả về dòng mới (null nếu không có). */
export const setUser = async (id, changes) =>
  row(await User.findByIdAndUpdate(id, changes, { new: true }).lean());

const findUser = async (filter) => row(await User.findOne(filter).lean());

export function authRouter({ sendMail, verifyGoogle, jwtSecret }) {
  const router = Router();
  const session = (user) => ({ token: signToken(user, jwtSecret), user: publicUser(user) });
  const otpOf = (user, purpose) => ({ user_id: user.id, purpose });

  async function issueOtp(user, purpose) {
    const last = await Otp.findOne(otpOf(user, purpose)).lean();
    const waitMs = last ? new Date(last.expires_at) - OTP_TTL_MS + OTP_RESEND_MS - Date.now() : 0;
    if (waitMs > 0) throw new HttpError(429, `Vui lòng đợi ${Math.ceil(waitMs / 1000)} giây rồi gửi lại mã`);
    const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, '0');
    await Otp.updateOne(otpOf(user, purpose),
      { code_hash: sha256(code), attempts: 0, expires_at: new Date(Date.now() + OTP_TTL_MS) }, { upsert: true });
    try {
      await sendMail(user.email, code, purpose);
    } catch (err) {
      console.error('Gửi email OTP lỗi:', err);
      throw new HttpError(502, 'Không gửi được email OTP, hãy thử lại');
    }
  }

  async function consumeOtp(user, purpose, code) {
    const otp = await Otp.findOne(otpOf(user, purpose)).lean();
    if (!otp || new Date(otp.expires_at) < new Date()) throw new HttpError(400, 'Mã OTP đã hết hạn, hãy gửi lại mã mới');
    if (otp.code_hash !== sha256(str(code))) {
      if (otp.attempts + 1 >= OTP_MAX_ATTEMPTS) {
        await Otp.deleteOne(otpOf(user, purpose));
        throw new HttpError(400, 'Nhập sai quá nhiều lần, hãy gửi lại mã mới');
      }
      await Otp.updateOne(otpOf(user, purpose), { $inc: { attempts: 1 } });
      throw new HttpError(400, 'Mã OTP không đúng');
    }
    await Otp.deleteOne(otpOf(user, purpose));
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

    const existing = await findUser({ $or: [{ email }, { username }] });
    // Đăng ký lại khi chưa xác minh (VD: mất mã OTP) thì cho cập nhật và gửi mã mới.
    const isRetry = existing && !existing.active && existing.email === email && existing.username === username;
    if (existing && !isRetry) throw new HttpError(409, 'Tên đăng nhập hoặc email đã được dùng');
    const hash = await bcrypt.hash(password, 10);
    const user = isRetry
      ? await setUser(existing.id, { full_name: fullName, password_hash: hash })
      : await insert(User, { email, username, full_name: fullName, password_hash: hash });
    await issueOtp(user, 'register');
    res.status(201).json({ message: 'Đã gửi mã OTP tới email', email: maskEmail(email) });
  });

  router.post('/register/verify', async (req, res) => {
    const user = await findUser({ email: str(req.body?.email).toLowerCase() });
    if (!user || user.active) throw new HttpError(400, 'Không có tài khoản nào đang chờ xác minh với email này');
    await consumeOtp(user, 'register', req.body?.code);
    res.json(session(await setUser(user.id, { active: true })));
  });

  router.post('/login', async (req, res) => {
    const user = await findUser({ username: str(req.body?.username).toLowerCase() });
    const ok = user?.password_hash && (await bcrypt.compare(pass(req.body?.password), user.password_hash));
    if (!ok) throw new HttpError(401, 'Sai tên đăng nhập hoặc mật khẩu');
    if (!user.active) throw new HttpError(403, 'Tài khoản chưa xác minh email');
    await issueOtp(user, 'login');
    res.json({ message: 'Đã gửi mã OTP tới email', email: maskEmail(user.email) });
  });

  router.post('/login/verify', async (req, res) => {
    const user = await findUser({ username: str(req.body?.username).toLowerCase() });
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
    let user = await findUser({ $or: [{ google_id: payload.sub }, { email }] });
    if (!user) {
      const base = email.split('@')[0].toLowerCase().replace(/[^a-z0-9_.]/g, '').slice(0, 24).padEnd(3, '0');
      const taken = await User.exists({ username: base });
      user = await insert(User, { email, username: taken ? `${base}_${crypto.randomInt(1000, 10000)}` : base });
    }
    // Google đã xác minh email nên kích hoạt luôn
    user = await setUser(user.id, { google_id: payload.sub, active: true, full_name: user.full_name || payload.name || '' });
    res.json(session(user));
  });

  return router;
}
