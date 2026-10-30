// ESP32 bãi giữ xe: 2 đầu đọc RFID, barrier cổng ra, OLED, phím, vân tay bảo vệ.
// Giao tiếp với điện thoại camera qua MQTT (EMQX Cloud, TLS): ESP32 dùng WiFi bãi xe, ĐT dùng WiFi hay 4G đều được.
//   ESP32 -> bgx/evt:  {"t":"scan","g":"in","uid":"..","id":5} · {"t":"auth","g":"out","pin":"1234"|"finger":3}
//                      · {"t":"emg","g":"out","on":true} · {"t":"enrolled","g":"out","id":3}
//                      (auth có thêm "for":"enroll" khi PIN dùng để đăng ký vân tay, phím B)
//                      · {"t":"att","g":"out","finger":3|"pin":"1234"} (chấm công, phím C)
//   ĐT -> bgx/cmd:     {"t":"res","id":5,"ok":true,"open":true,"l1":"..","l2":".."} · {"t":"open"}
//                      · {"t":"st","free":37,"cap":50} · {"t":"time","ts":<giây local>} · {"t":"auth","ok":true,"gid":2}
//                      · {"t":"attres","ok":true,"l1":"VAO CA","l2":"Tuan 06:05 tre 5p"}
//                      · {"t":"wl","i":0,"n":25,"c":"UID:YYYYMMDD;UID:0"} danh sách thẻ tháng (chia nhiều bản tin)
//                      · {"t":"offack","n":4} API đã nhận 4 lượt offline đầu hàng chờ
//   ESP32 -> bgx/evt:  {"t":"off","g":"out","ev":[{"t":"in","uid":"..","ts":..,"by":"card"},..]} gửi bù lượt offline
//   Online/offline (retained + LWT, "1"/"0"): bgx/esp (ESP32), bgx/phone/in|out|both (từng ĐT).
// Điện thoại gọi REST API. Mất ĐT / mất mạng: thẻ tháng có trong danh sách đã lưu (flash) vẫn qua được, mọi lượt
// ghi vào flash kèm giờ DS3231 rồi gửi bù khi có ĐT lại. Nút khẩn cấp và vân tay mở cổng cục bộ, không cần mạng.
#include <Arduino.h>
#include <ArduinoJson.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>
#include <SPI.h>
#include <Wire.h>
#include <MFRC522v2.h>
#include <MFRC522DriverSPI.h>
#include <MFRC522DriverPinSimple.h>
#include <I2CKeyPad.h>
#include <Adafruit_SSD1306.h>
#include <Fonts/FreeSansBold12pt7b.h>
#include <Fonts/FreeSansBold9pt7b.h>
#include <Fonts/FreeSans9pt7b.h>
#include <RTClib.h>
#include <Adafruit_Fingerprint.h>
#include <ESP32Servo.h>
#include <LittleFS.h>
#include <vector>
#include "pins.h"
#include "secrets.h"
#include "ca_roots.h"

// Phải trùng với app/lib/esp_link.dart
#define T_EVT "bgx/evt"
#define T_CMD "bgx/cmd"
#define T_ESP "bgx/esp"
#define T_PHONE "bgx/phone/"

// ---- Hiệu chỉnh theo phần cứng thật ----
const int SERVO_OPEN_DEG = 90;
const int SERVO_CLOSE_DEG = 0;
const uint32_t BARRIER_HOLD_MS = 5000;
const uint32_t RESULT_TIMEOUT_MS = 12000;  // ĐT chụp + OCR + DB thường ~3-5s
const uint32_t PIN_REPLY_TIMEOUT_MS = 8000;
const uint32_t SAME_CARD_DEBOUNCE_MS = 3000;
const uint32_t RFID_CHECK_MS = 2000;  // kiểm tra RC522 còn đúng cấu hình (bị reset do sụt áp thì khởi tạo lại)
const uint32_t MSG_SHOW_MS = 5000;
const uint32_t AUTH_WINDOW_MS = 20000;
const int PIN_MAX_TRIES = 5;
const uint32_t PIN_LOCK_MS = 60000;
const size_t CMD_MAX = 512;  // bản tin danh sách thẻ tháng ~350 byte
const size_t OFF_MAX = 1000;   // tối đa số lượt offline lưu trong flash (~60KB)
const int OFF_BATCH = 4;       // số lượt gửi bù mỗi bản tin
const uint32_t OFF_RETRY_MS = 15000;

