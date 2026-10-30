import pg from 'pg';
import { OAuth2Client } from 'google-auth-library';
import { createApp } from './app.js';
import { brevoMailer } from './mail.js';

const env = process.env;
const REQUIRED = ['DATABASE_URL', 'JWT_SECRET', 'SUPABASE_URL', 'SUPABASE_SERVICE_KEY', 'PLATE_TOKEN',
  'GOOGLE_CLIENT_ID', 'BREVO_API_KEY', 'MAIL_FROM'];
const missing = REQUIRED.filter((k) => !env[k]);
if (missing.length) throw new Error(`Thiếu biến môi trường: ${missing.join(', ')}`);

const SUPABASE_TOKEN_CACHE_MS = 5 * 60 * 1000;
const SIGNED_URL_TTL_S = 3600;

// Cột date (hạn vé tháng) giữ nguyên chuỗi 'YYYY-MM-DD': đổi sang Date theo múi giờ máy chủ dễ lệch 1 ngày.
pg.types.setTypeParser(1082, (v) => v);

// Chuỗi kết nối Session pooler của Supabase (IPv4): Render không ra được IPv6 nên không dùng db.<ref>.supabase.co.
const db = new pg.Pool({ connectionString: env.DATABASE_URL, ssl: { rejectUnauthorized: false }, max: 5 });
const google = new OAuth2Client();
const supabaseHeaders = { apikey: env.SUPABASE_SERVICE_KEY, authorization: `Bearer ${env.SUPABASE_SERVICE_KEY}` };

// Token Supabase của ĐT camera: hỏi Supabase Auth một lần rồi nhớ 5 phút (mỗi lượt quẹt thẻ gọi OCR qua API).
// ponytail: cache trong RAM của 1 instance, đủ cho gói free; dùng chung Redis nếu chạy nhiều instance.
const tokenCache = new Map();
async function verifySupabase(token) {
  const hit = tokenCache.get(token);
  if (hit && hit.until > Date.now()) return hit.user;
  const res = await fetch(`${env.SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: env.SUPABASE_SERVICE_KEY, authorization: `Bearer ${token}` },
  });
  const body = res.ok ? await res.json() : null;
  const user = body?.app_metadata?.role === 'staff' ? { email: body.email } : null;
  if (tokenCache.size > 1000) tokenCache.clear();
  tokenCache.set(token, { user, until: Date.now() + SUPABASE_TOKEN_CACHE_MS });
  return user;
}

async function signImage(path) {
  const res = await fetch(`${env.SUPABASE_URL}/storage/v1/object/sign/plates/${path}`, {
    method: 'POST',
    headers: { ...supabaseHeaders, 'content-type': 'application/json' },
    body: JSON.stringify({ expiresIn: SIGNED_URL_TTL_S }),
  });
  if (!res.ok) throw Object.assign(new Error('Không lấy được ảnh'), { status: res.status === 400 ? 404 : 502 });
  return `${env.SUPABASE_URL}/storage/v1${(await res.json()).signedURL}`;
}

createApp({
  db,
  jwtSecret: env.JWT_SECRET,
  plateToken: env.PLATE_TOKEN,
  sendMail: brevoMailer({ apiKey: env.BREVO_API_KEY, from: env.MAIL_FROM }),
  verifyGoogle: async (idToken) => (await google.verifyIdToken({ idToken, audience: env.GOOGLE_CLIENT_ID })).getPayload(),
  verifySupabase,
  signImage,
}).listen(env.PORT ?? 3000, () => console.log(`API chạy ở cổng ${env.PORT ?? 3000}, múi giờ ${env.TZ ?? 'hệ thống'}`));
