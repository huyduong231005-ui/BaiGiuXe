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
  capacity: { type: Number, default: 50 }, // dùng khi chưa vẽ sơ đồ ô đậu; có ô thì sức chứa = số ô
  night_mark: { type: String, default: '22:00:00' },
  layout: { type: [String], default: [] }, // mặt bằng bãi dạng lưới ký tự (xem layout.js)
  lot_name: { type: String, default: 'Bãi giữ xe' },
  address: S,
  lat: N,
  lng: N,
}, opts), 'settings');

// Loại xe và bảng giá (vé lượt ngày / mỗi đêm, vé tháng). code: motorbike | car | bicycle | ...
export const VehicleType = model('VehicleType', new Schema({
  _id: Number,
  code: { type: String, required: true, unique: true },
  name: { type: String, required: true },
  price_day: { type: Number, default: 0 },
  price_night: { type: Number, default: 0 },
  price_month: { type: Number, default: 0 },
}, opts), 'vehicle_types');

// Khu đậu xe: tên 1 chữ cái (trùng ký tự vẽ ô của khu trên mặt bằng), cùng một loại xe.
export const Zone = model('Zone', new Schema({
  _id: Number,
  name: { type: String, required: true, unique: true },
  vehicle_type: { type: String, required: true },
}, opts), 'zones');

// Ô đậu, sinh từ mặt bằng (row, col = vị trí trên lưới). card_uid = ô riêng của cư dân (thẻ tháng); null = ô cho khách.
export const Slot = model('Slot', new Schema({
  _id: Number,
  code: { type: String, required: true, unique: true }, // VD: A-01
  zone_id: { type: Number, required: true },
  row: Number,
  col: Number,
  vehicle_type: String,
  card_uid: S,
  active: { type: Boolean, default: true }, // false = ô tạm khoá (sửa chữa...)
}, opts).index({ card_uid: 1 }, { unique: true, partialFilterExpression: { card_uid: { $type: 'string' } } }), 'slots');

// Khoản thu ngoài phí lượt: vé tháng (duyệt đơn đăng ký / gia hạn).
export const Payment = model('Payment', new Schema({
  _id: Number,
  kind: { type: String, default: 'monthly' },
  amount: { type: Number, required: true },
  card_uid: S,
  user_id: N,
  request_id: N,
  months: N,
  vehicle_type: S,
  note: S,
  created_at: now,
}, opts).index({ created_at: -1 }), 'payments');

export const Card = model('Card', new Schema({
  uid: { type: String, required: true, unique: true },
  kind: { type: String, default: 'guest' },
  vehicle_type: S, // vé tháng: loại xe (giá tháng, ô đậu); vé lượt: null, loại xe lấy theo lượt gửi
  apartment: S, // căn hộ của chủ thẻ (VD: A1-12.05)
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
  vehicle_type: { type: String, default: 'motorbike' },
  slot_code: S, // ô đậu được chỉ lúc vào
  offline: { type: Boolean, default: false }, // ghi bù từ ESP32 sau khi mất mạng
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
  // Số liệu nhận diện biển của lượt quẹt (để thống kê tốc độ / độ chính xác)
  ocr_ms: N, // thời gian chụp + OCR (gồm cả lần chụp lại)
  total_ms: N, // từ lúc quẹt tới lúc có kết quả
  shots: N, // số lần chụp (1 hoặc 2)
  score: N,
  vehicle_type: S,
  slot_code: S,
  offline_key: S, // lượt ghi bù từ ESP32: chống ghi trùng khi gửi lại
  created_at: now,
}, opts).index({ kind: 1, status: 1 })
  .index({ offline_key: 1 }, { unique: true, partialFilterExpression: { offline_key: { $type: 'string' } } }), 'gate_events');

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
  vehicle_type: { type: String, default: 'motorbike' },
  apartment: S,
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

// Giá mặc định tham khảo chung cư TP.HCM (QĐ 35/2018 trần xe máy 310.000đ/tháng; dự án thực tế 100–150k xe máy,
// ô tô 1,2–1,5 triệu). Quản lý sửa được trong app.
const DEFAULT_TYPES = [
  ['motorbike', 'Xe máy', 5000, 10000, 150000],
  ['car', 'Ô tô', 25000, 50000, 1500000],
  ['bicycle', 'Xe đạp', 2000, 5000, 100000],
];

const DEFAULT_SHIFTS = [['Ca sáng', '06:00:00', '14:00:00'], ['Ca chiều', '14:00:00', '22:00:00'], ['Ca đêm', '22:00:00', '06:00:00']];

/** Tạo index, dòng cài đặt và 3 ca mặc định nếu CSDL còn trống (thay cho migration). */
export async function initDb() {
  await Promise.all(Object.values(mongoose.models).map((m) => m.syncIndexes()));
  await Settings.updateOne({ _id: 1 }, { $setOnInsert: { capacity: 50 } }, { upsert: true, setDefaultsOnInsert: true });
  if (!(await VehicleType.exists({}))) {
    for (const [code, name, day, night, month] of DEFAULT_TYPES) {
      await insert(VehicleType, { code, name, price_day: day, price_night: night, price_month: month });
    }
  }
  if (!(await ShiftDef.exists({}))) {
    for (const [name, start, end] of DEFAULT_SHIFTS) await insert(ShiftDef, { name, start_time: start, end_time: end });
  }
}

/** Escape chuỗi người dùng nhập trước khi đưa vào RegExp (tìm kiếm "chứa"). */
export const contains = (s) => new RegExp(String(s).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i');
