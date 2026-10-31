// Kiểm tra phần cứng từng linh kiện, không cần mạng.
// 1) Tự kiểm: I2C, OLED, RTC, PCF8574, 2x RC522, AS608, nút khẩn cấp.
// 2) Chạy thử: còi, servo (bạn quan sát/ nghe).
// 3) Tương tác: quẹt thẻ, bấm phím, đặt ngón tay, nhấn nút khẩn cấp -> in ra Serial + OLED.
// Lệnh Serial: 't' chạy lại tự kiểm, 'o' đóng/mở servo, 'l' chạy lại còi+servo.
#include <Arduino.h>
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

const int SERVO_OPEN_DEG = 90;
const int SERVO_CLOSE_DEG = 0;

SPIClass hspi(HSPI);
MFRC522DriverPinSimple ssIn(RFID_IN_SS), ssOut(RFID_OUT_SS);
// Cổng vào dùng HSPI, cổng ra dùng VSPI: cổng vào trên VSPI đọc được nhưng không ghi được (thay dây, đổi chân MOSI,
// đổi chéo module đều không hết), đổi bộ SPI thì cả 2 cổng ghi/đọc OK. Giữ giống main.cpp.
MFRC522DriverSPI drvIn{ssIn, hspi}, drvOut{ssOut, SPI};
MFRC522 rfidIn{drvIn}, rfidOut{drvOut};
I2CKeyPad keypad(PCF8574_ADDR);
Adafruit_SSD1306 oled(128, 64, &Wire, -1);
RTC_DS3231 rtc;
Adafruit_Fingerprint finger(&Serial2);
Servo barrier;

bool oledOk = false, fpOk = false, servoOpen = false, emLast = false;
char lastKey = 'N';
uint32_t lastFp = 0;
int passed = 0, total = 0;

void check(const char *name, bool ok, const String &detail = "") {
  total++;
  if (ok) passed++;
  Serial.printf("  [%s] %-22s %s\n", ok ? "PASS" : "FAIL", name, detail.c_str());
}

void oledShow(const String &a, const String &b = "") {
  if (!oledOk) return;
  oled.clearDisplay();
  oled.setTextColor(SSD1306_WHITE);
  // Chỉ dùng phần giữa (y 16..47) để không bị viền che.
  oled.setTextSize(a.length() <= 10 ? 2 : 1);
  oled.setCursor(0, 18);
  oled.print(a);
  oled.setTextSize(1);
  oled.setCursor(0, 38);
  oled.print(b);
  oled.display();
}

// Thước đo vùng nhìn thấy: 8 dòng chữ, dòng thứ n bắt đầu ở y = 8n.
// Đọc dòng đầu tiên và cuối cùng còn thấy rõ để biết viền module có che mép không.
void oledRuler() {
  if (!oledOk) return;
  oled.clearDisplay();
  oled.setTextColor(SSD1306_WHITE);
  oled.setTextSize(1);
  for (int y = 0; y < 64; y += 8) {
    oled.setCursor(0, y);
    oled.printf("dong %d (y=%d)", y / 8 + 1, y);
  }
  oled.display();
}

// Chẩn đoán OLED: trắng toàn màn -> khung viền + chữ to -> thước. Lặp 3 lần.
void oledDiag() {
  Serial.printf("[OLED] oledOk=%d, chay chan doan...\n", oledOk);
  if (!oledOk) oledOk = oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR);
  for (int n = 0; n < 3; n++) {
    oled.clearDisplay();
    oled.fillRect(0, 0, 128, 64, SSD1306_WHITE);
    oled.display();
    Serial.println("[OLED] 1) TRANG toan man");
    delay(2000);
    oled.clearDisplay();
    oled.drawRect(0, 0, 128, 64, SSD1306_WHITE);
    oled.setTextColor(SSD1306_WHITE);
    oled.setTextSize(2);
    oled.setCursor(16, 24);
    oled.print("OLED OK");
    oled.display();
    Serial.println("[OLED] 2) KHUNG VIEN + OLED OK");
    delay(3000);
    oledRuler();
    Serial.println("[OLED] 3) THUOC 8 dong");
    delay(4000);
  }
}