// ---- Thiết bị ----
SPIClass hspi(HSPI);
MFRC522DriverPinSimple ssIn(RFID_IN_SS), ssOut(RFID_OUT_SS);
MFRC522DriverSPI drvIn{ssIn, SPI}, drvOut{ssOut, hspi};
MFRC522 rfidIn{drvIn}, rfidOut{drvOut};
I2CKeyPad keypad(PCF8574_ADDR);
Adafruit_SSD1306 oled(128, 64, &Wire, -1);
RTC_DS3231 rtc;
Adafruit_Fingerprint finger(&Serial2);
Servo barrier;
WiFiClientSecure net;
PubSubClient mqtt(net);

// ---- Trạng thái ----
struct Gate {
  Gate(const char *n, MFRC522 &r) : name(n), rfid(r) {}
  const char *name;
  MFRC522 &rfid;
  long pendingId = 0;
  uint32_t pendingAt = 0, lastUidAt = 0;
  String pendingUid;  // thẻ đang chờ ĐT trả kết quả (ĐT không trả lời thì xét offline)
  unsigned long resets = 0;  // số lần RC522 bị reset (sụt áp) phải khởi tạo lại
  String lastUid;
};
Gate gIn{"in", rfidIn};
Gate gOut{"out", rfidOut};

long nextId = 1;
int freeSlots = -1, capacity = -1;
String msg1 = "Moi quet the", msg2;
uint32_t msgUntil = 0, barrierCloseAt = 0, lastDraw = 0, lastFp = 0;
bool emergency = false, emergencyLast = false, fpOk = false;
uint32_t emergencyChangedAt = 0;
bool authMode = false;
char authFor = 'o';  // phím vừa bấm quyết định PIN/vân tay dùng để: 'o' mở cổng (A), 'e' đăng ký vân tay (B), 'c' chấm công (C)
int enrollId = 0;  // >0: chờ loop() chạy đăng ký vân tay vào ô này (không chạy trong callback MQTT)
uint32_t authUntil = 0, pinLockUntil = 0, pinSentAt = 0;
String pinBuf;
int pinFails = 0;
char lastKey = 'N';
bool phoneIn = false, phoneOut = false, phoneBoth = false;  // theo bgx/phone/<cổng>
uint32_t lastMqttTry = 0;

// ---- Dự phòng mất mạng ----
struct WlCard {
  String uid;
  uint32_t until;  // YYYYMMDD, 0 = không hạn
};
std::vector<WlCard> wl, wlNew;  // danh sách thẻ tháng đang dùng / đang nhận dở từ ĐT
size_t offCount = 0;            // số lượt offline đang chờ gửi (số dòng /off.log)
uint32_t offSentAt = 0;         // đã gửi 1 lô, chờ offack
const char *WL_FILE = "/wl.txt";
const char *OFF_FILE = "/off.log";

// ---------- MQTT ----------

void handleCmd(const char *s);

/// Có ĐT nào đang xử lý cổng g ("in"/"out") không. nullptr = bất kỳ cổng nào.
bool phoneConnected(const char *g = nullptr) {
  if (!mqtt.connected()) return false;
  if (!g) return phoneIn || phoneOut || phoneBoth;
  return phoneBoth || (strcmp(g, "in") ? phoneOut : phoneIn);
}

void notify(JsonDocument &doc) {
  String s;
  serializeJson(doc, s);
  mqtt.publish(T_EVT, s.c_str());
}

void onMqtt(char *topic, byte *payload, unsigned int len) {
  char buf[CMD_MAX];
  len = min(len, (unsigned)CMD_MAX - 1);
  memcpy(buf, payload, len);
  buf[len] = 0;
  if (!strcmp(topic, T_CMD)) return handleCmd(buf);
  bool on = buf[0] == '1';
  if (!strcmp(topic, T_PHONE "in")) phoneIn = on;
  else if (!strcmp(topic, T_PHONE "out")) phoneOut = on;
  else if (!strcmp(topic, T_PHONE "both")) phoneBoth = on;
}

void initMqtt() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);  // tắt modem sleep: bớt ~100ms trễ mỗi bản tin
  WiFi.begin(WIFI_SSID, WIFI_PASS);  // tự kết nối lại khi rớt WiFi
  net.setCACert(CA_ROOTS);
  net.setHandshakeTimeout(5);
  mqtt.setServer(MQTT_HOST, 8883);
  mqtt.setCallback(onMqtt);
  mqtt.setBufferSize(CMD_MAX + 64);  // mặc định 256 byte, chưa đủ cho bản tin res dài + topic
  mqtt.setSocketTimeout(5);
}

