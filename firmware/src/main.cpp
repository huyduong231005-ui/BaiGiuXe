// ESP32 bãi giữ xe: 2 đầu đọc RFID, barrier cổng ra, OLED, phím, vân tay bảo vệ.
// Giao tiếp với điện thoại camera qua MQTT (HiveMQ Cloud, TLS): ESP32 dùng WiFi bãi xe, ĐT dùng WiFi hay 4G đều được.
//   ESP32 -> bgx/evt:  {"t":"scan","g":"in","uid":"..","id":5} · {"t":"auth","g":"out","pin":"1234"|"finger":3}
//                      · {"t":"emg","g":"out","on":true}
//   ĐT -> bgx/cmd:     {"t":"res","id":5,"ok":true,"open":true,"l1":"..","l2":".."} · {"t":"open"}
//                      · {"t":"st","free":37,"cap":50} · {"t":"time","ts":<giây local>} · {"t":"auth","ok":true}
//   Online/offline (retained + LWT, "1"/"0"): bgx/esp (ESP32), bgx/phone/in|out|both (từng ĐT).
// Điện thoại lo phần Supabase. Nút khẩn cấp và vân tay mở cổng cục bộ, không cần mạng.
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
#include <RTClib.h>
#include <Adafruit_Fingerprint.h>
#include <ESP32Servo.h>
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
const size_t CMD_MAX = 256;

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
uint32_t authUntil = 0, pinLockUntil = 0, pinSentAt = 0;
String pinBuf;
int pinFails = 0;
char lastKey = 'N';
bool phoneIn = false, phoneOut = false, phoneBoth = false;  // theo bgx/phone/<cổng>
uint32_t lastMqttTry = 0;

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
  if (WiFi.status() != WL_CONNECTED || millis() - lastMqttTry < 5000) return;
  lastMqttTry = millis();
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

void draw() {
  DateTime t = rtc.now();
  char buf[24];
  oled.clearDisplay();
  oled.setTextColor(SSD1306_WHITE);
  oled.setTextSize(1);
  oled.setCursor(0, 0);
  snprintf(buf, sizeof buf, "%02d:%02d %02d/%02d/%04d", t.hour(), t.minute(), t.day(), t.month(), t.year());
  oled.print(buf);
  oled.print(phoneConnected() ? "" : " !");  // "!" = chưa có điện thoại nào kết nối
  oled.setCursor(0, 12);
  if (emergency) oled.print("!! KHAN CAP - MO !!");
  else if (WiFi.status() != WL_CONNECTED) oled.print("Mat WiFi");
  else if (!mqtt.connected()) oled.print("Mat may chu MQTT");
  else if (!phoneConnected()) oled.print("Cho DT ket noi");
  else if (freeSlots >= 0) oled.printf("Con trong: %d/%d", freeSlots, capacity);
  bool showing = millis() < msgUntil || authMode;
  oled.setTextSize(msg1.length() <= 10 ? 2 : 1);
  oled.setCursor(0, 28);
  oled.print(showing ? msg1 : "Moi quet the");
  oled.setTextSize(1);
  oled.setCursor(0, 50);
  if (showing) oled.print(msg2);
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
    // Ghi rõ thiếu ĐT cho cổng nào: hay gặp khi chỉ có 1 ĐT mà chọn vai trò "cổng vào" thay vì "cả 2 cổng".
    const char *gateVi = strcmp(g.name, "in") ? "ra" : "vao";
    Serial.printf("[rfid] khong co DT phu trach cong %s -> tu choi\n", gateVi);
    return finishScan(g, false, "TU CHOI", String("Chua co DT cong ") + gateVi, false);
  }

  g.pendingId = nextId++;
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
    if (g->pendingId && millis() - g->pendingAt > RESULT_TIMEOUT_MS) finishScan(*g, false, "TU CHOI", "DT k phan hoi", false);
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
  if (millis() - lastFp < 200) return;
  lastFp = millis();
  if (finger.getImage() != FINGERPRINT_OK) return;
  if (finger.image2Tz() != FINGERPRINT_OK || finger.fingerFastSearch() != FINGERPRINT_OK) {
    showMsg("Van tay sai");
    beep(3);
    return;
  }
  // Vân tay đã khớp mẫu trong AS608 -> mở ngay; ĐT chỉ ghi log + đóng lượt bị từ chối gần nhất.
  grantLocal("Van tay #" + String(finger.fingerID));
  if (!phoneConnected("out")) return;  // ponytail: không có ĐT thì log bị mất, quản lý đóng lượt tay trong app
  JsonDocument ev;
  ev["t"] = "auth";
  ev["g"] = "out";
  ev["finger"] = finger.fingerID;
  notify(ev);
}

void submitPin() {
  if (millis() < pinLockUntil) return showMsg("Tam khoa", "Thu lai sau 60s");
  if (!phoneConnected("out")) return showMsg("Mat ket noi DT", "Dung van tay");
  JsonDocument ev;
  ev["t"] = "auth";
  ev["g"] = "out";
  ev["pin"] = pinBuf;  // đi qua TLS tới broker
  notify(ev);
  pinSentAt = millis();
  showMsg("Dang kiem tra", "PIN...");
}

void onPinResult(bool ok) {
  pinSentAt = 0;
  if (ok) {
    pinFails = 0;
    return grantLocal("PIN bao ve");
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

void checkKeypad() {
  char k = keypad.getChar();
  if (k == lastKey) return;  // chỉ xử lý lúc vừa nhấn
  lastKey = k;
  if (k == 'N' || k == 'F') return;
  beep(1, 30);
  if (k == 'A') {
    authMode = true;
    authUntil = millis() + AUTH_WINDOW_MS;
    pinBuf = "";
    return showMsg("Mo cong ra", "Van tay hoac PIN #");
  }
  if (!authMode) return;
  if (k == 'D') {
    authMode = false;
    return showMsg("Da huy");
  }
  if (k == '#') return submitPin();
  if (isDigit(k) && pinBuf.length() < 8) {
    pinBuf += k;
    showMsg("Mo cong ra", "PIN: " + String("********").substring(0, pinBuf.length()));
  }
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
  if (!phoneConnected("out")) return;
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
    long id = d["id"] | 0L;
    for (Gate *g : {&gIn, &gOut})
      if (g->pendingId == id) finishScan(*g, d["ok"] | false, d["l1"] | "", d["l2"] | "", d["open"] | false);
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
    if (pinSentAt) onPinResult(d["ok"] | false);  // bỏ qua nếu không có PIN nào đang chờ
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

  initMqtt();
  Serial.println("[boot] dang ket noi WiFi: " WIFI_SSID);
  showMsg("San sang");
}

void loop() {
  mqttLoop();  // nhận lệnh từ ĐT -> handleCmd

  checkEmergency();
  checkFinger();
  checkKeypad();
  readCard(gIn);
  readCard(gOut);
  checkRfidHealth();
  checkTimeouts();

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
