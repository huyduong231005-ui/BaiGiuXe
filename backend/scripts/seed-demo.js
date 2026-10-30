// Dữ liệu demo để thử / quay video: npm run seed-demo   (xoá: npm run seed-demo -- --remove)
// Email đều là email phụ Gmail huyduong455+...@gmail.com: mọi mã OTP về chung 1 hộp thư, không rơi vào Spam.
// Thẻ demo có UID DE0000xx, biển số giả: không đụng thẻ RFID thật của bãi.
import bcrypt from 'bcryptjs';
import pg from 'pg';

const PASSWORD = 'demo1234';
const GUARD = 'Nguyễn Văn Tuấn';
const USERS = [
  ['quanly', 'huyduong455+ql@gmail.com', 'Trần Quản Lý', 'manager'],
  ['baove', 'huyduong455+bv@gmail.com', GUARD, 'guard'],
  ['khach01', 'huyduong455+kh01@gmail.com', 'Lê Minh Khách', 'customer'],
  ['khach02', 'huyduong455+kh02@gmail.com', 'Phạm Thu Hà', 'customer'],
];
const DEMO_CARDS = "uid like 'DE0000%'";

const db = new pg.Client({ connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } });
await db.connect();
const q = (sql, params) => db.query(sql, params);

async function remove() {
  const usernames = USERS.map((u) => u[0]);
  await q(`delete from gate_events where uid like 'DE0000%'`);
  await q(`delete from sessions where card_uid like 'DE0000%'`);
  await q(`delete from ticket_requests where user_id in (select id from app_users where username = any($1))`, [usernames]);
  await q(`delete from cards where ${DEMO_CARDS}`);
  await q(`delete from app_users where username = any($1)`, [usernames]);
  await q(`delete from attendance where guard_id in (select id from guards where name = $1)`, [GUARD]);
  await q(`delete from guards where name = $1 and not exists (select 1 from sessions where override_by = guards.id)`, [GUARD]);
}