// Đọc byte trạng thái SSD1306 (bit6 = 1 nghĩa là màn đang TẮT), rồi ép bật + độ sáng tối đa + đảo màu.
void oledStatus() {
  Wire.requestFrom(OLED_ADDR, 1);
  int st = Wire.available() ? Wire.read() : -1;
  Serial.printf("[OLED] status=0x%02X -> man dang %s\n", st, st < 0 ? "KHONG DOC DUOC" : (st & 0x40) ? "TAT" : "BAT");
  oled.ssd1306_command(SSD1306_CHARGEPUMP);
  oled.ssd1306_command(0x14);
  oled.ssd1306_command(SSD1306_SETCONTRAST);
  oled.ssd1306_command(0xFF);
  oled.ssd1306_command(SSD1306_DISPLAYON);
  oled.ssd1306_command(SSD1306_DISPLAYALLON);  // bật toàn bộ điểm ảnh, bỏ qua RAM
  Serial.println("[OLED] ep sang toan bo diem anh 5s");
  delay(5000);
  oled.ssd1306_command(SSD1306_DISPLAYALLON_RESUME);
  Wire.requestFrom(OLED_ADDR, 1);
  st = Wire.available() ? Wire.read() : -1;
  Serial.printf("[OLED] status sau khi ep=0x%02X\n", st);
}

bool i2cHas(uint8_t addr);

// ---- Dò chân RC522 bằng bit-bang SPI: đọc VersionReg (0x37) với mọi tổ hợp SS/SCK/MOSI/MISO ----
// Loại trừ chân đã xác nhận: I2C 21/22, AS608 16/17, servo 13. Các chân không dùng trong lần thử
// được giữ HIGH để chân RST (chưa biết là chân nào) luôn ở mức cho phép RC522 chạy.
const int OUT_POOL[] = {4, 5, 18, 19, 23, 25, 26, 27, 32, 33, 14, 12, 2, 15};
const int IN_ONLY[] = {36, 39, 35, 34};
const int N_OUT = sizeof OUT_POOL / sizeof OUT_POOL[0];


uint8_t bbXfer(int ss, int sck, int mosi, int miso, uint8_t addr, uint8_t val) {
  pinMode(miso, INPUT);
  digitalWrite(sck, LOW);
  digitalWrite(ss, LOW);
  uint8_t out = addr, in = 0;
  for (int byteN = 0; byteN < 2; byteN++) {
    for (int b = 7; b >= 0; b--) {
      digitalWrite(mosi, (out >> b) & 1);
      delayMicroseconds(2);
      digitalWrite(sck, HIGH);
      if (byteN == 1) in = (in << 1) | digitalRead(miso);
      delayMicroseconds(2);
      digitalWrite(sck, LOW);
    }
    out = val;
  }
  digitalWrite(ss, HIGH);
  digitalWrite(sck, HIGH);
  digitalWrite(mosi, HIGH);
  return in;
}

// Ghi 0x5A rồi 0xA5 vào TReloadRegL (0x2D) và đọc lại: chỉ chip RC522 thật mới khớp cả hai.
bool bbProbe(int ss, int sck, int mosi, int miso) {
  for (uint8_t v : {0x5A, 0xA5}) {
    bbXfer(ss, sck, mosi, miso, 0x2D << 1, v);
    if (bbXfer(ss, sck, mosi, miso, 0x80 | (0x2D << 1), 0) != v) return false;
  }
  return true;
}

