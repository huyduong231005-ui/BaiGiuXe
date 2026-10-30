// Dữ liệu demo để thử / quay video: npm run seed-demo   (xoá: npm run seed-demo -- --remove)
// Email đều là email phụ Gmail huyduong455+...@gmail.com: mọi mã OTP về chung 1 hộp thư, không rơi vào Spam.
// Thẻ demo có UID DE0000xx, biển số giả: không đụng thẻ RFID thật của bãi.
import bcrypt from 'bcryptjs';
import mongoose from 'mongoose';
import {
  Attendance, Card, GateEvent, Guard, initDb, insert, Payment, Session, Settings, Slot, TicketRequest, User, Zone,
} from '../src/db.js';
import { SAMPLE_LAYOUT } from '../src/layout.js';
import { applyLayout } from '../src/lot.js';

const PASSWORD = 'demo1234';
const GUARD = 'Nguyễn Văn Tuấn';
const USERS = [
  ['admin', 'huyduong455+admin@gmail.com', 'Quản trị viên', 'admin'],
  ['quanly','huyduong455+ql@gmail.com', 'Trần Quản Lý', 'manager'],
  ['baove', 'huyduong455+bv@gmail.com', GUARD, 'guard'],
  ['khach01', 'huyduong455+kh01@gmail.com', 'Lê Minh Khách', 'customer'],
  ['khach02', 'huyduong455+kh02@gmail.com', 'Phạm Thu Hà', 'customer'],
];
const DEMO_UID = /^DE0000/;

process.env.TZ ||= 'Asia/Ho_Chi_Minh';
await mongoose.connect(process.env.MONGODB_URI);
await initDb();

const startOfDay = (daysAgo) => {
  const d = new Date();
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - daysAgo);
};
const at = (daysAgo, hm) => {
  const [h, m] = hm.split(':').map(Number);
  const d = startOfDay(daysAgo);
  d.setHours(h, m);
  return d;
};
const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const hoursAgo = (h) => new Date(Date.now() - h * 3600e3);

// Mặt bằng demo (chỉ tạo khi bãi chưa vẽ mặt bằng): A, B xe máy, C ô tô, D xe đạp (xem SAMPLE_LAYOUT).
const ZONES = [['A', 'motorbike'], ['B', 'motorbike'], ['C', 'car'], ['D', 'bicycle']];

async function remove() {
  const users = await User.find({ username: { $in: USERS.map((u) => u[0]) } }, { _id: 1 }).lean();
  const guards = await Guard.find({ name: GUARD }, { _id: 1 }).lean();
  await GateEvent.deleteMany({ uid: DEMO_UID });
  await Session.deleteMany({ card_uid: DEMO_UID });
  await TicketRequest.deleteMany({ user_id: { $in: users.map((u) => u._id) } });
  await Payment.deleteMany({ card_uid: DEMO_UID });
  await Slot.updateMany({ card_uid: DEMO_UID }, { card_uid: null });
  await Card.deleteMany({ uid: DEMO_UID });
  await User.deleteMany({ _id: { $in: users.map((u) => u._id) } });
  await Attendance.deleteMany({ guard_id: { $in: guards.map((g) => g._id) } });
  for (const g of guards) if (!(await Session.exists({ override_by: g._id }))) await Guard.deleteOne({ _id: g._id });
}

