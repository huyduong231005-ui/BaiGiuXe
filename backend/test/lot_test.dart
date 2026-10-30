import 'package:test/test.dart';

import 'helpers.dart';

// Mặt bằng thử: lối vào ở cột 1, lối ra ở cột 7, một làn đường, khu A xe máy 2 ô gần cổng vào, khu C ô tô 2 ô.
const layout = ['#I#####O#', '#=======#', '#AA.CC..#', '#########'];

void main() {
  late Ctx ctx;
  late String token;
  setUpAll(() async {
    ctx = await startApp();
    token = await loginAs(ctx, 'manager', 'quanly');
  });
  tearDownAll(() => ctx.close());

  Future<Res> call(String method, String path, [Object? body]) => ctx.call(method, path, token: token, body: body);
  Future<Res> scan(Map body) => call('POST', '/gate/scan', {'score': 0.95, ...body});

  test('bảng giá theo loại xe: 3 loại mặc định, thêm / sửa / không xoá được loại đang dùng', () async {
    final types = (await call('GET', '/vehicle-types')).body as List;
    expect([for (final t in types) [t['code'], t['price_day'], t['price_night'], t['price_month']]],
        [['motorbike', 5000, 10000, 150000], ['car', 25000, 50000, 1500000], ['bicycle', 2000, 5000, 100000]]);
    expect((await call('POST', '/vehicle-types', {'code': 'X', 'name': 'Lỗi', 'priceDay': 1, 'priceNight': 1, 'priceMonth': 1})).status, 400);
    final e = await call('POST', '/vehicle-types', {'code': 'ebike', 'name': 'Xe điện', 'priceDay': 4000, 'priceNight': 8000, 'priceMonth': 120000});
    expect(e.status, 201);
    expect((await call('PUT', '/vehicle-types/${e.body['id']}',
        {'name': 'Xe máy điện', 'priceDay': 4000, 'priceNight': 8000, 'priceMonth': 130000})).body['price_month'], 130000);
    expect((await call('DELETE', '/vehicle-types/${e.body['id']}')).status, 204);
    final quote = await call('POST', '/fees/quote', {'timeIn': '2026-10-28T01:00:00Z', 'timeOut': '2026-10-28T03:00:00Z', 'vehicleType': 'car'});
    expect(quote.body['fee'], 25000);
  });

  test('mặt bằng: tạo khu, vẽ ô, kiểm tra lối vào / ra / đường tới ô, giữ mã ô khi sửa, gán ô cư dân', () async {
    expect((await call('POST', '/zones', {'name': 'A', 'vehicleType': 'tau'})).status, 400);
    expect((await call('POST', '/zones', {'name': 'I', 'vehicleType': 'motorbike'})).status, 400); // I, O dành cho lối vào / ra
    final a = await call('POST', '/zones', {'name': 'a', 'vehicleType': 'motorbike'});
    expect(a.status, 201);
    await call('POST', '/zones', {'name': 'C', 'vehicleType': 'car'});

    Future<String> bad(List<String> l) async => (await call('PUT', '/lot/layout', {'layout': l})).body['message'];
    expect(await bad([for (final l in layout) l.replaceFirst('CC', 'BB')]), contains('Khu B chưa tạo'));
    expect(await bad([for (final l in layout) l.replaceFirst('O', '#')]), contains('lối ra'));
    expect(await bad([...layout.take(3), '#.....A.#', '#########']), contains('không có đường xe tới'));
    expect(await bad(['#I#O', '#==#', '#=']), contains('dài bằng nhau'));

    final saved = await call('PUT', '/lot/layout', {'layout': layout});
    expect(saved.status, 200);
    expect(saved.body['layout'], layout);
    expect([for (final z in saved.body['zones']) [for (final s in z['slots']) [s['code'], s['row'], s['col']]]],
        [[['A-01', 2, 1], ['A-02', 2, 2]], [['C-01', 2, 4], ['C-02', 2, 5]]]);

    await call('POST', '/cards', {'uid': 'C0000001', 'kind': 'monthly', 'plate': '59X111111', 'owner': 'Cư dân 1', 'apartment': 'a1-12.05'});
    await call('POST', '/cards', {'uid': 'C0000002', 'kind': 'guest'});
    expect((await call('PATCH', '/slots/A-01', {'cardUid': 'C0000002'})).status, 400); // thẻ lượt không giữ ô
    expect((await call('PATCH', '/slots/C-01', {'cardUid': 'C0000001'})).status, 400); // khác loại xe
    expect((await call('PATCH', '/slots/A-01', {'cardUid': 'c0000001'})).body['card_uid'], 'C0000001');
    final cards = (await call('GET', '/cards?q=C0000001')).body;
    expect([cards[0]['slot_code'], cards[0]['apartment'], cards[0]['vehicle_type']], ['A-01', 'A1-12.05', 'motorbike']);

    // Sửa mặt bằng: dời C-02 sang cột 6. Ô giữ vị trí giữ nguyên mã (ô cư dân A-01 không bị lệch), ô mới lấy số mới.
    final moved = [for (var r = 0; r < layout.length; r++) r == 2 ? '#AA.C.C.#' : layout[r]];
    final m = (await call('PUT', '/lot/layout', {'layout': moved})).body;
    expect([for (final s in m['zones'][1]['slots']) [s['code'], s['col']]], [['C-01', 4], ['C-02', 6]]);
    expect(m['zones'][0]['slots'][0]['card_uid'], 'C0000001');
    await call('PUT', '/lot/layout', {'layout': layout});
    expect((await call('GET', '/status')).body['capacity'], 4); // có sơ đồ thì sức chứa = số ô
    expect((await call('DELETE', '/zones/${a.body['id']}')).status, 409); // còn ô trên mặt bằng

    // Đường từ cổng vào tới ô + lời chỉ dẫn, và từ ô ra cổng ra
    final r = (await call('GET', '/lot/route?slot=c-02')).body;
    expect([r['path'][0], (r['path'] as List).last, (r['exitPath'] as List).last], [[0, 1], [2, 5], [0, 7]]);
    expect(r['hint'], 'Qua cổng vào, đi thẳng 1 ô, rẽ trái đi 4 ô, ô C-02 ở bên phải');
    expect((await call('GET', '/lot/route?slot=Z-99')).status, 404);
  });

  test('khách vãng lai được chỉ ô trống không phải ô cư dân; cư dân vào ô riêng; hết chỗ thì từ chối', () async {
    await call('POST', '/cards', {'uid': 'C0000003', 'kind': 'guest'});
    final guest = (await scan({'gate': 'in', 'uid': 'C0000002', 'plate': '30A11111', 'vehicle': 'Motorcycle'})).body;
    expect([guest['ok'], guest['l2'], guest['slot']], [true, 'Moi vao o A-02', 'A-02']); // A-01 là của cư dân
    expect(guest['route']['hint'], 'Qua cổng vào, đi thẳng 1 ô, rẽ trái đi 1 ô, ô A-02 ở bên phải');
    final full = (await scan({'gate': 'in', 'uid': 'C0000003', 'plate': '30A22222', 'vehicle': 'Motorcycle'})).body;
    expect([full['ok'], full['l2']], [false, 'Het cho xe may']);
    final car = (await scan({'gate': 'in', 'uid': 'C0000003', 'plate': '51G33333', 'vehicle': 'Sedan'})).body;
    expect([car['ok'], car['slot']], [true, 'C-01']); // OCR nhận ra ô tô -> ô tô trống gần cổng vào nhất
    final resident = (await scan({'gate': 'in', 'uid': 'C0000001', 'plate': '59X111111'})).body;
    expect([resident['ok'], resident['slot']], [true, 'A-01']);

    final map = (await call('GET', '/lot/map')).body;
    final a01 = map['zones'][0]['slots'][0];
    expect([a01['state'], a01['plate'], a01['apartment']], ['parked', '59X111111', 'A1-12.05']);
    expect((await call('GET', '/status')).body['byType']['motorbike']['free'], 0);
    // Khách xem sơ đồ: không lộ biển số / chủ xe
    final khach = await loginAs(ctx, 'customer', 'khach');
    final pub = (await ctx.call('GET', '/lot/map/public', token: khach)).body;
    expect((pub['zones'][0]['slots'][0] as Map).containsKey('plate'), isFalse);

    // Xe ra: ô trả lại, giá theo loại xe của lượt (ô tô 25.000đ)
    final out = (await scan({'gate': 'out', 'uid': 'C0000003', 'plate': '51G33333'})).body;
    expect([out['ok'], out['fee'], out['slot']], [true, 25000, 'C-01']);
    expect((await call('DELETE', '/zones/${map['zones'][0]['id']}')).status, 409); // khu có xe / ô cư dân
  });

  test('thống kê nhận diện biển: tốc độ, đọc được lần đầu, khớp biển lúc ra', () async {
    await scan({'gate': 'in', 'uid': 'FFFFFFFF', 'plate': null, 'score': 0, 'shots': 2, 'ocrMs': 3400, 'totalMs': 3900});
    final st = (await call('GET', '/stats/ocr')).body;
    expect(st['scans'], greaterThanOrEqualTo(5));
    expect(st['ocrMs']['p95'], 3400);
    expect(st['readRate'], lessThan(100));
    expect(st['exitMatchRate'], 100);
    expect((st['reasons'] as List).any((r) => r['message'] == 'Het cho xe may'), isTrue);
    expect(st['recent'][0]['shots'], 2);
  });

  test('doanh thu: tách vé lượt / vé tháng, theo ngày và theo tháng, theo loại xe', () async {
    // Đơn vé tháng ô tô 2 tháng được duyệt -> khoản thu 3.000.000đ
    final khach = await loginAs(ctx, 'customer', 'khach2');
    final r = await ctx.call('POST', '/me/requests', token: khach,
        body: {'plate': '51H44444', 'ownerName': 'Bình', 'months': 2, 'vehicleType': 'car', 'apartment': 'B2-03.01'});
    final ok = await call('POST', '/requests/${r.body['id']}/approve', {'cardUid': 'D0000001'});
    expect([ok.body['card']['vehicle_type'], ok.body['card']['apartment']], ['car', 'B2-03.01']);

    final day = (await call('GET', '/stats/revenue')).body;
    expect(day['rows'].length, 30);
    expect([day['visitor'], day['monthly'], day['total']], [25000, 3000000, 3025000]);
    expect((day['rows'] as List).last['total'], 3025000);
    final car = (day['byType'] as List).firstWhere((t) => t['vehicle_type'] == 'car');
    expect([car['name'], car['visitor'], car['monthly']], ['Ô tô', 25000, 3000000]);
    final month = (await call('GET', '/stats/revenue?group=month')).body;
    expect(month['rows'].length, 12);
    expect((month['rows'] as List).last['total'], 3025000);
    expect((await call('GET', '/stats/revenue?group=year')).status, 400);
  });

  test('mất mạng: ESP32 lấy danh sách thẻ tháng, gửi bù lượt ra / vào không bị ghi trùng', () async {
    final wl = (await call('GET', '/gate/whitelist')).body as List;
    expect(wl.any((c) => c['u'] == 'C0000001' && c['d'] == 0), isTrue);
    expect(wl.any((c) => c['u'] == 'C0000002'), isFalse); // thẻ lượt không có

    // Cư dân mới chưa có lượt gửi: mất mạng lúc vào (2 giờ trước) và lúc ra (1 giờ trước). Giờ ESP32 = giờ địa phương dạng epoch.
    await call('POST', '/cards', {'uid': 'C0000004', 'kind': 'monthly', 'plate': '59X444444', 'apartment': 'C3-01.01'});
    int local(DateTime d) => d.millisecondsSinceEpoch ~/ 1000 + d.timeZoneOffset.inSeconds;
    final events = [
      {'t': 'out', 'uid': 'C0000004', 'ts': local(ago(1)), 'by': 'card'}, // gửi lệch thứ tự: API tự xếp theo giờ
      {'t': 'in', 'uid': 'C0000004', 'ts': local(ago(2)), 'by': 'card'},
      {'t': 'out', 'ts': local(ago(1)), 'by': 'finger', 'guard': 3},
    ];
    expect((await call('POST', '/gate/offline', {'events': events})).body, {'received': 3, 'applied': 3});
    expect((await call('POST', '/gate/offline', {'events': events})).body, {'received': 3, 'applied': 0}); // gửi lại
    final day = ago(2);
    final date = '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
    final s = (await call('GET', '/sessions?plate=59X444444&date=$date')).body['sessions'][0];
    final hours = DateTime.parse(s['time_out']).difference(DateTime.parse(s['time_in'])).inMinutes / 60;
    expect([s['offline'], s['fee'], hours.round()], [true, 0, 1]);
    final log = [for (final e in (await call('GET', '/events?limit=3')).body) e['message']];
    expect(log, contains('Offline: bao ve mo bang van tay #3'));
  });
}
