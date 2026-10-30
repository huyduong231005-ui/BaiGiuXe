import 'dart:convert';

import 'package:bai_giu_xe/api.dart';
import 'package:bai_giu_xe/offline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final wl = [
    {'u': 'C0000001', 'd': 0},
    {'u': 'C0000002', 'd': 20261031},
  ];

  test('danh sách thẻ tháng: không hạn luôn cho qua, có hạn dùng tới hết ngày, thẻ lạ từ chối', () {
    expect(whitelistAllows(wl, 'C0000001', DateTime(2030)), isTrue);
    expect(whitelistAllows(wl, 'C0000002', DateTime(2026, 10, 31, 23, 59)), isTrue);
    expect(whitelistAllows(wl, 'C0000002', DateTime(2026, 11, 1)), isFalse);
    expect(whitelistAllows(wl, 'FFFFFFFF', DateTime(2026)), isFalse);
  });

  test('chia danh sách thành bản tin nhỏ cho ESP32; danh sách rỗng vẫn gửi 1 bản tin để ESP32 xoá', () {
    final big = [for (var i = 0; i < 25; i++) {'u': 'C00000${i.toString().padLeft(2, '0')}', 'd': 0}];
    final msgs = whitelistMessages(big);
    expect(msgs.map((m) => m['i']), [0, 10, 20]);
    expect(msgs.last['c'], 'C0000020:0;C0000021:0;C0000022:0;C0000023:0;C0000024:0');
    expect(msgs.every((m) => jsonEncode(m).length < 400), isTrue); // vừa bộ đệm MQTT 512 byte của ESP32
    expect(whitelistMessages(const []), [{'t': 'wl', 'i': 0, 'n': 0, 'c': ''}]);
  });

  test('giờ gửi cho API cùng kiểu giờ DS3231 (giây epoch của giờ địa phương)', () {
    final t = DateTime(2026, 10, 30, 8);
    expect(espTime(t), t.millisecondsSinceEpoch ~/ 1000 + t.timeZoneOffset.inSeconds);
  });

  test('mất mạng: lượt cho qua xếp hàng chờ, có mạng lại gửi bù rồi xoá khỏi hàng chờ', () async {
    SharedPreferences.setMockInitialValues({});
    final sent = <Object?>[];
    api = Api(client: MockClient((req) async {
      if (req.url.path == '/gate/whitelist') return http.Response(jsonEncode(wl), 200);
      sent.add(jsonDecode(req.body));
      return http.Response(jsonEncode({'received': 1, 'applied': 1}), 200);
    }));
    final off = GateOffline(await SharedPreferences.getInstance());
    expect(await off.refreshWhitelist(), isTrue);
    expect(await off.refreshWhitelist(), isFalse); // không đổi thì không gửi lại ESP32
    expect(off.allows('C0000001', DateTime(2026, 10, 30)), isTrue);

    await off.add('out', 'C0000001', DateTime(2026, 10, 30, 8));
    expect(off.queue.single['by'], 'card');
    expect(await off.flush(), 1);
    expect((sent.single as Map)['events'], hasLength(1));
    expect(off.queue, isEmpty);
    expect(await off.flush(), 0);
  });
}
