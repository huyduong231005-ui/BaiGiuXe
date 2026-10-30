// Mô hình MongoDB (Mongoose). Giữ id số tự tăng và tên trường snake_case như các bảng Postgres trước đây,
// nên JSON trả về không đổi và app Flutter không phải sửa các màn hình.
import mongoose from 'mongoose';

const { Schema, model } = mongoose;
const opts = { versionKey: false };
const N = { type: Number, default: null };
const S = { type: String, default: null };
const D = { type: Date, default: null };
const now = { type: Date, default: Date.now };
const isNumber = (field) => ({ unique: true, partialFilterExpression: { [field]: { $type: 'number' } } });

const Counter = model('Counter', new Schema({ _id: String, seq: Number }, opts), 'counters');

/** Id số tự tăng theo từng collection (thay cho "generated always as identity"). */
export const nextId = async (name) =>
  (await Counter.findByIdAndUpdate(name, { $inc: { seq: 1 } }, { returnDocument: 'after', upsert: true })).seq;

/** Document (lean) -> dòng JSON giống Postgres: _id số thành id, bỏ các cờ nội bộ dùng cho index. */
export function row(d) {
  if (!d) return null;
  const { _id, parked, on_duty: onDuty, ...r } = d;
  return typeof _id === 'number' ? { id: _id, ...r } : r;
}

/** Thêm document có id số, trả về dòng JSON. */
export async function insert(Model, data) {
  const doc = await Model.create({ _id: await nextId(Model.collection.name), ...data });
  return row(doc.toObject());
}

export const User = model('User', new Schema({
  _id: Number,
  username: { type: String, required: true, unique: true },
  email: { type: String, required: true, unique: true },
  full_name: { type: String, default: '' },
  password_hash: S, // null với tài khoản tạo bằng Google
  google_id: S,
  role: { type: String, default: 'customer' },
  guard_id: N, // tài khoản bảo vệ gắn với hồ sơ bảo vệ
  active: { type: Boolean, default: false }, // true sau khi xác minh email
  created_at: now,
}, opts).index({ google_id: 1 }, { unique: true, partialFilterExpression: { google_id: { $type: 'string' } } })
  .index({ guard_id: 1 }, isNumber('guard_id')), 'app_users');

export const Otp = model('Otp', new Schema({
  user_id: Number,
  purpose: String,
  code_hash: String,
  attempts: { type: Number, default: 0 },
  expires_at: Date,
}, opts).index({ user_id: 1, purpose: 1 }, { unique: true }), 'otps');

export const Settings = model('Settings', new Schema({
  _id: Number, // luôn = 1
  capacity: { type: Number, default: 50 },
  price_day: { type: Number, default: 3000 },
  price_night: { type: Number, default: 5000 },
  night_mark: { type: String, default: '22:00:00' },
  lot_name: { type: String, default: 'Bãi giữ xe' },
  address: S,
  lat: N,
  lng: N,
}, opts), 'settings');

export const Card = model('Card', new Schema({
  uid: { type: String, required: true, unique: true },
  kind: { type: String, default: 'guest' },
  plate: S,
  owner: S,
  active: { type: Boolean, default: true },
  created_at: now,
  user_id: N, // chủ thẻ có tài khoản app
  valid_until: S, // 'YYYY-MM-DD': vé tháng dùng tới hết ngày này (null = không giới hạn)
  lost_at: D, // chủ thẻ báo mất: cổng từ chối cả lúc vào lẫn lúc ra
}, opts).index({ user_id: 1 }), 'cards');

export const Guard = model('Guard', new Schema({
  _id: Number,
  name: { type: String, required: true },
  finger_id: N, // ô vân tay trên AS608
  pin_hash: S, // bcrypt
}, opts).index({ finger_id: 1 }, isNumber('finger_id')), 'guards');