void scanRc522Pins() {
  SPI.end();
  hspi.end();
  Serial.println("\n===== DO CHAN RC522 (khoang 30-60s) =====");
  for (int i = 0; i < N_OUT; i++) {
    pinMode(OUT_POOL[i], OUTPUT);
    digitalWrite(OUT_POOL[i], HIGH);
  }
  delay(50);
  int found = 0;
  for (int pass = 0; pass < 2 && !found; pass++) {
    for (int a = 0; a < N_OUT; a++)
      for (int c = 0; c < N_OUT; c++)
        for (int m = 0; m < N_OUT; m++) {
          int ss = OUT_POOL[a], sck = OUT_POOL[c], mosi = OUT_POOL[m];
          if (ss == sck || ss == mosi || sck == mosi) continue;
          for (int k = 0; k < N_OUT + 4; k++) {
            int miso = k < N_OUT ? OUT_POOL[k] : IN_ONLY[k - N_OUT];
            if (miso == ss || miso == sck || miso == mosi) continue;
            bool hit = bbProbe(ss, sck, mosi, miso);
            if (k < N_OUT) {  // trả chân MISO thử về OUTPUT HIGH
              pinMode(miso, OUTPUT);
              digitalWrite(miso, HIGH);
            }
            if (hit && bbProbe(ss, sck, mosi, miso)) {
              uint8_t v = bbXfer(ss, sck, mosi, miso, 0x80 | (0x37 << 1), 0);
              if (k < N_OUT) { pinMode(miso, OUTPUT); digitalWrite(miso, HIGH); }
              // Tìm RST: kéo từng chân còn lại xuống LOW, chip ngừng trả lời -> đó là RST.
              int rst = -1;
              for (int r = 0; r < N_OUT && rst < 0; r++) {
                int p = OUT_POOL[r];
                if (p == ss || p == sck || p == mosi || p == miso) continue;
                digitalWrite(p, LOW);
                delay(5);
                if (!bbProbe(ss, sck, mosi, miso)) rst = p;
                digitalWrite(p, HIGH);
                delay(20);
                if (k < N_OUT) { pinMode(miso, OUTPUT); digitalWrite(miso, HIGH); }
              }
              Serial.printf("  [TIM THAY] RC522 ver=0x%02X  SS=%d SCK=%d MOSI=%d MISO=%d RST=%d\n", v, ss, sck, mosi,
                            miso, rst);
              found++;
            }
          }
          delayMicroseconds(200);
        }
    Serial.printf("  het luot %d, tim thay %d\n", pass + 1, found);
  }
  if (!found) Serial.println("  KHONG tim thay RC522 nao: kiem tra nguon 3.3V/GND cua RC522.");
  Serial.println("  (Reset board de dung lai cau hinh chan cu)");
}

// Dò dây OLED bằng còi trong 120s: OLED xuất hiện trên I2C -> bíp ngắn (+ vẽ màn trắng), mất -> bíp dài.
void oledWatch() {
  // Dò dây trong 180s, theo dõi cả DS3231 (0x68) và OLED (0x3C).
  // Module xuất hiện -> bíp ngắn (OLED: vẽ màn trắng), module mất -> bíp dài.
  Serial.println("[DO DAY] 180s: lac/cam lai day DS3231 + OLED, nghe coi\n");
  const uint8_t addrs[] = {0x68, OLED_ADDR};
  const char *names[] = {"DS3231", "OLED"};
  bool was[2];
  for (int i = 0; i < 2; i++) {
    was[i] = i2cHas(addrs[i]);
    Serial.printf("[DO DAY] %s ban dau: %s\n", names[i], was[i] ? "CO" : "KHONG");
  }
  for (uint32_t end = millis() + 180000; millis() < end;) {
    for (int i = 0; i < 2; i++) {
      bool now = i2cHas(addrs[i]);
      if (now == was[i]) continue;
      was[i] = now;
      Serial.printf("[DO DAY] %s %s\n", names[i], now ? "XUAT HIEN" : "MAT");
      digitalWrite(BUZZER_PIN, HIGH);
      delay(now ? 60 : 500);
      digitalWrite(BUZZER_PIN, LOW);
      if (now && addrs[i] == OLED_ADDR && (oledOk = oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR))) {
        oled.clearDisplay();
        oled.fillRect(0, 0, 128, 64, SSD1306_WHITE);
        oled.display();
      }
    }
    delay(100);
  }
  Serial.printf("[DO DAY] ket thuc: DS3231=%s OLED=%s\n", was[0] ? "CO" : "KHONG", was[1] ? "CO" : "KHONG");
}