await remove();
if (process.argv.includes('--remove')) {
  console.log('Đã xoá dữ liệu demo');
} else {
  const hash = await bcrypt.hash(PASSWORD, 10);
  const g = await insert(Guard, { name: GUARD, pin_hash: await bcrypt.hash('2468', 10) });
  const id = {};
  for (const [username, email, name, role] of USERS) {
    id[username] = (await insert(User, { username, email, full_name: name, password_hash: hash, role,
      guard_id: role === 'guard' ? g.id : null, active: true })).id;
  }

  if (!(await Settings.findById(1).lean())?.layout?.length) {
    // ponytail: bãi demo chưa có mặt bằng thì xoá sơ đồ cũ dạng lưới (bản trước) rồi vẽ lại theo mặt bằng mẫu.
    await Slot.deleteMany({});
    await Zone.deleteMany({});
    for (const [name, vehicleType] of ZONES) await insert(Zone, { name, vehicle_type: vehicleType });
    await applyLayout(SAMPLE_LAYOUT);
  }

  // Thẻ: khach01 cư dân xe máy còn hạn (xe đang trong bãi, ô A-01), khach02 cư dân ô tô hết hạn (đang chờ gia hạn, ô C-01),
  // 2 thẻ lượt cho khách vãng lai.
  await Card.create([
    { uid: 'DE000001', kind: 'monthly', vehicle_type: 'motorbike', apartment: 'A1-12.05', plate: '59X188888', owner: 'Lê Minh Khách',
      user_id: id.khach01, valid_until: ymd(startOfDay(-25)) },
    { uid: 'DE000002', kind: 'monthly', vehicle_type: 'car', apartment: 'B2-03.01', plate: '51G22222', owner: 'Phạm Thu Hà',
      user_id: id.khach02, valid_until: ymd(startOfDay(3)) },
    { uid: 'DE000003', kind: 'guest' },
    { uid: 'DE000004', kind: 'guest' },
  ]);
  await Slot.updateOne({ code: 'A-01', card_uid: null }, { card_uid: 'DE000001' });
  await Slot.updateOne({ code: 'C-01', card_uid: null }, { card_uid: 'DE000002' });

  // Khoản thu vé tháng 6 tháng gần đây (biểu đồ doanh thu theo tháng có số).
  for (let m = 0; m < 6; m++) {
    const at = new Date(new Date().getFullYear(), new Date().getMonth() - m, 3 + m, 9);
    await insert(Payment, { amount: 150000, card_uid: 'DE000001', user_id: id.khach01, months: 1, vehicle_type: 'motorbike', created_at: at });
    if (m > 0) await insert(Payment, { amount: 1500000, card_uid: 'DE000002', user_id: id.khach02, months: 1, vehicle_type: 'car', created_at: at });
  }

  // Lượt gửi 7 ngày qua: vé tháng miễn phí, vé lượt có phí ngày / đêm (biểu đồ doanh thu có số).
  // [thẻ, biển, loại xe, ô, ngày trước, giờ vào, giờ ra, phí]. Giá: xe máy 5.000đ / qua đêm 10.000đ, ô tô 25.000đ.
  const closed = [
    ['DE000001', '59X188888', 'motorbike', 'A-01', 6, 8, 17, 0], ['DE000001', '59X188888', 'motorbike', 'A-01', 4, 8, 18, 0],
    ['DE000001', '59X188888', 'motorbike', 'A-01', 2, 7, 17, 0], ['DE000002', '51G22222', 'car', 'C-01', 5, 9, 16, 0],
    ['DE000003', '30A12345', 'motorbike', 'A-02', 6, 9, 11, 5000], ['DE000004', '51H67890', 'car', 'C-02', 5, 13, 15, 25000],
    ['DE000003', '61C24680', 'motorbike', 'A-03', 4, 20, 31, 10000], ['DE000004', '43D13579', 'motorbike', 'A-02', 3, 10, 12, 5000],
    ['DE000003', '30A12345', 'motorbike', 'A-02', 2, 14, 16, 5000], ['DE000004', '29B67890', 'motorbike', 'A-04', 1, 19, 32, 10000],
    ['DE000003', '51H67890', 'car', 'C-02', 1, 8, 9, 25000], ['DE000004', '43D13579', 'motorbike', 'A-02', 0, 7, 9, 5000],
  ];
  // Số đo nhận diện mẫu (giống đo thực tế ~1,4-2,2s, độ tin cậy 0,9-0,99). Thống kê thật lấy từ lượt quẹt thật.
  const metric = (i, shots = 1) => ({ ocr_ms: 1350 + ((i * 137) % 900) + (shots - 1) * 1700, total_ms: 1900 + ((i * 137) % 900) + (shots - 1) * 1700,
    shots, score: Math.round((0.9 + ((i * 7) % 10) / 100) * 1000) / 1000 });
  let i = 0;
  for (const [card, plate, vt, slot, daysAgo, inH, outH, fee] of closed) {
    const timeIn = new Date(startOfDay(daysAgo).getTime() + inH * 3600e3);
    const timeOut = new Date(startOfDay(daysAgo).getTime() + outH * 3600e3);
    await insert(Session, { card_uid: card, plate_in: plate, plate_out: plate, time_in: timeIn, time_out: timeOut, fee,
      vehicle_type: vt, slot_code: slot, parked: false });
    await insert(GateEvent, { gate: 'in', kind: 'scan', uid: card, status: 'ok', plate, message: `Moi vao o ${slot}`,
      vehicle_type: vt, slot_code: slot, created_at: timeIn, ...metric(i++) });
    await insert(GateEvent, { gate: 'out', kind: 'scan', uid: card, status: 'ok', plate, message: `Phi: ${fee}d`, open: true,
      vehicle_type: vt, slot_code: slot, created_at: timeOut, ...metric(i++, i % 5 === 0 ? 2 : 1) });
  }
  // 1 lượt biển mờ phải chụp lại vẫn không đọc được (thống kê lý do từ chối).
  await insert(GateEvent, { gate: 'in', kind: 'scan', uid: 'DE000004', status: 'denied', plate: null, message: 'Khong doc duoc bien',
    created_at: hoursAgo(5), ocr_ms: 3600, total_ms: 4100, shots: 2, score: null });
  // Đang trong bãi: xe của khach01 ở ô riêng A-01 và một xe vé lượt được chỉ vào ô A-02.
  await insert(Session, { card_uid: 'DE000001', plate_in: '59X188888', time_in: hoursAgo(2), slot_code: 'A-01' });
  await insert(Session, { card_uid: 'DE000003', plate_in: '30A12345', time_in: hoursAgo(40 / 60), slot_code: 'A-02' });
  await insert(GateEvent, { gate: 'in', kind: 'scan', uid: 'DE000001', status: 'ok', plate: '59X188888', message: 'Moi vao o A-01',
    slot_code: 'A-01', vehicle_type: 'motorbike', created_at: hoursAgo(2), ...metric(i++) });
  await insert(GateEvent, { gate: 'in', kind: 'scan', uid: 'DE000003', status: 'ok', plate: '30A12345', message: 'Moi vao o A-02',
    slot_code: 'A-02', vehicle_type: 'motorbike', created_at: hoursAgo(40 / 60), ...metric(i++) });

  // Đơn gia hạn 3 tháng của khach02 đang chờ quản lý duyệt; 1 đơn cũ bị từ chối.
  await insert(TicketRequest, { user_id: id.khach02, card_uid: 'DE000002', plate: '51G22222', owner_name: 'Phạm Thu Hà', months: 3,
    vehicle_type: 'car', apartment: 'B2-03.01', note: 'Xe Mazda 3 trắng' });
  await insert(TicketRequest, { user_id: id.khach01, plate: '59X199999', owner_name: 'Lê Minh Khách', months: 1, status: 'rejected',
    apartment: 'A1-12.05',
    reply: 'Mỗi người chỉ đăng ký 1 xe vé tháng', handled_at: hoursAgo(72), created_at: hoursAgo(96) });

  // Bảng công gần đây của bảo vệ demo: đúng giờ, trễ, về sớm, quên chấm ra.
  const shifts = [[1, '06:00', '06:03', '14:01', 'finger'], [2, '06:00', '06:12', '14:00', 'pin'],
    [3, '14:00', '13:55', '21:40', 'finger'], [4, '06:00', '05:58', null, 'auto']];
  for (const [daysAgo, start, tin, tout, how] of shifts) {
    const end = start === '06:00' ? '14:00' : '22:00';
    await insert(Attendance, { guard_id: g.id, shift_name: start === '06:00' ? 'Ca sáng' : 'Ca chiều',
      shift_start: at(daysAgo, start), shift_end: at(daysAgo, end), time_in: at(daysAgo, tin),
      time_out: at(daysAgo, tout ?? end), method_in: 'finger', method_out: how, on_duty: false });
  }

  // Thông tin bãi cho bản đồ của khách (chỉ điền khi chưa có).
  await Settings.updateOne({ _id: 1, lat: null }, { lot_name: 'Bãi giữ xe HUTECH',
    address: '475A Điện Biên Phủ, P.25, Bình Thạnh, TP.HCM', lat: 10.80167, lng: 106.71442 });
  console.log(`Đã tạo dữ liệu demo. Mật khẩu chung: ${PASSWORD}. PIN bảo vệ ${GUARD}: 2468`);
}
await mongoose.disconnect();
