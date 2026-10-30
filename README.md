# BaiGiuXe — Quản lý bãi giữ xe

ESP32 (2 đầu đọc RFID, barrier, OLED, bàn phím, vân tay) + 2 điện thoại làm camera chụp biển số + app Flutter quản lý. Mọi dữ liệu đi qua REST API (Node.js, deploy Render), CSDL MongoDB Atlas. Danh sách thư viện và công nghệ chi tiết: [công nghệ.md](công%20nghệ.md).

```
ESP32 (WiFi bãi xe) --MQTT bgx/evt--> EMQX Cloud --> ĐT camera của cổng đó (WiFi hoặc 4G)
ĐT camera: chụp -> REST API /plates/recognize (Plate Recognizer) -> REST API /gate/scan (API kiểm tra, ghi lượt gửi)
           -> MQTT bgx/cmd -> ESP32: còi / OLED / barrier
App quản lý / khách hàng --HTTPS--> REST API (Render) --> MongoDB Atlas
```

REST API: https://baigiuxe.onrender.com (danh sách API, số chỗ trống trực tiếp) · thử từng API: https://baigiuxe.onrender.com/docs

| Thư mục | Nội dung |
|---|---|
| `backend/` | REST API Node.js + Express + Mongoose (MongoDB Atlas), deploy Render (`render.yaml`). Xử lý mọi nghiệp vụ: đăng nhập OTP / Google, thẻ, lượt gửi, phí, cổng, bảo vệ, chấm công, vé tháng, báo cáo |
| `app/` | Flutter (Android / iOS / macOS). Một app: Quản lý, Khách hàng (vé tháng), Bảo vệ, và chế độ Thiết bị camera (cổng vào / ra / cả 2) |
| `firmware/` | PlatformIO cho ESP32 DevKit V1 (`src/main.cpp` firmware chính, `src/hwtest.cpp` thử phần cứng) |

## 1. MongoDB Atlas

1. Tạo cluster free (M0), **Database Access** tạo user, **Network Access** cho phép `0.0.0.0/0` (Render không có IP cố định).
2. **Connect → Drivers** lấy chuỗi `mongodb+srv://...`, thêm tên database sau dấu `/`, VD `...mongodb.net/baigiuxe`.
3. Không cần tạo bảng: lần chạy đầu API tự tạo index, dòng cài đặt và 3 ca trực mặc định.

## 2. Plate Recognizer

Đăng ký tại platerecognizer.com (gói free 2.500 lượt/tháng) và lấy API token.

## 2b. REST API (Render)

```bash
cd backend
npm test                 # 41 test, MongoDB trong bộ nhớ (mongodb-memory-server)
cp .env.example .env     # điền MONGODB_URI, JWT_SECRET, PLATE_TOKEN, GOOGLE_CLIENT_ID, BREVO_API_KEY, MAIL_FROM
npm run dev
npm run seed-demo        # tài khoản + thẻ + lượt gửi + bảng công mẫu để demo (xoá: npm run seed-demo -- --remove)
```

Deploy: Render → New → Blueprint → repo này (đọc `render.yaml`), nhập các biến bí mật. Tài khoản tự đăng ký qua app là
khách hàng; cấp quyền admin: `npm run make-admin -- <tên đăng nhập>`.

## 3. EMQX Cloud (MQTT)

ESP32 và 2 ĐT camera nói chuyện qua broker MQTT, nên ĐT dùng WiFi hay 4G đều được, không cần đứng gần ESP32.

1. Đăng ký EMQX Cloud, tạo deployment **Serverless** (miễn phí).
2. **Overview**: chép địa chỉ broker (dạng `xxxx.ala.eu-central-1.emqxsl.com`), cổng TLS là 8883.
3. **Access Control → Authentication**: tạo 2 tài khoản, một cho ESP32 (ví dụ `esp32`), một cho app (ví dụ `phone`).

Đổi sang broker khác (HiveMQ...) thì thêm root CA của broker đó vào `firmware/src/ca_roots.h`.

## 4. App Flutter

```bash
cd app
flutter test
# Sửa app/dart_defines.json: MQTT_HOST, MQTT_USER, MQTT_PASS (API_URL mặc định baigiuxe.onrender.com)
flutter build apk --release --dart-define-from-file=dart_defines.json
```

Màn đăng nhập (tên đăng nhập + mật khẩu → mã OTP gửi email, hoặc Google, hoặc đăng ký mới) có 2 chế độ:
- **Tài khoản**: quản lý / admin vào màn quản lý, khách hàng vào màn vé tháng, bảo vệ xem bảng công của mình.
- **Thiết bị camera**: đăng nhập tài khoản quản lý rồi chọn vai trò của máy:
- **Camera cổng vào / ra** (Android, iOS): gắn điện thoại nhìn thẳng biển số, cắm sạc. Màn hình luôn sáng. Màn camera ở lại liên tục để quét xe xếp hàng, hiện 4 xe gần nhất.
- **Quản lý** (mọi nền tảng, kể cả macOS).

Các mục ở thanh dưới:

| Mục | Dùng để |
|---|---|
| Tổng quan | Số chỗ trống, xe trong bãi, sự kiện gần đây, nút mở cổng ra, cho xe ra khi mất thẻ |
| Lịch sử | Lượt gửi theo ngày, tìm biển số, doanh thu |
| Thẻ | Thêm thẻ (mở màn thêm thẻ rồi quẹt ở đầu đọc bất kỳ, UID tự điền), sửa, khoá, xoá |
| Bảo vệ | Thêm bảo vệ (tên + PIN), xem ai có vân tay, ai đang trực, mở **Bảng công** theo tháng |
| Cài đặt | Giá, sức chứa, mốc tính qua đêm, **ca trực** (giờ bắt đầu/kết thúc), đổi vai trò, đăng xuất |
| Camera | Chỉ có trên ĐT camera: quay lại màn camera |

Tính phí: lượt không qua mốc đêm (mặc định 22:00) tính giá ngày; mỗi lần qua mốc đêm tính một giá đêm. Vé tháng miễn phí.

## 5. Firmware ESP32

```bash
cd firmware
# Sửa src/secrets.h: WiFi 2.4GHz của bãi + tài khoản MQTT của ESP32 (mẫu: src/secrets.h.example)
pio run -t upload && pio device monitor
```

- **Đối chiếu `src/pins.h` với dây thật trước khi nạp.** Servo barrier ở chân 13, còi thụ động ở chân 19.
- Cần hiệu chỉnh trên phần cứng thật: `SERVO_OPEN_DEG` / `SERVO_CLOSE_DEG`, `KEYMAP` (nếu phím bấm ra sai ký tự), `EMERGENCY_ACTIVE`, `BUZZER_HZ` (nếu còi nhỏ).
- Nạp hay bị đứt giữa chừng thì hạ tốc độ: `PLATFORMIO_UPLOAD_SPEED=115200 pio run -t upload`.
- `src/ca_roots.h` chứa root CA cho TLS: DigiCert Global Root G2 (EMQX Cloud) và ISRG Root X1/X2 (Let's Encrypt).
- Dòng trạng thái trên OLED (vùng vàng): `Mat WiFi` → kiểm tra WiFi bãi; `Mat may chu MQTT` → kiểm tra địa chỉ / tài khoản MQTT; `Cho DT ket noi` → chưa có ĐT camera nào mở app.

### Bảo vệ: vân tay, PIN, chấm công

1. Trong app vào **Bảo vệ → Thêm bảo vệ**, nhập tên và PIN (4-8 số).
2. Đăng ký vân tay ở ESP32: **B** → PIN của bảo vệ đó → **#** → đặt ngón tay, nhấc ra, đặt lại. Vân tay lưu vào AS608 ở ô số = ID bảo vệ, app tự gán vân tay cho bảo vệ.
3. Chấm công: **C** → đặt vân tay (hoặc nhập PIN → **#**). Lần đầu là vào ca, lần sau là ra ca. Bảng công tính trễ / về sớm theo ca trực khai báo trong Cài đặt.

Đăng ký vân tay, mở cổng bằng PIN và chấm công đều cần ĐT cổng ra đang mở app (ĐT chuyển lên API kiểm tra PIN và ghi CSDL). Mở cổng bằng vân tay đã đăng ký thì không cần mạng.

### Thao tác ở cổng
| Tình huống | ESP32 |
|---|---|
| Quẹt thẻ hợp lệ | 1 tiếng bíp, OLED hiện biển số; cổng ra thì barrier mở 5s |
| Bị từ chối (lệch biển, bãi đầy, thẻ lạ...) | 3 tiếng bíp, OLED hiện lý do |
| Bảo vệ mở tay | Đặt vân tay bất kỳ lúc nào, hoặc **A** → nhập PIN → **#**. Sai PIN 5 lần thì khoá 60s |
| Đăng ký vân tay | **B** → PIN bảo vệ → **#** → đặt ngón tay, nhấc ra, đặt lại. OLED báo `DA DANG KY` hoặc lý do lỗi |
| Chấm công vào/ra ca | **C** → đặt vân tay, hoặc nhập PIN → **#**. OLED báo `VAO CA` / `RA CA`, tên, giờ, số phút trễ/sớm |
| Khi đang nhập PIN | **C** = xoá 1 số, `*` = xoá hết, **D** = huỷ |
| Nút khẩn cấp | Bấm lần 1: mở và giữ barrier. Bấm lần 2: đóng. Không cần mạng |
| Mất thẻ | App → Tổng quan → chạm vào xe → *Cho xe ra + mở cổng* |

## Bảo mật

`app/dart_defines.json` và `firmware/src/secrets.h` **đang được đưa lên repo** (mật khẩu WiFi, mật khẩu MQTT). Nếu repo để công khai, hãy đổi các mật khẩu/token này định kỳ, hoặc đưa 2 file trở lại `.gitignore` và chỉ giữ file mẫu.

## Chưa làm (có chủ đích)
- Hàng đợi offline khi mất internet (vân tay đã đăng ký và nút khẩn cấp vẫn mở cổng được).
- Giữ ảnh biển số lâu hơn 90 ngày (ảnh lưu trong MongoDB, tự xoá sau 90 ngày để không đầy 512MB của Atlas free).
- Sửa / xoá tay một lượt chấm công trong bảng công.