void mqttLoop() {
  if (mqtt.connected()) {
    mqtt.loop();
    return;
  }
  phoneIn = phoneOut = phoneBoth = false;
  if (millis() - lastMqttTry < 5000) return;
  lastMqttTry = millis();
  if (WiFi.status() != WL_CONNECTED) {
    Serial.printf("[wifi] chua ket noi, status %d\n", WiFi.status());  // 1 = không thấy tên WiFi, 4 = sai mật khẩu
    return;
  }
  // shortcut: bắt tay TLS chặn loop ~1-2s mỗi lần thử (tối đa 5s); tách sang task riêng nếu cần phím/còi phản hồi khi mất mạng.
  if (!mqtt.connect("bgx-esp32", MQTT_USER, MQTT_PASS, T_ESP, 1, true, "0")) {
    Serial.printf("[mqtt] ket noi loi %d\n", mqtt.state());
    return;
  }
  mqtt.publish(T_ESP, "1", true);
  mqtt.subscribe(T_CMD, 1);
  mqtt.subscribe(T_PHONE "+", 1);  // nhận lại trạng thái ĐT (retained) ngay khi kết nối
  Serial.println("[mqtt] da ket noi");
}

// ---------- Dự phòng mất mạng: danh sách thẻ tháng + nhật ký offline trong flash ----------

void loadWhitelist() {
  wl.clear();
  // Mở kiểu append để tạo file rỗng nếu chưa có (exists() của LittleFS bản này vẫn in lỗi khi thiếu file).
  LittleFS.open(WL_FILE, FILE_APPEND).close();
  LittleFS.open(OFF_FILE, FILE_APPEND).close();
  File f = LittleFS.open(WL_FILE, "r");
  while (f && f.available()) {
    String line = f.readStringUntil('\n');
    int c = line.indexOf(':');
    if (c > 0) wl.push_back({line.substring(0, c), (uint32_t)line.substring(c + 1).toInt()});
  }
  if (f) f.close();
  File o = LittleFS.open(OFF_FILE, "r");
  offCount = 0;
  while (o && o.available()) offCount += o.readStringUntil('\n').length() > 0;
  if (o) o.close();
  Serial.printf("[offline] %u the thang, %u luot cho gui bu\n", (unsigned)wl.size(), (unsigned)offCount);
}

/// Nhận 1 phần danh sách thẻ tháng; đủ n thẻ thì thay danh sách cũ và lưu flash.
void onWhitelist(JsonDocument &d) {
  size_t i = d["i"] | 0, n = d["n"] | 0;
  if (i == 0) wlNew.clear();
  if (i != wlNew.size()) return;  // lệch thứ tự (mất 1 bản tin): chờ ĐT gửi lại lần sau
  String c = d["c"] | "";
  for (int start = 0; start < (int)c.length();) {
    int end = c.indexOf(';', start);
    if (end < 0) end = c.length();
    String item = c.substring(start, end);
    int colon = item.indexOf(':');
    if (colon > 0) wlNew.push_back({item.substring(0, colon), (uint32_t)item.substring(colon + 1).toInt()});
    start = end + 1;
  }
  if (wlNew.size() < n) return;
  wl = wlNew;
  File f = LittleFS.open(WL_FILE, "w");
  for (auto &x : wl) f.printf("%s:%u\n", x.uid.c_str(), (unsigned)x.until);
  f.close();
  Serial.printf("[offline] da luu %u the thang\n", (unsigned)wl.size());
}

bool wlAllows(const String &uid) {
  DateTime t = rtc.now();
  uint32_t today = t.year() * 10000UL + t.month() * 100UL + t.day();
  for (auto &x : wl)
    if (x.uid == uid) return x.until == 0 || x.until >= today;
  return false;
}

/// Ghi 1 lượt lúc mất ĐT / mất mạng. ts = giờ DS3231 (giờ địa phương), API đổi về giờ thật.
void logOffline(const char *t, const String &uid, const char *by, int guard = 0) {
  if (offCount >= OFF_MAX) {  // ponytail: giữ lượt cũ, bỏ lượt mới khi đầy; cần ĐT gửi bù để có chỗ
    Serial.println("[offline] nhat ky day, bo luot moi");
    return;
  }
  JsonDocument e;
  e["t"] = t;
  if (uid.length()) e["uid"] = uid;
  e["ts"] = rtc.now().unixtime();
  e["by"] = by;
  if (guard) e["guard"] = guard;
  File f = LittleFS.open(OFF_FILE, FILE_APPEND);
  serializeJson(e, f);
  f.print('\n');
  f.close();
  offCount++;
}