bool i2cHas(uint8_t addr) {
  Wire.beginTransmission(addr);
  return Wire.endTransmission() == 0;
}

// Đọc thô VersionReg + ghi/đọc lại TReloadRegL. Không dùng PCD_GetVersion() vì nó trả 0xFF
// (Unknown) cho mọi chip clone có mã version lạ dù chip vẫn chạy tốt.
bool rfidOk(MFRC522Driver &d, String &detail) {
  using R = MFRC522Constants::PCD_Register;
  byte v = d.PCD_ReadRegister(R::VersionReg);
  d.PCD_WriteRegister(R::TReloadRegL, 0x5A);
  byte a = d.PCD_ReadRegister(R::TReloadRegL);
  d.PCD_WriteRegister(R::TReloadRegL, 0xA5);
  byte b = d.PCD_ReadRegister(R::TReloadRegL);
  bool ok = a == 0x5A && b == 0xA5;
  detail = String("version=0x") + String(v, HEX) + (ok ? " ghi/doc OK" : " KHONG PHAN HOI");
  return ok;
}

void autoTests() {
  passed = total = 0;
  Serial.println("\n===== 1. TU KIEM =====");

  String found;
  for (uint8_t a = 1; a < 127; a++)
    if (i2cHas(a)) found += String("0x") + String(a, HEX) + " ";
  Serial.printf("  I2C tim thay: %s\n", found.length() ? found.c_str() : "(khong co gi - kiem tra SDA/SCL/nguon)");

  check("OLED 0x3C", oledOk && i2cHas(OLED_ADDR), i2cHas(OLED_ADDR) ? "" : "mat ket noi I2C");
  oledShow("Dang test");

  bool rtcOk = i2cHas(0x68) && rtc.begin();
  if (rtcOk) {
    DateTime t1 = rtc.now();
    delay(1100);
    DateTime t2 = rtc.now();
    char buf[32];
    snprintf(buf, sizeof buf, "%02d:%02d:%02d %02d/%02d/%04d%s", t2.hour(), t2.minute(), t2.second(), t2.day(), t2.month(),
             t2.year(), rtc.lostPower() ? " (mat nguon pin!)" : "");
    check("DS3231 0x68 chay", t2.unixtime() > t1.unixtime(), buf);
  } else {
    check("DS3231 0x68 chay", false, "khong thay tren I2C");
  }

  check("PCF8574 phim 0x20", keypad.isConnected());

  String d;
  check("RC522 cong vao (HSPI)", rfidOk(drvIn, d), d);
  check("RC522 cong ra (VSPI)", rfidOk(drvOut, d), d);

  fpOk = finger.verifyPassword();
  if (fpOk) {
    finger.getTemplateCount();
    finger.getParameters();
    check("AS608 van tay", true, String(finger.templateCount) + "/" + String(finger.capacity) + " van tay da dang ky");
  } else {
    check("AS608 van tay", false, "khong phan hoi (TX/RX dao? baud 57600?)");
  }

  emLast = digitalRead(EMERGENCY_PIN) == EMERGENCY_ACTIVE;
  check("Nut khan cap dang nha", !emLast, emLast ? "dang doc la NHAN -> sai EMERGENCY_ACTIVE hoac dau day?" : "");

  Serial.printf("  => %d/%d PASS\n", passed, total);
  oledShow(String(passed) + "/" + String(total) + " PASS", "Xem Serial");
}