// parked = true khi chưa ra: 1 thẻ chỉ có 1 lượt đang gửi, 1 biển chỉ có 1 lượt đang gửi.
export const Session = model('Session', new Schema({
  _id: Number,
  card_uid: { type: String, required: true },
  plate_in: S,
  plate_out: S,
  img_in: S,
  img_out: S,
  time_in: now,
  time_out: D,
  fee: N,
  override_by: N, // bảo vệ mở tay
  parked: { type: Boolean, default: true },
}, opts).index({ card_uid: 1 }, { unique: true, partialFilterExpression: { parked: true } })
  .index({ plate_in: 1 }, { unique: true, partialFilterExpression: { parked: true } })
  .index({ time_in: -1 }), 'sessions');

export const GateEvent = model('GateEvent', new Schema({
  _id: Number,
  gate: String, // in | out
  kind: String, // scan | override | emergency | open_cmd
  uid: S,
  ref_id: N,
  guard_id: N,
  status: { type: String, default: 'pending' }, // pending | ok | denied | done
  plate: S,
  img: S,
  message: S,
  open: { type: Boolean, default: false },
  created_at: now,
}, opts).index({ kind: 1, status: 1 }), 'gate_events');

export const ShiftDef = model('ShiftDef', new Schema({
  _id: Number,
  name: String,
  start_time: String, // 'HH:MM:SS'
  end_time: String, // end_time <= start_time = ca qua đêm
}, opts), 'shift_defs');

// on_duty = true khi chưa chấm ra: mỗi bảo vệ chỉ có 1 ca đang mở.
export const Attendance = model('Attendance', new Schema({
  _id: Number,
  guard_id: { type: Number, required: true },
  shift_id: N,
  shift_name: S, // chép tên ca lúc chấm, đổi/xoá ca sau này không làm sai bảng công cũ
  shift_start: D, // mốc ca theo lịch (đã gắn ngày) để tính trễ / về sớm
  shift_end: D,
  time_in: now,
  time_out: D,
  method_in: S, // finger | pin
  method_out: S, // finger | pin | auto (quên chấm ra)
  on_duty: { type: Boolean, default: true },
}, opts).index({ guard_id: 1 }, { unique: true, partialFilterExpression: { on_duty: true } })
  .index({ time_in: -1 }), 'attendance');

export const TicketRequest = model('TicketRequest', new Schema({
  _id: Number,
  user_id: { type: Number, required: true },
  card_uid: S, // có = gia hạn thẻ đang dùng; null = đăng ký mới
  plate: String,
  owner_name: String,
  months: Number,
  note: S,
  status: { type: String, default: 'pending' }, // pending | approved | rejected | cancelled
  reply: S,
  handled_by: N,
  handled_at: D,
  created_at: now,
}, opts).index({ status: 1, created_at: -1 }), 'ticket_requests');

// Ảnh biển số (JPEG đã thu nhỏ ~150KB). ponytail: lưu thẳng trong MongoDB, tự xoá sau 90 ngày để không đầy
// 512MB của Atlas free; chuyển sang object storage nếu cần giữ ảnh lâu hơn.
export const PlateImage = model('PlateImage', new Schema({
  path: { type: String, required: true, unique: true },
  data: Buffer,
  created_at: { type: Date, default: Date.now, expires: 90 * 24 * 3600 },
}, opts), 'plate_images');

const DEFAULT_SHIFTS = [['Ca sáng', '06:00:00', '14:00:00'], ['Ca chiều', '14:00:00', '22:00:00'], ['Ca đêm', '22:00:00', '06:00:00']];

/** Tạo index, dòng cài đặt và 3 ca mặc định nếu CSDL còn trống (thay cho migration). */
export async function initDb() {
  await Promise.all(Object.values(mongoose.models).map((m) => m.syncIndexes()));
  await Settings.updateOne({ _id: 1 }, { $setOnInsert: { capacity: 50 } }, { upsert: true, setDefaultsOnInsert: true });
  if (!(await ShiftDef.exists({}))) {
    for (const [name, start, end] of DEFAULT_SHIFTS) await insert(ShiftDef, { name, start_time: start, end_time: end });
  }
}

/** Escape chuỗi người dùng nhập trước khi đưa vào RegExp (tìm kiếm "chứa"). */
export const contains = (s) => new RegExp(String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