/// Có ĐT cổng ra thì gửi bù từng lô OFF_BATCH lượt; chờ offack rồi mới gửi lô sau (mất ack thì gửi lại, API tự bỏ trùng).
void flushOffline() {
  if (!offCount || !phoneConnected("out") || (offSentAt && millis() - offSentAt < OFF_RETRY_MS)) return;
  JsonDocument d;
  d["t"] = "off";
  d["g"] = "out";
  JsonArray ev = d["ev"].to<JsonArray>();
  File f = LittleFS.open(OFF_FILE, "r");
  for (int i = 0; i < OFF_BATCH && f && f.available();) {
    String line = f.readStringUntil('\n');
    if (!line.length()) continue;
    JsonDocument e;
    if (!deserializeJson(e, line)) ev.add(e);
    i++;
  }
  if (f) f.close();
  if (ev.size()) notify(d);
  offSentAt = millis();
}

/// API đã nhận n lượt đầu hàng chờ: xoá khỏi flash.
void onOfflineAck(size_t n) {
  File f = LittleFS.open(OFF_FILE, "r");
  String rest;
  size_t skipped = 0;
  while (f && f.available()) {
    String line = f.readStringUntil('\n');
    if (!line.length()) continue;
    if (skipped < n) skipped++;
    else rest += line + '\n';
  }
  if (f) f.close();
  File w = LittleFS.open(OFF_FILE, "w");
  w.print(rest);
  w.close();
  offCount = offCount > skipped ? offCount - skipped : 0;
  offSentAt = 0;
  Serial.printf("[offline] da gui bu %u luot, con %u\n", (unsigned)skipped, (unsigned)offCount);
}

// ---------- Hiển thị / còi ----------

void showMsg(const String &a, const String &b = "") {
  msg1 = a;
  msg2 = b;
  msgUntil = millis() + MSG_SHOW_MS;
}

// Kênh LEDC 15 (timer 3) để không đụng kênh/timer 0 mà ESP32Servo cấp cho barrier.
const int BUZZER_CH = 15;

void buzz(bool on) {
#if BUZZER_PASSIVE
  ledcWrite(BUZZER_CH, on ? 128 : 0);  // xung vuông 50%
#else
  digitalWrite(BUZZER_PIN, on);
#endif
}

void beep(int times, int ms = 100) {
  // ponytail: còi chặn loop tối đa ~600ms; chuyển sang non-blocking nếu cần phản hồi nhanh hơn.
  for (int i = 0; i < times; i++) {
    buzz(true);
    delay(ms);
    buzz(false);
    if (i < times - 1) delay(ms);
  }
}

/// In chữ căn giữa, đường chân chữ ở y, bằng font to nhất trong danh sách còn vừa 128px.
/// nullptr = font mặc định 5x7 (toạ độ y của nó là đỉnh chữ, nên lùi lên 7px cho cùng chân chữ).
void printFit(const String &s, int16_t y, std::initializer_list<const GFXfont *> fonts) {
  int16_t x1, y1;
  uint16_t w = 0, h;
  const GFXfont *font = nullptr;
  for (const GFXfont *f : fonts) {
    font = f;
    oled.setFont(f);
    oled.getTextBounds(s, 0, y, &x1, &y1, &w, &h);
    if (w <= 128) break;
  }
  oled.setCursor(w <= 128 ? (128 - w) / 2 - x1 : 0, font ? y : y - 7);
  oled.print(s);
  oled.setFont();
}

void draw() {
  DateTime t = rtc.now();
  char buf[24];
  oled.clearDisplay();
  oled.setTextWrap(false);  // chữ dài bị cắt ở mép phải thay vì tràn xuống dòng dưới
  oled.setTextColor(SSD1306_WHITE);
  oled.setTextSize(1);
  oled.setCursor(0, 0);
  snprintf(buf, sizeof buf, "%02d:%02d %02d/%02d/%04d", t.hour(), t.minute(), t.day(), t.month(), t.year());
  oled.print(buf);
  oled.print(phoneConnected() ? "" : " !");  // "!" = chưa có điện thoại nào kết nối
  oled.setCursor(0, 8);  // OLED 2 màu: hàng 0-15 vàng, 16-63 xanh -> dòng 8-15 nằm trọn vùng vàng
  if (emergency) oled.print("!! KHAN CAP - MO !!");
  else if (WiFi.status() != WL_CONNECTED) oled.print("Mat WiFi");
  else if (!mqtt.connected()) oled.print("Mat may chu MQTT");
  else if (!phoneConnected()) oled.print(wl.size() ? "Mat DT: the thang OK" : "Cho DT ket noi");
  else if (offCount) oled.printf("Gui bu: %u luot", (unsigned)offCount);
  else if (freeSlots >= 0) oled.printf("Con trong: %d/%d", freeSlots, capacity);
  bool showing = millis() < msgUntil || authMode;
  // Vùng xanh (hàng 16-63): dòng chính chữ đậm to, dòng phụ bên dưới.
  printFit(showing ? msg1 : String("Moi quet the"), 42, {&FreeSansBold12pt7b, &FreeSansBold9pt7b, nullptr});
  if (showing && msg2.length()) printFit(msg2, 61, {&FreeSans9pt7b, nullptr});
  oled.display();
}

