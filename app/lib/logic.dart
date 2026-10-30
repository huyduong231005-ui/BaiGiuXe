// Logic thuần (không I/O) dùng trên giao diện: chuẩn hoá biển số, hạn vé tháng, thống kê chấm công.
// Quyết định cho xe vào / ra, tính phí, chấm công ở cổng nằm trên API (backend/lib/src/rules.dart).

typedef Rec = Map<String, dynamic>;

String normPlate(String? s) => (s ?? '').toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');

/// Độ tin cậy OCR tối thiểu để chấp nhận một lần đọc biển (dưới mức này app tự chụp lại 1 lần).
/// ponytail: hạ xuống nếu biển thật hay bị từ chối oan; nâng lên nếu vẫn lọt biển đọc sai.
const minPlateScore = 0.8;

/// Vé tháng còn hạn: dùng tới hết ngày valid_until (giờ địa phương); valid_until null = không giới hạn.
bool monthlyValid(Rec? card, DateTime now) {
  if (card?['kind'] != 'monthly') return false;
  final v = card!['valid_until'] as String?;
  if (v == null) return true;
  final d = DateTime.parse(v);
  return now.isBefore(DateTime(d.year, d.month, d.day + 1));
}

String hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Số liệu một lượt chấm công (một dòng attendance). Quên chấm ra (method_out = auto) không tính giờ làm
/// và không tính về sớm vì giờ ra là giờ hệ thống tự đóng.
typedef AttStat = ({int lateMin, int earlyMin, int workedMin, bool open, bool missingOut});

AttStat attStat(Rec r) {
  DateTime? t(String k) => r[k] == null ? null : DateTime.parse(r[k] as String);
  final inT = t('time_in')!, outT = t('time_out'), start = t('shift_start'), end = t('shift_end');
  final missing = r['method_out'] == 'auto';
  final counted = outT != null && !missing;
  int pos(Duration d) => d.isNegative ? 0 : d.inMinutes;
  return (
    lateMin: start == null ? 0 : pos(inT.difference(start)),
    earlyMin: counted && end != null ? pos(end.difference(outT)) : 0,
    workedMin: counted ? pos(outT.difference(inT)) : 0,
    open: outT == null,
    missingOut: missing,
  );
}
