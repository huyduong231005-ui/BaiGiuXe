import mongoose from 'mongoose';
import { OAuth2Client } from 'google-auth-library';
import { createApp } from './app.js';
import { initDb } from './db.js';
import { brevoMailer } from './mail.js';

const env = process.env;
const REQUIRED = ['MONGODB_URI', 'JWT_SECRET', 'PLATE_TOKEN', 'GOOGLE_CLIENT_ID', 'BREVO_API_KEY', 'MAIL_FROM'];
const missing = REQUIRED.filter((k) => !env[k]);
if (missing.length) throw new Error(`Thiếu biến môi trường: ${missing.join(', ')}`);

const google = new OAuth2Client();

await mongoose.connect(env.MONGODB_URI);
await initDb();
createApp({
  jwtSecret: env.JWT_SECRET,
  plateToken: env.PLATE_TOKEN,
  sendMail: brevoMailer({ apiKey: env.BREVO_API_KEY, from: env.MAIL_FROM }),
  verifyGoogle: async (idToken) => (await google.verifyIdToken({ idToken, audience: env.GOOGLE_CLIENT_ID })).getPayload(),
}).listen(env.PORT ?? 3000, () => console.log(`API chạy ở cổng ${env.PORT ?? 3000}, múi giờ ${env.TZ ?? 'hệ thống'}`));