void openBarrier() {
  barrier.write(SERVO_OPEN_DEG);
  barrierCloseAt = millis() + BARRIER_HOLD_MS;
}

// ---------- Quẹt thẻ ----------

void finishScan(Gate &g, bool ok, const String &l1, const String &l2, bool open) {
  showMsg(l1.length() ? l1 : (ok ? "OK" : "TU CHOI"), l2);
  g.pendingId = 0;
  if (open && &g == &gOut) openBarrier();
  beep(ok ? 1 : 3);
}

/// Không có ĐT / ĐT không trả lời: cư dân (thẻ tháng trong danh sách đã lưu) vẫn qua, ghi nhật ký để gửi bù.
void offlineScan(Gate &g, const String &uid) {
  if (!wlAllows(uid)) return finishScan(g, false, "TU CHOI", "Mat mang - goi BV", false);
  logOffline(g.name, uid, "card");
  finishScan(g, true, "CU DAN", "Offline - moi qua", true);
}

void readCard(Gate &g) {
  if (g.pendingId || !g.rfid.PICC_IsNewCardPresent() || !g.rfid.PICC_ReadCardSerial()) return;
  String uid;
  for (byte i = 0; i < g.rfid.uid.size; i++) {
    char hex[3];
    snprintf(hex, sizeof hex, "%02X", g.rfid.uid.uidByte[i]);
    uid += hex;
  }
  g.rfid.PICC_HaltA();
  Serial.printf("[rfid] cong %s doc the %s\n", g.name, uid.c_str());
  if (uid == g.lastUid && millis() - g.lastUidAt < SAME_CARD_DEBOUNCE_MS) return;
  g.lastUid = uid;
  g.lastUidAt = millis();
  if (!phoneConnected(g.name)) {
    Serial.printf("[rfid] khong co DT phu trach cong %s -> che do offline\n", g.name);
    return offlineScan(g, uid);
  }

  g.pendingId = nextId++;
  g.pendingUid = uid;
  g.pendingAt = millis();
  showMsg("Dang xu ly", uid);
  JsonDocument ev;
  ev["t"] = "scan";
  ev["g"] = g.name;
  ev["uid"] = uid;
  ev["id"] = g.pendingId;
  notify(ev);
}

// RC522 bị sụt áp (WiFi phát sóng, servo kéo dòng) tự reset: vẫn trả lời SPI nhưng cấu hình về mặc định,
// ĂNG-TEN TẮT -> không bao giờ đọc được thẻ nữa. Kiểm tra các thanh ghi PCD_Init đã đặt, lệch thì khởi tạo lại.
// (Bài học từ project KhoaBaoMat, commit b371f3e.)
bool rfidConfigured(MFRC522Driver &d) {
  using R = MFRC522Constants::PCD_Register;
  return (d.PCD_ReadRegister(R::TxControlReg) & 0x03) == 0x03 &&  // ăng-ten đang bật
         d.PCD_ReadRegister(R::TModeReg) == 0x80 &&               // bộ định thời tự chạy
         d.PCD_ReadRegister(R::TxASKReg) == 0x40;                 // điều chế 100% ASK
}

void healRfid(Gate &g, MFRC522Driver &d) {
  if (rfidConfigured(d)) return;
  using R = MFRC522Constants::PCD_Register;
  Serial.printf("[rfid] dau doc %s bi reset (sut ap?) TxControl 0x%02X TMode 0x%02X - khoi tao lai (lan %lu)\n",
                g.name, d.PCD_ReadRegister(R::TxControlReg), d.PCD_ReadRegister(R::TModeReg), ++g.resets);
  g.rfid.PCD_Init();
}

void checkRfidHealth() {
  static uint32_t last = 0;
  if (millis() - last < RFID_CHECK_MS) return;
  last = millis();
  healRfid(gIn, drvIn);
  healRfid(gOut, drvOut);
}

void checkTimeouts() {
  for (Gate *g : {&gIn, &gOut})
    if (g->pendingId && millis() - g->pendingAt > RESULT_TIMEOUT_MS) offlineScan(*g, g->pendingUid);
  if (pinSentAt && millis() - pinSentAt > PIN_REPLY_TIMEOUT_MS) {
    pinSentAt = 0;
    showMsg("DT k phan hoi", "Dung van tay");
  }
}

