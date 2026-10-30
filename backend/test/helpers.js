// Dựng CSDL giống Supabase trong bộ nhớ (PGlite) rồi chạy nguyên các migration của repo.
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto';
import { createApp } from '../src/app.js';

process.env.TZ = 'Asia/Ho_Chi_Minh';
const MIGRATIONS = fileURLToPath(new URL('../../supabase/migrations/', import.meta.url));

// Những gì Supabase có sẵn mà migration dùng tới.
const SUPABASE_STUBS = `
  create schema extensions;
  create schema auth;
  create function auth.jwt() returns jsonb language sql stable as $$ select null::jsonb $$;
  create schema storage;
  create table storage.buckets (id text primary key, name text, public boolean);
  create table storage.objects (bucket_id text);
  alter table storage.objects enable row level security;
  create role anon;
  create role authenticated;
  create publication supabase_realtime;
`;

/** PGlite bọc lại cho giống pg.Pool: query() trả { rows, rowCount }. */
export async function createDb() {
  const pg = await PGlite.create({ extensions: { pgcrypto } });
  await pg.exec(SUPABASE_STUBS);
  for (const f of readdirSync(MIGRATIONS).sort()) await pg.exec(readFileSync(MIGRATIONS + f, 'utf8'));
  return {
    query: async (sql, params) => {
      const r = await pg.query(sql, params);
      return { rows: r.rows, rowCount: r.affectedRows ?? r.rows.length };
    },
    close: () => pg.close(),
  };
}

export const JWT_SECRET = 'test-secret';

/** App + server thật trên cổng ngẫu nhiên; mail và Google được giả lập. */
export async function startApp(overrides = {}) {
  const db = await createDb();
  const mails = [];
  const app = createApp({
    db,
    jwtSecret: JWT_SECRET,
    sendMail: async (to, code, purpose) => mails.push({ to, code, purpose }),
    verifyGoogle: async () => { throw new Error('không dùng'); },
    verifySupabase: async () => null,
    plateToken: 'plate-token',
    ...overrides,
  });
  const server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const call = async (method, path, { token, body, raw, headers } = {}) => {
    const res = await fetch(base + path, {
      method,
      headers: {
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
        ...(token ? { authorization: `Bearer ${token}` } : {}),
        ...headers,
      },
      body: raw ?? (body !== undefined ? JSON.stringify(body) : undefined),
    });
    const text = await res.text();
    return { status: res.status, body: text ? JSON.parse(text) : null };
  };
  const close = async () => {
    await new Promise((r) => server.close(r));
    await db.close();
  };
  return { db, mails, call, close, base };
}

/** Tạo tài khoản đã kích hoạt với vai trò cho trước và trả về JWT (qua đúng luồng OTP). */
export async function loginAs(ctx, role, username = role) {
  const email = `${username}@test.vn`;
  await ctx.call('POST', '/auth/register', { body: { email, username, password: 'matkhau1' } });
  const reg = ctx.mails.findLast((m) => m.to === email);
  const { body } = await ctx.call('POST', '/auth/register/verify', { body: { email, code: reg.code } });
  if (role !== 'guard') await ctx.db.query('update app_users set role = $1 where username = $2', [role, username]);
  return body.token;
}