await q('begin');
try {
  await remove();
  if (process.argv.includes('--remove')) {
    await q('commit');
    console.log('Đã xoá dữ liệu demo');
    process.exit(0);
  }
  const hash = await bcrypt.hash(PASSWORD, 10);
  const { rows: [g] } = await q(
    `insert into guards (name, pin_hash) values ($1, extensions.crypt('2468', extensions.gen_salt('bf'))) returning id`, [GUARD]);
  const id = {};
  for (const [username, email, name, role] of USERS) {
    const { rows: [u] } = await q(
      `insert into app_users (username, email, full_name, password_hash, role, guard_id, active)
       values ($1, $2, $3, $4, $5, $6, true) returning id`, [username, email, name, hash, role, role === 'guard' ? g.id : null]);
    id[username] = u.id;
  }

  // Thẻ: khach01 vé tháng còn hạn (xe đang trong bãi), khach02 vé tháng hết hạn (đang chờ gia hạn), 2 vé lượt.
  await q(`insert into cards (uid, kind, plate, owner, user_id, valid_until) values
    ('DE000001', 'monthly', '59X188888', 'Lê Minh Khách', $1, current_date + 25),
    ('DE000002', 'monthly', '51G22222', 'Phạm Thu Hà', $2, current_date - 3),
    ('DE000003', 'guest', null, null, null, null),
    ('DE000004', 'guest', null, null, null, null)`, [id.khach01, id.khach02]);

  // Lượt gửi 7 ngày qua: vé tháng miễn phí, vé lượt có phí ngày / đêm (biểu đồ doanh thu có số).
  const closed = [
    ['DE000001', '59X188888', 6, 8, 17, 0], ['DE000001', '59X188888', 4, 8, 18, 0], ['DE000001', '59X188888', 2, 7, 17, 0],
    ['DE000002', '51G22222', 5, 9, 16, 0],
    ['DE000003', '30A12345', 6, 9, 11, 3000], ['DE000004', '29B67890', 5, 13, 15, 3000], ['DE000003', '61C24680', 4, 20, 31, 5000],
    ['DE000004', '43D13579', 3, 10, 12, 3000], ['DE000003', '30A12345', 2, 14, 16, 3000], ['DE000004', '29B67890', 1, 19, 32, 5000],
    ['DE000003', '61C24680', 1, 8, 9, 3000], ['DE000004', '43D13579', 0, 7, 9, 3000],
  ];
  for (const [card, plate, daysAgo, inH, outH, fee] of closed) {
    await q(`insert into sessions (card_uid, plate_in, plate_out, time_in, time_out, fee) values
      ($1, $2, $2, date_trunc('day', now() at time zone 'Asia/Ho_Chi_Minh') at time zone 'Asia/Ho_Chi_Minh'
           - make_interval(days => $3) + make_interval(hours => $4),
       date_trunc('day', now() at time zone 'Asia/Ho_Chi_Minh') at time zone 'Asia/Ho_Chi_Minh'
           - make_interval(days => $3) + make_interval(hours => $5), $6)`, [card, plate, daysAgo, inH, outH, fee]);
  }
  // Đang trong bãi: xe của khach01 và một xe vé lượt.
  await q(`insert into sessions (card_uid, plate_in, time_in) values
    ('DE000001', '59X188888', now() - interval '2 hours'), ('DE000003', '30A12345', now() - interval '40 minutes')`);
  await q(`insert into gate_events (gate, kind, uid, status, plate, message, open, created_at) values
    ('in', 'scan', 'DE000001', 'ok', '59X188888', 'Moi vao', false, now() - interval '2 hours'),
    ('in', 'scan', 'DE000003', 'ok', '30A12345', 'Moi vao', false, now() - interval '40 minutes')`);

  // Đơn gia hạn 3 tháng của khach02 đang chờ quản lý duyệt; 1 đơn cũ bị từ chối.
  await q(`insert into ticket_requests (user_id, card_uid, plate, owner_name, months, note) values
    ($1, 'DE000002', '51G22222', 'Phạm Thu Hà', 3, 'Xe Vision trắng, gửi giờ hành chính')`, [id.khach02]);
  await q(`insert into ticket_requests (user_id, plate, owner_name, months, status, reply, handled_at, created_at) values
    ($1, '59X199999', 'Lê Minh Khách', 1, 'rejected', 'Mỗi người chỉ đăng ký 1 xe vé tháng', now() - interval '3 days',
     now() - interval '4 days')`, [id.khach01]);

  // Bảng công tháng này của bảo vệ demo: đúng giờ, trễ, về sớm, quên chấm ra.
  const shifts = [[1, '06:00', '06:03', '14:01', 'finger'], [2, '06:00', '06:12', '14:00', 'pin'],
    [3, '14:00', '13:55', '21:40', 'finger'], [4, '06:00', '05:58', null, 'auto']];
  for (const [daysAgo, start, tin, tout, how] of shifts) {
    const day = `(date_trunc('day', now() at time zone 'Asia/Ho_Chi_Minh') - make_interval(days => ${daysAgo}))`;
    const at = (hm) => `(${day} + time '${hm}') at time zone 'Asia/Ho_Chi_Minh'`;
    const end = start === '06:00' ? '14:00' : '22:00';
    await q(`insert into attendance (guard_id, shift_name, shift_start, shift_end, time_in, time_out, method_in, method_out)
      values ($1, $2, ${at(start)}, ${at(end)}, ${at(tin)}, ${tout ? at(tout) : at(end)}, 'finger', $3)`,
    [g.id, start === '06:00' ? 'Ca sáng' : 'Ca chiều', how]);
  }

  // Thông tin bãi cho bản đồ của khách (chỉ điền khi chưa có).
  await q(`update settings set lot_name = 'Bãi giữ xe HUTECH', address = '475A Điện Biên Phủ, P.25, Bình Thạnh, TP.HCM',
    lat = 10.80167, lng = 106.71442 where lat is null`);
  await q('commit');
  console.log(`Đã tạo dữ liệu demo. Mật khẩu chung: ${PASSWORD}. PIN bảo vệ ${GUARD}: 2468`);
} catch (err) {
  await q('rollback');
  throw err;
} finally {
  await db.end();
}