void outputTests() {
  Serial.println("\n===== 2. CHAY THU (quan sat/nghe) =====");
  Serial.println("  Coi keu 2 tieng");
  oledShow("Coi");
  for (int i = 0; i < 2; i++) {
    digitalWrite(BUZZER_PIN, HIGH);
    delay(150);
    digitalWrite(BUZZER_PIN, LOW);
    delay(150);
  }
  Serial.printf("  Servo: dong(%d) -> mo(%d) -> dong. Can adapter 12V cho servo.\n", SERVO_CLOSE_DEG, SERVO_OPEN_DEG);
  oledShow("Servo");
  barrier.write(SERVO_CLOSE_DEG);
  delay(700);
  barrier.write(SERVO_OPEN_DEG);
  delay(1200);
  barrier.write(SERVO_CLOSE_DEG);
  delay(700);
}

// Hiệu chỉnh phím: OLED yêu cầu bấm lần lượt từng phím in trên bàn phím,
// ghi lại vị trí quét thật (0-15) rồi in ra KEYMAP đúng với cách đấu dây hiện tại.
void calibrateKeypad() {
  const char order[] = "123A456B789C*0#D";
  char map[19] = "????????????????NF";
  Serial.println("\n===== HIEU CHINH PHIM: bam dung phim OLED yeu cau =====");
  for (int i = 0; i < 16; i++) {
    oledShow(String("Bam: ") + order[i], String(i + 1) + "/16");
    uint8_t idx;
    while ((idx = keypad.getKey()) >= 16) delay(20);  // chờ đến khi bấm, không tự bỏ qua
    if (map[idx] != '?') Serial.printf("  CANH BAO: vi tri %d da gan cho '%c'\n", idx, map[idx]);
    map[idx] = order[i];
    Serial.printf("  %c -> vi tri quet %d (hang %d, cot %d)\n", order[i], idx, idx / 4 + 1, idx % 4 + 1);
    digitalWrite(BUZZER_PIN, HIGH);
    delay(40);
    digitalWrite(BUZZER_PIN, LOW);
    oledShow(String("Da nhan ") + order[i], String("vi tri ") + idx);
    while (keypad.getKey() < 16) delay(20);  // chờ nhả phím
    delay(400);
  }
  keypad.loadKeyMap(map);
  Serial.printf("  => KEYMAP moi: const char KEYMAP[] = \"%s\";\n", map);
  Serial.println(strcmp(map, KEYMAP) == 0 ? "  => TRUNG voi KEYMAP hien tai, day dung." : "  => KHAC KEYMAP hien tai.");
  oledShow("Xong", "Xem Serial");
}

// Kiểm từng nút với KEYMAP hiện tại: OLED yêu cầu phím, so ký tự đọc được, báo DUNG/SAI.
void verifyKeypad() {
  const char order[] = "123A456B789C*0#D";
  String wrong;
  Serial.println("\n===== KIEM TUNG NUT =====");
  for (int i = 0; i < 16; i++) {
    oledShow(String("Bam: ") + order[i], String(i + 1) + "/16");
    char k;
    while ((k = keypad.getChar()) == 'N' || k == 'F') delay(20);
    bool ok = k == order[i];
    if (!ok) wrong += String(order[i]) + "->" + k + " ";
    Serial.printf("  Bam %c -> doc %c  %s\n", order[i], k, ok ? "DUNG" : "SAI");
    oledShow(ok ? "DUNG" : String("SAI: ") + k, String("Phim ") + order[i]);
    digitalWrite(BUZZER_PIN, HIGH);
    delay(ok ? 40 : 400);
    digitalWrite(BUZZER_PIN, LOW);
    while (keypad.getChar() != 'N') delay(20);  // chờ nhả phím
    delay(500);
  }
  Serial.printf("  => %s\n", wrong.length() ? (String("SAI: ") + wrong).c_str() : "16/16 DUNG");
  oledShow(wrong.length() ? "Co phim SAI" : "16/16 DUNG", "Xem Serial");
}

