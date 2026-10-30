// Đặc tả OpenAPI 3 cho trang /docs (Swagger UI). Chỉ mô tả, không kiểm dữ liệu (kiểm ở từng router).
const json = (example) => ({ content: { 'application/json': { example } } });
const q = (name, description, example) => ({ name, in: 'query', required: false, description, example, schema: { type: 'string' } });
const p = (name, example) => ({ name, in: 'path', required: true, example, schema: { type: 'string' } });
const op = (tag, summary, { body, params, secure = true, image } = {}) => ({
  tags: [tag], summary,
  ...(secure ? {} : { security: [] }),
  ...(params ? { parameters: params } : {}),
  ...(body ? { requestBody: json(body) } : {}),
  ...(image ? { requestBody: { content: { 'image/jpeg': { schema: { type: 'string', format: 'binary' } } } } } : {}),
  responses: { 200: { description: 'OK' }, 400: { description: 'Dữ liệu không hợp lệ' }, 401: { description: 'Chưa đăng nhập' } },
});

const card = { uid: 'A1B2C3D4', kind: 'monthly', plate: '59X1-123.45', owner: 'Nguyễn An', active: true };
const shift = { name: 'Ca sáng', startTime: '06:00', endTime: '14:00' };

export const openapi = {
  openapi: '3.0.3',
  info: { title: 'Bãi giữ xe API', version: '1.0.0',
    description: 'REST API cho app Flutter quản lý bãi giữ xe. Đăng nhập: /auth/login → mã OTP gửi email → /auth/login/verify trả JWT; bấm Authorize và dán JWT.' },
  components: { securitySchemes: { bearer: { type: 'http', scheme: 'bearer', bearerFormat: 'JWT' } } },
  security: [{ bearer: [] }],
  paths: {
    '/auth/register': { post: op('Xác thực', 'Đăng ký, gửi OTP', { secure: false, body: { email: 'ban@gmail.com', username: 'baove1', fullName: 'Lê Văn B', password: 'matkhau1' } }) },
    '/auth/register/verify': { post: op('Xác thực', 'Xác minh OTP đăng ký → JWT', { secure: false, body: { email: 'ban@gmail.com', code: '123456' } }) },
    '/auth/login': { post: op('Xác thực', 'Mật khẩu đúng → gửi OTP', { secure: false, body: { username: 'baove1', password: 'matkhau1' } }) },
    '/auth/login/verify': { post: op('Xác thực', 'Xác minh OTP đăng nhập → JWT', { secure: false, body: { username: 'baove1', code: '123456' } }) },
    '/auth/google': { post: op('Xác thực', 'Đăng nhập Google (idToken) → JWT', { secure: false, body: { idToken: '...' } }) },
    '/me': { get: op('Xác thực', 'Tài khoản đang đăng nhập'), patch: op('Xác thực', 'Đổi họ tên / mật khẩu', { body: { fullName: 'Lê Văn B', currentPassword: 'matkhau1', newPassword: 'matkhau2' } }) },

    '/status': { get: op('Bãi xe', 'Sức chứa, xe đang gửi, chỗ trống', { secure: false }) },
    '/fees/quote': { post: op('Bãi xe', 'Tính phí theo bảng giá hiện tại', { secure: false, body: { timeIn: '2026-10-30T20:00:00+07:00', timeOut: '2026-10-31T07:00:00+07:00', kind: 'guest' } }) },
    '/sessions': { get: op('Bãi xe', 'Lượt gửi theo ngày / xe trong bãi, kèm doanh thu', { params: [q('date', 'Ngày YYYY-MM-DD (mặc định hôm nay)', '2026-10-30'), q('plate', 'Tìm biển (vào hoặc ra)', '59X1'), q('open', 'true = xe đang trong bãi', 'false')] }) },
    '/sessions/lookup': { get: op('Bãi xe', 'Tra cứu xe trong bãi theo biển (lệch 1 ký tự), kèm phí tạm tính', { params: [q('plate', 'Biển cần tra', '30A99998'), q('candidates', 'Phương án đọc khác của OCR, cách nhau dấu phẩy', '')] }) },
    '/reports/monthly.xlsx': { get: op('Bãi xe', 'Báo cáo tháng Excel: doanh thu, lượt gửi, bảng công', { params: [q('month', 'YYYY-MM', '2026-10')] }) },
    '/sessions/{id}/fee': { get: op('Bãi xe', 'Phí nếu cho ra bây giờ', { params: [p('id', 1)] }) },
    '/sessions/{id}/release': { post: op('Bãi xe', 'Mất thẻ: đóng lượt + mở cổng ra', { params: [p('id', 1)] }) },
    '/gate/open': { post: op('Bãi xe', 'Mở barrier cổng ra từ xa') },
    '/events': { get: op('Bãi xe', 'Nhật ký cổng gần nhất', { params: [q('limit', '1-200', '20')] }) },

    '/cards': { get: op('Thẻ', 'Danh sách thẻ', { params: [q('q', 'Tìm UID / biển / chủ xe', '')] }), post: op('Thẻ', 'Thêm thẻ', { body: card }) },
    '/cards/{uid}': { patch: op('Thẻ', 'Sửa / khoá thẻ', { params: [p('uid', 'A1B2C3D4')], body: { active: false } }), delete: op('Thẻ', 'Xoá thẻ (chưa có lịch sử)', { params: [p('uid', 'A1B2C3D4')] }) },
    '/scans/latest': { get: op('Thẻ', 'Thẻ vừa quẹt sau mốc since', { params: [q('since', 'Thời điểm ISO 8601', '2026-10-30T00:00:00Z')] }) },
    '/settings': { get: op('Thẻ', 'Cài đặt bãi'), put: op('Thẻ', 'Lưu cài đặt', { body: { capacity: 50, priceDay: 3000, priceNight: 5000, nightMark: '22:00' } }) },
    '/plates/recognize': { post: op('Biển số', 'Nhận diện biển từ ảnh JPEG', { image: true }) },
    '/plates/url': { get: op('Biển số', 'Link ảnh biển số có hạn 1 giờ', { params: [q('path', 'Đường dẫn ảnh', 'in/2026-10-30/1761800000000_A1B2C3D4.jpg')] }) },

    '/gate/scan': { post: op('Cổng (ĐT camera)', 'Quẹt thẻ: API kiểm tra thẻ / biển / chỗ trống, mở hoặc đóng lượt gửi, trả 2 dòng OLED', { body: { gate: 'in', uid: 'A1B2C3D4', plate: '59X112345', score: 0.95, candidates: ['59X112345'], img: 'in/2026-10-30/1761800000000_A1B2C3D4.jpg' } }) },
    '/gate/auth': { post: op('Cổng (ĐT camera)', 'Bảo vệ mở tay bằng PIN / vân tay (đóng lượt bị từ chối gần đây)', { body: { pin: '2468', enroll: false, denied: { uid: 'A1B2C3D4', plate: '59X112345' } } }) },
    '/gate/enrolled': { post: op('Cổng (ĐT camera)', 'ESP32 vừa lưu vân tay vào ô = ID bảo vệ', { body: { id: 1 } }) },
    '/gate/punch': { post: op('Cổng (ĐT camera)', 'Chấm công: vào ca gần nhất / ra ca', { body: { finger: 1 } }) },
    '/gate/emergency': { post: op('Cổng (ĐT camera)', 'Ghi bật / tắt chế độ khẩn cấp', { body: { on: true } }) },
    '/gate/commands': { get: op('Cổng (ĐT camera)', 'Lệnh mở cổng đang chờ (30 giây gần nhất)') },
    '/gate/commands/{id}/done': { post: op('Cổng (ĐT camera)', 'Đã mở cổng theo lệnh', { params: [p('id', 1)] }) },
    '/gate/images': { put: op('Cổng (ĐT camera)', 'Tải ảnh biển số lên (lưu trong MongoDB 90 ngày)', { image: true, params: [q('path', 'Đường dẫn ảnh', 'in/2026-10-30/1761800000000_A1B2C3D4.jpg')] }) },

    '/lot/map': { get: op('Sơ đồ bãi', 'Sơ đồ bãi: khu, ô, trạng thái (trống / cư dân / có xe), biển số, căn hộ') },
    '/lot/map/public': { get: op('Sơ đồ bãi', 'Sơ đồ bãi không kèm biển / chủ xe (cư dân, khách xem)') },
    '/vehicle-types': { get: op('Sơ đồ bãi', 'Loại xe + bảng giá'), post: op('Sơ đồ bãi', 'Thêm loại xe', { body: { code: 'ebike', name: 'Xe máy điện', priceDay: 4000, priceNight: 8000, priceMonth: 120000 } }) },
    '/vehicle-types/{id}': { put: op('Sơ đồ bãi', 'Sửa giá loại xe', { params: [p('id', 1)], body: { name: 'Xe máy', priceDay: 5000, priceNight: 10000, priceMonth: 150000 } }), delete: op('Sơ đồ bãi', 'Xoá loại xe chưa dùng', { params: [p('id', 4)] }) },
    '/zones': { post: op('Sơ đồ bãi', 'Thêm khu (tên 1 chữ cái, vẽ ô của khu trên mặt bằng bằng chữ đó)', { body: { name: 'A', vehicleType: 'motorbike' } }) },
    '/zones/{id}': { put: op('Sơ đồ bãi', 'Đổi loại xe của khu', { params: [p('id', 1)], body: { name: 'A', vehicleType: 'motorbike' } }), delete: op('Sơ đồ bãi', 'Xoá khu không còn ô', { params: [p('id', 1)] }) },
    '/lot/layout': { put: op('Sơ đồ bãi', "Lưu mặt bằng: '#' tường, '.' trống, '=' đường, 'I' lối vào, 'O' lối ra, chữ cái = ô của khu", { body: { layout: ['##I################O##', '#==AAAAAAAAAAAAAAAA==#', '#====================#', '#==BBBBBBBBBBBBBBBB==#', '#==BBBBBBBBBBBBBBBB==#', '#====================#', '#==CCCCCCCC.DDDDDDD==#', '######################'] } }) },
    '/lot/route': { get: op('Sơ đồ bãi', 'Đường từ lối vào tới ô + lời chỉ dẫn, đường từ ô ra lối ra', { params: [q('slot', 'Mã ô', 'A-08')] }) },
    '/slots/{code}': { patch: op('Sơ đồ bãi', 'Gán ô cho cư dân (thẻ tháng) / bỏ gán / tạm khoá', { params: [p('code', 'A-01')], body: { cardUid: 'A1B2C3D4', active: true } }) },
    '/stats/revenue': { get: op('Doanh thu', 'Doanh thu theo ngày / tháng: vé lượt + vé tháng, theo loại xe', { params: [q('group', 'day | month', 'day'), q('from', 'YYYY-MM-DD hoặc YYYY-MM', ''), q('to', 'YYYY-MM-DD hoặc YYYY-MM', '')] }) },
    '/stats/ocr': { get: op('Biển số', 'Tốc độ + độ chính xác nhận diện biển (trung bình, p95, đọc được lần đầu, khớp lúc ra)', { params: [q('days', 'Số ngày gần nhất', '30')] }) },
    '/gate/whitelist': { get: op('Cổng (ĐT camera)', 'Thẻ tháng còn hạn để ESP32 lưu sẵn (dùng khi mất mạng)') },
    '/gate/offline': { post: op('Cổng (ĐT camera)', 'Gửi bù lượt ra / vào ghi trên ESP32 lúc mất mạng', { body: { events: [{ t: 'in', uid: 'A1B2C3D4', ts: 1793340000, by: 'card' }] } }) },
    '/guards': { get: op('Bảo vệ', 'Danh sách bảo vệ'), post: op('Bảo vệ', 'Thêm bảo vệ', { body: { name: 'Nguyễn Văn Tuấn', pin: '1234' } }) },
    '/guards/{id}': { patch: op('Bảo vệ', 'Sửa tên / PIN / ID vân tay', { params: [p('id', 1)], body: { pin: '5678', fingerId: 1 } }), delete: op('Bảo vệ', 'Xoá bảo vệ', { params: [p('id', 1)] }) },
    '/shifts': { get: op('Bảo vệ', 'Ca trực'), post: op('Bảo vệ', 'Thêm ca', { body: shift }) },
    '/shifts/{id}': { put: op('Bảo vệ', 'Sửa ca', { params: [p('id', 1)], body: shift }), delete: op('Bảo vệ', 'Xoá ca', { params: [p('id', 1)] }) },
    '/attendance': { get: op('Bảo vệ', 'Bảng công tháng', { params: [q('month', 'YYYY-MM', '2026-10')] }) },
    '/me/attendance': { get: op('Bảo vệ', 'Bảng công của tôi', { params: [q('month', 'YYYY-MM', '2026-10')] }) },

    '/lot': { get: op('Khách hàng', 'Thông tin bãi: tên, địa chỉ, toạ độ, bảng giá, chỗ trống', { secure: false }) },
    '/me/cards': { get: op('Khách hàng', 'Thẻ của tôi: hạn vé, xe đang gửi, phí nếu ra bây giờ') },
    '/me/cards/{uid}/lost': { post: op('Khách hàng', 'Báo mất thẻ: khoá ngay, cổng chặn cả vào lẫn ra', { params: [p('uid', 'A1B2C3D4')] }) },
    '/me/cards/{uid}/qr': { get: op('Khách hàng', 'Mã QR vé xe (ký, hết hạn 10 phút, không lộ UID)', { params: [p('uid', 'A1B2C3D4')] }) },
    '/me/sessions': { get: op('Khách hàng', 'Lịch sử ra vào của xe tôi') },
    '/me/plates/url': { get: op('Khách hàng', 'Ảnh biển số lúc vào/ra của xe tôi', { params: [q('path', 'Đường dẫn ảnh', 'in/2026-10-30/1761800000000_A1B2C3D4.jpg')] }) },
    '/me/requests': { get: op('Khách hàng', 'Đơn vé tháng của tôi'), post: op('Khách hàng', 'Gửi đơn đăng ký / gia hạn vé tháng', { body: { plate: '59X1-123.45', ownerName: 'Nguyễn An', months: 1, note: 'Xe Vision trắng', cardUid: null } }) },
    '/me/requests/{id}': { patch: op('Khách hàng', 'Sửa đơn đang chờ', { params: [p('id', 1)], body: { plate: '59X112345', ownerName: 'Nguyễn An', months: 3 } }), delete: op('Khách hàng', 'Huỷ đơn đang chờ', { params: [p('id', 1)] }) },
    '/requests': { get: op('Bãi xe', 'Đơn vé tháng của khách', { params: [q('status', 'pending | approved | rejected', 'pending')] }) },
    '/requests/{id}/approve': { post: op('Bãi xe', 'Duyệt đơn: gia hạn hoặc gán thẻ RFID mới', { params: [p('id', 1)], body: { cardUid: 'A1B2C3D4', reply: 'Đã cấp thẻ, nhận tại quầy' } }) },
    '/requests/{id}/reject': { post: op('Bãi xe', 'Từ chối đơn (ghi lý do)', { params: [p('id', 1)], body: { reply: 'Bãi đã hết chỗ vé tháng' } }) },
    '/sessions/by-ticket': { get: op('Bãi xe', 'Quét QR vé của khách -> xe đang gửi', { params: [q('qr', 'Chuỗi mã QR', '')] }) },
    '/admin/users': { get: op('Quản trị', 'Tài khoản', { params: [q('q', 'Tìm', ''), q('role', 'admin | manager | guard | customer', '')] }),
      post: op('Quản trị', 'Tạo tài khoản đã kích hoạt', { body: { email: 'bv@gmail.com', username: 'baove2', fullName: 'Lê B', password: 'matkhau1', role: 'guard', guardId: null } }) },
    '/admin/users/{id}': { patch: op('Quản trị', 'Đổi vai trò / khoá / gắn bảo vệ', { params: [p('id', 2)], body: { role: 'manager', active: true, guardId: null } }), delete: op('Quản trị', 'Xoá tài khoản', { params: [p('id', 2)] }) },
  },
};
