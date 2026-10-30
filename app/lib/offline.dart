import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'logic.dart';

/// Dự phòng mất mạng cho ĐT camera cổng:
/// - Lưu sẵn danh sách thẻ tháng còn hạn (GET /gate/whitelist) để cư dân vẫn ra vào khi API không gọi được.
/// - Lượt cho qua lúc mất mạng xếp vào hàng chờ (SharedPreferences, tắt app không mất), có mạng lại gửi bù POST /gate/offline.
/// Cùng định dạng sự kiện với ESP32 ({t: in|out, uid, ts: giây giờ địa phương, by: card|finger|emg}).
class GateOffline {
  GateOffline(this.prefs);

  static const _wlKey = 'gate_whitelist', _queueKey = 'gate_offline_queue';
  static const maxQueue = 2000;

  final SharedPreferences prefs;

  List<Rec> get whitelist => ((jsonDecode(prefs.getString(_wlKey) ?? '[]')) as List).cast<Rec>();
  List<Rec> get queue => ((jsonDecode(prefs.getString(_queueKey) ?? '[]')) as List).cast<Rec>();

  /// Lấy danh sách mới từ API. Trả về true nếu danh sách đổi (cần gửi lại cho ESP32).
  Future<bool> refreshWhitelist() async {
    final list = jsonEncode(await api.get('/gate/whitelist'));
    if (list == prefs.getString(_wlKey)) return false;
    await prefs.setString(_wlKey, list);
    return true;
  }

  bool allows(String uid, DateTime now) => whitelistAllows(whitelist, uid, now);

  Future<void> add(String gate, String uid, DateTime at, {String by = 'card'}) async {
    final q = [...queue, {'t': gate, 'uid': uid, 'ts': espTime(at), 'by': by}];
    await prefs.setString(_queueKey, jsonEncode(q.length > maxQueue ? q.sublist(q.length - maxQueue) : q));
  }

  /// Gửi bù hàng chờ lên API. API bỏ qua lượt đã ghi nên gửi lại khi lỗi giữa chừng không bị trùng.
  Future<int> flush() async {
    final q = queue;
    if (q.isEmpty) return 0;
    await api.post('/gate/offline', {'events': q});
    // Trong lúc gửi có thể đã thêm lượt mới: chỉ bỏ phần vừa gửi.
    final now = queue;
    await prefs.setString(_queueKey, jsonEncode(now.sublist(q.length.clamp(0, now.length))));
    return q.length;
  }
}

/// Giờ dạng ESP32 dùng (DS3231 chạy giờ địa phương): giây epoch của giờ địa phương.
int espTime(DateTime t) => t.millisecondsSinceEpoch ~/ 1000 + t.timeZoneOffset.inSeconds;

/// Thẻ có trong danh sách thẻ tháng và còn hạn tới hết ngày d (YYYYMMDD, 0 = không hạn).
bool whitelistAllows(List<Rec> list, String uid, DateTime now) {
  final today = now.year * 10000 + now.month * 100 + now.day;
  return list.any((c) => c['u'] == uid && ((c['d'] as int) == 0 || (c['d'] as int) >= today));
}

/// Chia danh sách thẻ thành các bản tin MQTT nhỏ cho ESP32 (bộ đệm 512 byte):
/// {"t":"wl","i":0,"n":25,"c":"A1B2C3D4:20261231;C0000001:0"} — i = vị trí phần tử đầu, n = tổng số thẻ.
List<Rec> whitelistMessages(List<Rec> list, {int per = 10}) => [
      for (var i = 0; i < list.length || i == 0; i += per)
        {
          't': 'wl',
          'i': i,
          'n': list.length,
          'c': list.skip(i).take(per).map((c) => '${c['u']}:${c['d']}').join(';'),
        },
    ];
