// Logic thuần (không I/O): chuẩn hoá biển số, tính phí, quyết định cho xe vào/ra.
// Message trả về là ASCII không dấu, tối đa 21 ký tự để vừa một dòng OLED.

typedef Rec = Map<String, dynamic>;

String normPlate(String? s) => (s ?? '').toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

/// OCR hay đọc nhầm đúng 1 ký tự (đo thực tế: Y->M, 8->3, 8->0) nên cho lệch tối đa 1 ký tự.
/// ponytail: tăng lên 2 nếu vẫn bị từ chối oan; giảm về 0 nếu lo xe khác biển gần giống dùng trộm thẻ.
const maxPlateDiff = 1;

/// Khoảng cách Levenshtein giữa hai biển đã chuẩn hoá (thêm/bớt/thay 1 ký tự = 1).
int plateDistance(String a, String b) {
  var prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, i);
    for (var j = 1; j <= b.length; j++) {
      final sub = prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      cur[j] = [sub, prev[j] + 1, cur[j - 1] + 1].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return prev[b.length];
}

bool samePlate(String? a, String? b) => plateDistance(normPlate(a), normPlate(b)) <= maxPlateDiff;

/// Biển [known] khớp kết quả OCR: khớp biển tốt nhất, hoặc một trong các phương án đọc khác (candidates).
bool matchesRead(String? known, String? best, List<String> candidates) =>
    samePlate(known, best) || candidates.any((c) => samePlate(known, c));

class FeeConfig {
  const FeeConfig({required this.priceDay, required this.priceNight, required this.nightMarkMinutes});

  factory FeeConfig.fromRow(Rec r) {
    final hm = (r['night_mark'] as String).split(':');
    return FeeConfig(
      priceDay: r['price_day'] as int,
      priceNight: r['price_night'] as int,
      nightMarkMinutes: int.parse(hm[0]) * 60 + int.parse(hm[1]),
    );
  }

  final int priceDay;
  final int priceNight;
  final int nightMarkMinutes;
}

/// Số lần mốc đêm (giờ địa phương) rơi vào khoảng [inT, outT).
int nightsCrossed(DateTime inT, DateTime outT, int markMinutes) {
  inT = inT.toLocal();
  outT = outT.toLocal();
  var mark = DateTime(inT.year, inT.month, inT.day, 0, markMinutes);
  if (mark.isBefore(inT)) mark = DateTime(mark.year, mark.month, mark.day + 1, mark.hour, mark.minute);
  var n = 0;
  while (mark.isBefore(outT)) {
    n++;
    mark = DateTime(mark.year, mark.month, mark.day + 1, mark.hour, mark.minute);
  }
  return n;
}

int calcFee(DateTime inT, DateTime outT, FeeConfig cfg, {bool monthly = false}) {
  if (monthly) return 0;
  final n = nightsCrossed(inT, outT, cfg.nightMarkMinutes);
  return n == 0 ? cfg.priceDay : n * cfg.priceNight;
}

class Decision {
  const Decision.deny(this.message)
      : ok = false,
        open = false,
        fee = null;
  const Decision.allow(this.message, {this.open = false, this.fee}) : ok = true;

  final bool ok;
  final bool open;
  final String message;
  final int? fee;
}

/// Độ tin cậy OCR tối thiểu để chấp nhận một lần đọc biển (dưới mức này app tự chụp lại 1 lần).
/// ponytail: hạ xuống nếu biển thật hay bị từ chối oan; nâng lên nếu vẫn lọt biển đọc sai.
const minPlateScore = 0.8;

/// Xe chỉ được vào khi: thẻ hợp lệ, bãi còn chỗ, ĐỌC ĐƯỢC biển rõ ràng, và biển đó chưa ở trong bãi.
/// Biển là chìa khoá đối chiếu lúc ra, nên không đọc được biển thì không cho vào.
Decision decideEntry({
  required Rec? card,
  required bool hasOpenSession,
  required int free,
  required String? plate,
  double score = 1,
  List<String> candidates = const [],
  List<String> parkedPlates = const [],
}) {
  if (card == null) return const Decision.deny('The chua dang ky');
  if (card['active'] != true) return const Decision.deny('The bi khoa');
  if (hasOpenSession) return const Decision.deny('The dang gui xe');
  if (free <= 0) return const Decision.deny('Bai da day');
  if (plate == null || normPlate(plate).isEmpty) return const Decision.deny('Khong doc duoc bien');
  if (score < minPlateScore) return const Decision.deny('Bien mo, quet lai');
  if (parkedPlates.any((p) => samePlate(p, plate))) return const Decision.deny('Xe da o trong bai');
  if (card['kind'] == 'monthly' && !matchesRead(card['plate'] as String?, plate, candidates)) {
    return const Decision.deny('Sai xe ve thang');
  }
  return const Decision.allow('Moi vao');
}

Decision decideExit({
  required Rec? card,
  required Rec? session,
  required String? plateOut,
  List<String> candidates = const [],
  required DateTime now,
  required FeeConfig cfg,
}) {
  if (session == null) return const Decision.deny('Khong co luot gui');
  if (plateOut == null) return const Decision.deny('Khong doc duoc bien');
  final plateIn = session['plate_in'] as String?;
  if (plateIn == null) return const Decision.deny('Thieu bien luc vao');
  if (!matchesRead(plateIn, plateOut, candidates)) return const Decision.deny('Sai bien so');
  final fee = feeFor(session, card, now, cfg);
  return Decision.allow('Phi: ${fee}d', open: true, fee: fee);
}

int feeFor(Rec session, Rec? card, DateTime now, FeeConfig cfg) =>
    calcFee(DateTime.parse(session['time_in'] as String), now, cfg, monthly: card?['kind'] == 'monthly');
