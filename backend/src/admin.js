// Quản trị tài khoản API: xem, đổi vai trò, khoá, gắn với hồ sơ bảo vệ, xoá.
import { Router } from 'express';
import { HttpError, publicUser, ROLES, str } from './auth.js';

export function adminRouter({ db }) {
  const router = Router();

  router.get('/users', async (req, res) => {
    const q = `%${str(req.query.q).toLowerCase()}%`;
    const role = str(req.query.role);
    const { rows } = await db.query(
      `select * from app_users where (username like $1 or lower(email) like $1 or lower(full_name) like $1)
       and ($2 = '' or role = $2) order by id`, [q, role]);
    res.json(rows.map(publicUser));
  });

  router.patch('/users/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    const [user] = (await db.query('select * from app_users where id = $1', [id])).rows;
    if (!user) throw new HttpError(404, 'Không có tài khoản này');
    const b = req.body ?? {};
    const role = b.role ?? user.role;
    if (!ROLES.includes(role)) throw new HttpError(400, `Vai trò là một trong: ${ROLES.join(', ')}`);
    if (id === req.user.id && (role !== 'admin' || b.active === false)) {
      throw new HttpError(400, 'Không tự hạ quyền hoặc tự khoá tài khoản admin đang dùng');
    }
    const guardId = 'guardId' in b ? b.guardId : user.guard_id;
    if (guardId !== null && !Number.isInteger(guardId)) throw new HttpError(400, 'guardId là số hoặc null');
    const { rows } = await db.query(
      `update app_users set role = $2, active = $3, guard_id = $4, full_name = $5 where id = $1 returning *`,
      [id, role, typeof b.active === 'boolean' ? b.active : user.active, guardId,
        b.fullName !== undefined ? str(b.fullName) : user.full_name]);
    res.json(publicUser(rows[0]));
  });

  router.delete('/users/:id', async (req, res) => {
    const id = Number(req.params.id) || 0;
    if (id === req.user.id) throw new HttpError(400, 'Không tự xoá tài khoản đang dùng');
    const { rowCount } = await db.query('delete from app_users where id = $1', [id]);
    if (!rowCount) throw new HttpError(404, 'Không có tài khoản này');
    res.status(204).end();
  });
  return router;
}
