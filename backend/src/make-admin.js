// Cấp quyền admin cho 1 tài khoản đã đăng ký: npm run make-admin -- <username>
import pg from 'pg';

const username = process.argv[2]?.toLowerCase();
if (!username) throw new Error('Cách dùng: npm run make-admin -- <username>');

const db = new pg.Client({ connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } });
await db.connect();
const { rows } = await db.query(
  "update app_users set role = 'admin', active = true where username = $1 returning username", [username]);
console.log(rows.length ? `Đã cấp quyền admin cho ${username}` : `Không có tài khoản ${username}`);
await db.end();