// ---------- Bảo vệ mở cổng thủ công ----------

void grantLocal(const String &how) {
  openBarrier();
  showMsg("DA MO", how);
  beep(1);
  authMode = false;
  pinBuf = "";
}

void checkFinger() {
  // AS608 có lúc không trả lời lúc khởi động (chưa sẵn sàng / sụt áp khi WiFi phát): thử lại mỗi 5s
  // thay vì tắt vân tay tới lần reset sau.
  if (!fpOk) {
    if (millis() - lastFp < 5000) return;
    lastFp = millis();
    if ((fpOk = finger.verifyPassword())) Serial.println("[boot] AS608 da tra loi");
    return;
  }
  if (authMode && authFor == 'e') return;  // đang nhập PIN để đăng ký: đặt tay không được mở cổng
  if (millis() - lastFp < 200) return;
  lastFp = millis();
  if (finger.getImage() != FINGERPRINT_OK) return;
  if (finger.image2Tz() != FINGERPRINT_OK || finger.fingerFastSearch() != FINGERPRINT_OK) {
    showMsg("Van tay sai");
    beep(3);
    return;
  }
  if (authMode && authFor == 'c') {  // chấm công: không mở cổng, ĐT ghi vào/ra ca rồi trả attres
    if (!phoneConnected("out")) return showMsg("Mat ket noi DT", "Chua cham duoc");
    JsonDocument ev;
    ev["t"] = "att";
    ev["g"] = "out";
    ev["finger"] = finger.fingerID;
    notify(ev);
    pinSentAt = millis();  // dùng chung bộ đếm chờ ĐT trả lời với PIN
    return showMsg("Dang cham cong", "Van tay #" + String(finger.fingerID));
  }
  // Vân tay đã khớp mẫu trong AS608 -> mở ngay; ĐT chỉ ghi log + đóng lượt bị từ chối gần nhất.
  grantLocal("Van tay #" + String(finger.fingerID));
  if (!phoneConnected("out")) return logOffline("out", "", "finger", finger.fingerID);
  JsonDocument ev;
  ev["t"] = "auth";
  ev["g"] = "out";
  ev["finger"] = finger.fingerID;
  notify(ev);
}

void submitPin() {
  if (millis() < pinLockUntil) return showMsg("Tam khoa", "Thu lai sau 60s");
  if (!phoneConnected("out")) return showMsg("Mat ket noi DT", authFor == 'o' ? "Dung van tay" : "Can DT de kiem PIN");
  if (authFor == 'e' && !fpOk) return showMsg("Loi cam bien", "Van tay khong tra loi");
  JsonDocument ev;
  ev["t"] = authFor == 'c' ? "att" : "auth";
  ev["g"] = "out";
  ev["pin"] = pinBuf;  // đi qua TLS tới broker
  if (authFor == 'e') ev["for"] = "enroll";
  notify(ev);
  pinSentAt = millis();
  showMsg("Dang kiem tra", "PIN...");
}

void onPinResult(bool ok, int guardId) {
  pinSentAt = 0;
  if (ok) {
    pinFails = 0;
    if (authFor != 'e') return grantLocal("PIN bao ve");
    authMode = false;
    pinBuf = "";
    enrollId = guardId;  // loop() chạy đăng ký, vì hàm này đang nằm trong callback MQTT
    return;
  }
  pinBuf = "";
  beep(3);
  if (++pinFails >= PIN_MAX_TRIES) {
    pinFails = 0;
    pinLockUntil = millis() + PIN_LOCK_MS;
    authMode = false;
    return showMsg("Tam khoa", "Sai PIN qua nhieu");
  }
  showMsg("Sai PIN", "Nhap lai roi #");
}

// ---------- Đăng ký vân tay (phím B -> PIN bảo vệ -> đặt tay 2 lần) ----------

void checkEmergency();

/// Chờ đặt tay (present) hoặc nhấc tay (!present). Trong lúc chờ vẫn giữ MQTT, nút khẩn cấp, OLED.
/// Hết giờ hoặc bấm D -> false.
bool waitFinger(bool present, uint32_t ms) {
  int lastCode = -1;
  for (uint32_t until = millis() + ms; millis() < until; delay(50)) {
    int code = finger.getImage();
    if (code != lastCode) Serial.printf("[vantay] getImage = %d\n", lastCode = code);  // 0 OK, 2 chưa có tay, 1/3 lỗi
    if ((code == FINGERPRINT_OK) == present) return true;
    if (keypad.getChar() == 'D') return false;
    msgUntil = millis() + 1000;  // giữ lời nhắc trên OLED suốt lúc chờ
    mqttLoop();
    checkEmergency();
    draw();
  }
  return false;
}