// Dò chân LED/còi/servo bằng bàn phím (không cần OLED): từng chân trống nhấp nháy,
// người dùng bấm phím theo thiết bị phản ứng: 1 vào XANH, 2 vào ĐỎ, 3 ra XANH, 4 ra ĐỎ,
// 5 CÒI, 6 SERVO, 0 không có gì -> sang chân sau.
void findOutputPins() {
  const int cand[] = {2, 12, 13, 15, 19, 25, 26};
  const char *names[] = {"", "LED_IN_G", "LED_IN_R", "LED_OUT_G", "LED_OUT_R", "BUZZER_PIN", "SERVO_PIN"};
  barrier.detach();
  for (int p : cand) {
    pinMode(p, OUTPUT);
    digitalWrite(p, LOW);
  }
  Serial.println("\n===== DO CHAN LED/COI/SERVO: 1 vao xanh, 2 vao do, 3 ra xanh, 4 ra do, 5 coi, 6 servo, 0 khong co =====");
  for (int p : cand) {
    Serial.printf("  Dang nhap nhay chan %d...\n", p);
    char k = 'N';
    bool on = false;
    while (k < '0' || k > '6') {
      on = !on;
      digitalWrite(p, on);
      for (int t = 0; t < 25; t++) {  // 250ms, vẫn quét phím
        k = keypad.getChar();
        if (k >= '0' && k <= '6') break;
        delay(10);
      }
    }
    digitalWrite(p, LOW);
    if (k == '0') Serial.printf("  chan %d: khong noi gi\n", p);
    else Serial.printf("  [KET QUA] #define %s %d\n", names[k - '0'], p);
    while (keypad.getChar() != 'N') delay(20);  // chờ nhả phím
    delay(300);
  }
  Serial.println("  Xong. Reset board de servo hoat dong lai.");
}

void pollCard(MFRC522 &r, const char *gate) {
  if (!r.PICC_IsNewCardPresent() || !r.PICC_ReadCardSerial()) return;
  String uid;
  for (byte i = 0; i < r.uid.size; i++) {
    char hex[3];
    snprintf(hex, sizeof hex, "%02X", r.uid.uidByte[i]);
    uid += hex;
  }
  r.PICC_HaltA();
  Serial.printf("[THE %s] UID %s\n", gate, uid.c_str());
  oledShow(uid, String("The ") + gate);
}

void setup() {
  Serial.begin(115200);
  delay(300);
  for (int p : {BUZZER_PIN}) {
    pinMode(p, OUTPUT);
    digitalWrite(p, LOW);
  }
  pinMode(EMERGENCY_PIN, INPUT);

  Wire.begin(I2C_SDA, I2C_SCL);
  oledOk = oled.begin(SSD1306_SWITCHCAPVCC, OLED_ADDR);
  keypad.begin();
  keypad.loadKeyMap((char *)KEYMAP);

  hspi.begin(RFID_IN_SCK, RFID_IN_MISO, RFID_IN_MOSI);
  SPI.begin(RFID_OUT_SCK, RFID_OUT_MISO, RFID_OUT_MOSI);
  for (int p : {RFID_IN_RST, RFID_OUT_RST}) {
    pinMode(p, OUTPUT);
    digitalWrite(p, HIGH);
  }
  rfidIn.PCD_Init();
  rfidOut.PCD_Init();

  Serial2.begin(57600, SERIAL_8N1, FP_RX, FP_TX);

  ESP32PWM::allocateTimer(0);
  barrier.setPeriodHertz(50);
  barrier.attach(SERVO_PIN, 500, 2400);

  autoTests();
  outputTests();
  Serial.println("\n===== 3. TUONG TAC =====");
  Serial.println("  Quet the o 2 dau doc, bam phim, dat ngon tay, nhan nut khan cap.");
  Serial.println("  Lenh: t = tu kiem lai, k = hieu chinh phim, o = dong/mo servo, l = coi+servo");
  oledRuler();  // giữ thước tới khi có thao tác đầu tiên
}

