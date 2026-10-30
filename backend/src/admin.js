// Quản trị tài khoản API: xem, đổi vai trò, khoá, gắn với hồ sơ bảo vệ, xoá.
import { Router } from 'express';
import bcrypt from 'bcryptjs';
import { EMAIL_RE, HttpError, MIN_PASSWORD, publicUser, ROLES, setUser, str, USERNAME_RE } from './auth.js';
import { Card, contains, insert, Otp, row, TicketRequest, User } from './db.js';

export function adminRouter() {
  const router = Router();

  // Admin tạo sẵn tài khoản (quản lý, bảo vệ, khách vé tháng) đã kích hoạt, không cần OTP đăng ký.
  router.post('/users', async (req, res) => {
    const b = req.body ?? {};
    const email = str(b.email).toLowerCase();
    const username = str(b.username).toLowerCase();
    const password = typeof b.password === 'string' ? b.password : '';
    const role = b.role ?? 'customer';
    if (!EMAIL_RE.test(email)) throw new HttpError(400, 'Email không hợp lệ');
    if (!USERNAME_RE.test(username)) throw new HttpError(400, 'Tên đăng nhập 3–30 ký tự: chữ thường, số, dấu _ hoặc .');
    if (password.length < MIN_PASSWORD) throw new HttpError(400, `Mật khẩu tối thiểu ${MIN_PASSWORD} ký tự`);
    if (!ROLES.includes(role)) throw new HttpError(400, `Vai trò là một trong: ${ROLES.join(', ')}`);
    const guardId = Number.isInteger(b.guardId) ? b.guardId : null;
    const user = await insert(User, {
      email, username, full_name: str(b.fullName), password_hash: await bcrypt.hash(password, 10), role,
      guard_id: guardId, active: true,
    });
    res.status(201).json(publicUser(user));
  });

  router.get('/users', async (req, res) => {
    const q = contains(str(req.query.q));
    const role = str(req.query.role);
    const users = await User.find({ $or: [{ username: q }, { email: q }, { full_name: q }], ...(role ? { role } : {}) })
      .sort({ _id: 1 }).lean();
    res.json(users.map((u) => publicUser(row(u))));
  });

  router.patch('/users/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    const user = row(await User.findById(id).lean());
    if (!user) throw new HttpError(404, 'Không có tài khoản này');
    const b = req.body ?? {};
    const role = b.role ?? user.role;
    if (!ROLES.includes(role)) throw new HttpError(400, `Vai trò là một trong: ${ROLES.join(', ')}`);
    if (id === req.user.id && (role !== 'admin' || b.active === false)) {
      throw new HttpError(400, 'Không tự hạ quyền hoặc tự khoá tài khoản admin đang dùng');
    }
    const guardId = 'guardId' in b ? b.guardId : user.guard_id;
    if (guardId !== null && !Number.isInteger(guardId)) throw new HttpError(400, 'guardId là số hoặc null');
    res.json(publicUser(await setUser(id, {
      role, active: typeof b.active === 'boolean' ? b.active : user.active, guard_id: guardId,
      full_name: b.fullName !== undefined ? str(b.fullName) : user.full_name,
    })));
  });

  // Như khoá ngoại cũ: xoá mã OTP và đơn vé tháng của tài khoản, thẻ / đơn đã duyệt bỏ liên kết.
  router.delete('/users/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    if (id === req.user.id) throw new HttpError(400, 'Không tự xoá tài khoản đang dùng');
    if (!(await User.findByIdAndDelete(id))) throw new HttpError(404, 'Không có tài khoản này');
    await Promise.all([
      Otp.deleteMany({ user_id: id }),
      TicketRequest.deleteMany({ user_id: id }),
      TicketRequest.updateMany({ handled_by: id }, { handled_by: null }),
      Card.updateMany({ user_id: id }, { user_id: null }),
    ]);
    res.status(204).end();
  });
  return router;
}