/// Lấy 2 ảnh cùng một ngón, ghép mẫu, lưu vào ô id của AS608. Trả về lý do lỗi, nullptr = thành công.
const char *enrollSteps(int id) {
  finger.getParameters();
  Serial.printf("[vantay] dang ky o %d, suc chua %d\n", id, finger.capacity);
  if (id < 1 || id > finger.capacity) return "ID vuot suc chua";
  for (int n = 1; n <= 2; n++) {
    showMsg(n == 1 ? "Dat ngon tay" : "Dat lai ngon", "Lan " + String(n) + "/2 - D: huy");
    if (!waitFinger(true, 15000)) return "Het gio / da huy";
    if (finger.image2Tz(n) != FINGERPRINT_OK) return "Anh mo, thu lai";
    beep(1, 30);
    showMsg("Nhac tay ra");
    waitFinger(false, 10000);
  }
  if (finger.createModel() != FINGERPRINT_OK) return "2 lan khong khop";
  if (finger.storeModel(id) != FINGERPRINT_OK) return "Loi luu mau";
  return nullptr;
}

void enrollFinger(int id) {
  const char *err = enrollSteps(id);
  Serial.printf("[vantay] ket qua: %s\n", err ? err : "OK");
  if (err) showMsg("DK THAT BAI", err);
  else showMsg("DA DANG KY", "Van tay #" + String(id));
  beep(err ? 3 : 1);
  if (err || !phoneConnected("out")) return;  // không có ĐT: mẫu đã lưu, nhập ID vân tay tay trong app
  JsonDocument ev;
  ev["t"] = "enrolled";
  ev["g"] = "out";
  ev["id"] = id;
  notify(ev);
}

const char *authTitle() { return authFor == 'e' ? "DK van tay" : authFor == 'c' ? "Cham cong" : "Mo cong ra"; }

void checkKeypad() {
  char k = keypad.getChar();
  if (k == lastKey) return;  // chỉ xử lý lúc vừa nhấn
  lastKey = k;
  if (k == 'N' || k == 'F') return;
  beep(1, 30);
  // A/B luôn bắt đầu lại; C chỉ bắt đầu chấm công khi chưa nhập PIN (đang nhập thì C = xoá 1 số).
  if (k == 'A' || k == 'B' || (k == 'C' && !authMode)) {
    authMode = true;
    authFor = k == 'A' ? 'o' : k == 'B' ? 'e' : 'c';
    authUntil = millis() + AUTH_WINDOW_MS;
    pinBuf = "";
    return showMsg(authTitle(), authFor == 'e' ? "PIN bao ve roi #" : "Van tay hoac PIN #");
  }
  if (!authMode) return;
  if (k == 'D') {
    authMode = false;
    return showMsg("Da huy");
  }
  if (k == '#') return submitPin();
  if (k == 'C' && pinBuf.length()) pinBuf.remove(pinBuf.length() - 1);  // xoá 1 số
  if (k == '*') pinBuf = "";                                             // xoá hết
  if (isDigit(k) && pinBuf.length() < 8) pinBuf += k;
  authUntil = millis() + AUTH_WINDOW_MS;  // còn bấm phím thì chưa hết giờ
  showMsg(authTitle(), "PIN: " + String("********").substring(0, pinBuf.length()));
}

// ---------- Khẩn cấp ----------

void checkEmergency() {
  bool pressed = digitalRead(EMERGENCY_PIN) == EMERGENCY_ACTIVE;
  if (pressed == emergencyLast || millis() - emergencyChangedAt < 50) return;
  emergencyLast = pressed;
  emergencyChangedAt = millis();
  if (!pressed) return;  // bật/tắt khi vừa nhấn
  emergency = !emergency;
  barrier.write(emergency ? SERVO_OPEN_DEG : SERVO_CLOSE_DEG);
  barrierCloseAt = 0;
  beep(emergency ? 5 : 1, 60);
  if (!phoneConnected("out")) {
    if (emergency) logOffline("out", "", "emg");
    return;
  }
  JsonDocument ev;
  ev["t"] = "emg";
  ev["g"] = "out";
  ev["on"] = emergency;
  notify(ev);
}

// ---------- Lệnh từ điện thoại ----------

