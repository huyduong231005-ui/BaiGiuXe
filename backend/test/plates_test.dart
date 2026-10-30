import 'dart:convert';

import 'package:bai_giu_xe_api/src/plates.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Ctx ctx;
  late String token;
  final sent = <http.Request>[];
  setUpAll(() async {
    ctx = await startApp(plateClient: MockClient((req) async {
      sent.add(req);
      return http.Response(jsonEncode({'results': [
        {'plate': '59x112345', 'score': 0.71, 'candidates': []},
        {'plate': '30a99999', 'score': 0.98, 'vehicle': {'type': 'Sedan'},
          'candidates': [{'plate': '30a99999'}, {'plate': '30a99998'}]},
      ]}), 200);
    }));
    token = await loginAs(ctx, 'manager', 'quanly');
  });
  tearDownAll(() => ctx.close());

  test('bestPlate lấy biển tin cậy cao nhất, chuẩn hoá kèm các phương án', () {
    expect(bestPlate([]), {'plate': null, 'score': 0, 'candidates': [], 'vehicle': null});
    expect(bestPlate([{'plate': 'ab-1', 'score': 0.9}]), {'plate': 'AB1', 'score': 0.9, 'candidates': ['AB1'], 'vehicle': null});
  });

  test('nhận diện biển: gửi ảnh qua API, token Plate Recognizer chỉ nằm ở máy chủ', () async {
    final r = await ctx.call('POST', '/plates/recognize', token: token, raw: [0xff, 0xd8, 0xff], headers: {'content-type': 'image/jpeg'});
    expect(r.status, 200);
    expect(r.body, {'plate': '30A99999', 'score': 0.98, 'candidates': ['30A99999', '30A99998'], 'vehicle': 'Sedan'});
    expect(sent[0].headers['authorization'], 'Token plate-token');
    expect(latin1.decode(sent[0].bodyBytes), contains('name="regions"\r\n\r\nvn'));

    expect((await ctx.call('POST', '/plates/recognize', token: token, body: {})).status, 400);
    expect((await ctx.call('POST', '/plates/recognize', raw: 'x'.codeUnits, headers: {'content-type': 'image/jpeg'})).status, 401);
  });

  test('ảnh biển số: ĐT camera tải lên, link ký có hạn xem được không cần đăng nhập, sửa link thì bị chặn', () async {
    const path = 'in/2026-10-30/1761800000000_A1B2C3D4.jpg';
    const jpg = [0xff, 0xd8, 0xff, 0xd9];
    final up = await ctx.call('PUT', '/gate/images?path=$path', token: token, raw: jpg, headers: {'content-type': 'image/jpeg'});
    expect(up.status, 204);
    final ok = await ctx.call('GET', '/plates/url?path=$path', token: token);
    final res = await http.get(Uri.parse(ok.body['url']));
    expect([res.statusCode, res.headers['content-type']], [200, 'image/jpeg']);
    expect(res.bodyBytes, jpg);
    expect((await http.get(Uri.parse((ok.body['url'] as String).replaceFirst('1761800000000', '1761800000001')))).statusCode, 403);
    expect((await ctx.call('GET', '/plates/url?path=../secret', token: token)).status, 400);
  });
}