void loop() {
  pollCard(rfidIn, "VAO");
  pollCard(rfidOut, "RA");

  // Đọc thô PCF8574: kéo nửa thấp/nửa cao xuống 0 và xem nửa kia có bit nào bị kéo theo.
  // Không phụ thuộc keymap, nên thấy được cả khi hàng/cột đấu ngược.
  static uint8_t lastA = 0xF0, lastB = 0x0F;
  static uint32_t lastRaw = 0;
  if (millis() - lastRaw > 40) {
    lastRaw = millis();
    uint8_t a = 0, b = 0;
    Wire.beginTransmission(PCF8574_ADDR); Wire.write(0xF0); Wire.endTransmission();
    if (Wire.requestFrom(PCF8574_ADDR, 1) == 1) a = Wire.read();
    Wire.beginTransmission(PCF8574_ADDR); Wire.write(0x0F); Wire.endTransmission();
    if (Wire.requestFrom(PCF8574_ADDR, 1) == 1) b = Wire.read();
    if (a != lastA || b != lastB) {
      lastA = a;
      lastB = b;
      if (a != 0xF0 || b != 0x0F) Serial.printf("[PCF RAW] P7..P4=0x%X  P3..P0=0x%X\n", a >> 4, b & 0x0F);
    }
  }

  char k = keypad.getChar();
  if (k != lastKey) {
    lastKey = k;
    if (k == 'F') Serial.println("[PHIM] loi doc (bam 2 phim cung luc?)");
    else if (k != 'N') {
      Serial.printf("[PHIM] %c\n", k);
      oledShow(String("Phim ") + k);
    }
  }

  if (fpOk && millis() - lastFp > 200) {
    lastFp = millis();
    if (finger.getImage() == FINGERPRINT_OK) {
      if (finger.image2Tz() == FINGERPRINT_OK && finger.fingerFastSearch() == FINGERPRINT_OK) {
        Serial.printf("[VAN TAY] KHOP id #%d (do tin cay %d)\n", finger.fingerID, finger.confidence);
        oledShow(String("Van tay #") + finger.fingerID);
      } else {
        Serial.println("[VAN TAY] co ngon tay nhung KHONG KHOP (chua dang ky?)");
        oledShow("Van tay ?", "khong khop");
      }
      delay(800);
    }
  }

  bool em = digitalRead(EMERGENCY_PIN) == EMERGENCY_ACTIVE;
  if (em != emLast) {
    delay(30);
    if ((digitalRead(EMERGENCY_PIN) == EMERGENCY_ACTIVE) == em) {
      emLast = em;
      Serial.printf("[KHAN CAP] %s\n", em ? "NHAN" : "NHA");
      oledShow(em ? "KHAN CAP" : "Nut nha");
    }
  }

  if (Serial.available()) {
    char c = Serial.read();
    if (c == 't') autoTests();
    if (c == 'k') calibrateKeypad();
    if (c == 'r') oledRuler();
    if (c == 'v') verifyKeypad();
    if (c == 'd') oledDiag();
    if (c == 's') oledStatus();
    if (c == 'w') oledWatch();
    if (c == 'p') scanRc522Pins();
    if (c == 'g') findOutputPins();
    if (c == 'l') outputTests();
    if (c == 'o') {
      servoOpen = !servoOpen;
      barrier.write(servoOpen ? SERVO_OPEN_DEG : SERVO_CLOSE_DEG);
      Serial.printf("[SERVO] %s\n", servoOpen ? "MO" : "DONG");
    }
  }
}