void handleCmd(const char *s) {
  JsonDocument d;
  if (deserializeJson(d, s)) {
    Serial.printf("[mqtt] JSON loi: %s\n", s);
    return;
  }
  const char *t = d["t"] | "";
  if (!strcmp(t, "res")) {
    long id = d["id"] | 0L;  // id 0 = quẹt thử trên app: cổng rảnh cũng có pendingId 0, không được mở barrier
    for (Gate *g : {&gIn, &gOut})
      if (id && g->pendingId == id) finishScan(*g, d["ok"] | false, d["l1"] | "", d["l2"] | "", d["open"] | false);
  } else if (!strcmp(t, "open")) {
    openBarrier();
    showMsg("DA MO", "Lenh tu app");
    beep(1);
  } else if (!strcmp(t, "st")) {
    freeSlots = d["free"] | -1;
    capacity = d["cap"] | -1;
  } else if (!strcmp(t, "time")) {
    rtc.adjust(DateTime((uint32_t)(d["ts"] | 0UL)));
  } else if (!strcmp(t, "auth")) {
    if (pinSentAt) onPinResult(d["ok"] | false, d["gid"] | 0);  // bỏ qua nếu không có PIN nào đang chờ
  } else if (!strcmp(t, "wl")) {
    onWhitelist(d);
  } else if (!strcmp(t, "offack")) {
    onOfflineAck(d["n"] | 0);
  } else if (!strcmp(t, "attres")) {  // kết quả chấm công
    bool ok = d["ok"] | false;
    pinSentAt = 0;
    if (ok) pinFails = 0;
    authMode = false;
    pinBuf = "";
    showMsg(d["l1"] | "", d["l2"] | "");
    beep(ok ? 1 : 3);
  }
}

// ---------- setup / loop ----------

void initRfid(MFRC522 &r, int rstPin) {
  pinMode(rstPin, OUTPUT);
  digitalWrite(rstPin, HIGH);  // driver v2 không tự điều khiển RST
  r.PCD_Init();
}

void setup() {
  Serial.begin(115200);
  pinMode(BUZZER_PIN, OUTPUT);
  digitalWrite(BUZZER_PIN, LOW);
#if BUZZER_PASSIVE
  ledcSetup(BUZZER_CH, BUZZER_HZ, 8);
  ledcAttachPin(BUZZER_PIN, BUZZER_CH);
#endif
  gpio_set_drive_capability((gpio_num_t)BUZZER_PIN, GPIO_DRIVE_CAP_3);  // dòng ra tối đa ~40mA
  buzz(false);
  pinMode(EMERGENCY_PIN, INPUT);

  Wire.begin(I2C_SDA, I2C_SCL);
  if (!oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR)) Serial.println("OLED loi");
  if (!rtc.begin()) Serial.println("DS3231 loi");
  if (!keypad.begin()) Serial.println("PCF8574 loi");
  keypad.loadKeyMap((char *)KEYMAP);

  SPI.begin(RFID_IN_SCK, RFID_IN_MISO, RFID_IN_MOSI);
  hspi.begin(RFID_OUT_SCK, RFID_OUT_MISO, RFID_OUT_MOSI);
  initRfid(rfidIn, RFID_IN_RST);
  initRfid(rfidOut, RFID_OUT_RST);

  Serial2.begin(57600, SERIAL_8N1, FP_RX, FP_TX);
  fpOk = finger.verifyPassword();
  if (!fpOk) Serial.println("AS608 loi");

  ESP32PWM::allocateTimer(0);
  barrier.setPeriodHertz(50);
  barrier.attach(SERVO_PIN, 500, 2400);
  barrier.write(SERVO_CLOSE_DEG);

  if (!LittleFS.begin(true)) Serial.println("LittleFS loi");  // true: định dạng lại nếu chưa có
  loadWhitelist();

  initMqtt();
  Serial.println("[boot] dang ket noi WiFi: " WIFI_SSID);
  showMsg("San sang");
}

void loop() {
  mqttLoop();  // nhận lệnh từ ĐT -> handleCmd
  if (enrollId) {
    int id = enrollId;
    enrollId = 0;
    enrollFinger(id);
  }

  checkEmergency();
  checkFinger();
  checkKeypad();
  readCard(gIn);
  readCard(gOut);
  checkRfidHealth();
  checkTimeouts();
  flushOffline();

  uint32_t now = millis();
  if (authMode && now > authUntil) authMode = false;
  if (barrierCloseAt && now > barrierCloseAt && !emergency) {
    barrier.write(SERVO_CLOSE_DEG);
    barrierCloseAt = 0;
  }
  if (now - lastDraw > 250) {
    lastDraw = now;
    draw();
  }
}
