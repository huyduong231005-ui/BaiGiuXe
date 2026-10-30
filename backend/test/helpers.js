// MongoDB trong bộ nhớ (mongodb-memory-server) cho từng file test; mail và Google được giả lập.
import mongoose from 'mongoose';
import { MongoMemoryServer } from 'mongodb-memory-server';
import { createApp } from '../src/app.js';
import * as db from '../src/db.js';
import { calcFee } from '../src/rules.js';

process.env.TZ = 'Asia/Ho_Chi_Minh';

export const JWT_SECRET = 'test-secret';

/** App + server thật trên cổng ngẫu nhiên. ctx.db là các model trong src/db.js để dựng dữ liệu. */
export async function startApp(overrides = {}) {
  const mongo = await MongoMemoryServer.create();
  await mongoose.connect(mongo.getUri());
  await db.initDb();
  const mails = [];
  const app = createApp({
    jwtSecret: JWT_SECRET,
    sendMail: async (to, code, purpose) => mails.push({ to, code, purpose }),
    verifyGoogle: async () => { throw new Error('không dùng'); },
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
    await mongoose.disconnect();
    await mongo.stop();
  };
  return { db, mails, call, close, base };
}

/** Tạo tài khoản đã kích hoạt với vai trò cho trước và trả về JWT (qua đúng luồng OTP). */
export async function loginAs(ctx, role, username = role) {
  const email = `${username}@test.vn`;
  await ctx.call('POST', '/auth/register', { body: { email, username, password: 'matkhau1' } });
  const reg = ctx.mails.findLast((m) => m.to === email);
  const { body } = await ctx.call('POST', '/auth/register/verify', { body: { email, code: reg.code } });
  if (role !== 'customer') await ctx.db.User.updateOne({ username }, { role });
  return body.token;
}

const H = 3600e3;
export const ago = (h) => new Date(Date.now() - h * H);

/** Phí xe máy (giá mặc định) cho lượt vào lúc timeIn, ra bây giờ: test không phụ thuộc giờ chạy (ngày / đêm). */
export const motorbikeFeeNow = (timeIn) =>
  calcFee(timeIn, new Date(), { night_mark: '22:00:00', price_day: 5000, price_night: 10000 });
