import 'package:bai_giu_xe_api/src/auth.dart' show checkPassword;
import 'package:bai_giu_xe_api/src/db.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Ctx ctx;
  late String token;
  setUpAll(() async {
    ctx = await startApp();
    token = await loginAs(ctx, 'manager', 'quanly');
  });
  tearDownAll(() => ctx.close());

  Future<Map<String, dynamic>> tuan() async => row(await Guard.findOne({'name': 'Nguyễn Văn Tuấn'}))!;

  test('bảo vệ: PIN bắt buộc 4-8 số, lưu dạng bcrypt, không trả hash ra ngoài', () async {
    expect((await ctx.call('POST', '/guards', token: token, body: {'name': 'Tuấn', 'pin': '12'})).status, 400);
    final g = await ctx.call('POST', '/guards', token: token, body: {'name': 'Nguyễn Văn Tuấn', 'pin': '1234'});
    expect(g.status, 201);
    expect([g.body['has_pin'], (g.body as Map).containsKey('pin_hash')], [true, false]);
    final hash = (await Guard.findById(g.body['id']))!['pin_hash'] as String;
    expect(hash.startsWith(r'$2') && await checkPassword('1234', hash), isTrue);

    final p = await ctx.call('PATCH', '/guards/${g.body['id']}', token: token, body: {'fingerId': 3});
    expect([p.body['finger_id'], p.body['name']], [3, 'Nguyễn Văn Tuấn']);
    expect((await ctx.call('PATCH', '/guards/${g.body['id']}', token: token, body: {'fingerId': 999})).status, 400);
  });

  test('ca trực: thêm, sửa, kiểm giờ HH:MM', () async {
    expect((await ctx.call('GET', '/shifts', token: token)).body.length, 3); // 3 ca mặc định do initDb tạo
    expect((await ctx.call('POST', '/shifts', token: token, body: {'name': 'Ca gãy', 'startTime': '25:00', 'endTime': '01:00'})).status, 400);
    final s = await ctx.call('POST', '/shifts', token: token, body: {'name': 'Ca hành chính', 'startTime': '08:00', 'endTime': '17:00'});
    final u = await ctx.call('PUT', '/shifts/${s.body['id']}', token: token, body: {'name': 'Ca HC', 'startTime': '07:30', 'endTime': '17:00'});
    expect([u.body['name'], u.body['start_time']], ['Ca HC', '07:30:00']);
    expect((await ctx.call('DELETE', '/shifts/${s.body['id']}', token: token)).status, 204);
  });

  test('bảng công tháng: tổng hợp theo bảo vệ; tài khoản bảo vệ chỉ xem của mình', () async {
    final g = await tuan();
    await Attendance.insert({'guard_id': g['id'], 'shift_name': 'Ca sáng',
      'shift_start': DateTime.parse('2026-10-28T06:00:00+07:00'), 'shift_end': DateTime.parse('2026-10-28T14:00:00+07:00'),
      'time_in': DateTime.parse('2026-10-28T06:10:00+07:00'), 'time_out': DateTime.parse('2026-10-28T13:50:00+07:00'),
      'method_in': 'finger', 'method_out': 'pin', 'on_duty': false});
    final r = await ctx.call('GET', '/attendance?month=2026-10', token: token);
    expect(r.body['summary'][0], {'guardId': g['id'], 'name': 'Nguyễn Văn Tuấn', 'shifts': 1, 'workedMin': 460,
      'lateCount': 1, 'lateMin': 10, 'earlyCount': 1, 'earlyMin': 10, 'missingOut': 0});
    expect(r.body['records'][0]['lateMin'], 10);

    final guard = await loginAs(ctx, 'guard', 'tuan');
    expect((await ctx.call('GET', '/me/attendance', token: guard)).status, 404);
    await User.updateOne({'username': 'tuan'}, {'guard_id': g['id']});
    final mine = await ctx.call('GET', '/me/attendance?month=2026-10', token: guard);
    expect(mine.body['records'].length, 1);
    expect((await ctx.call('GET', '/attendance', token: guard)).status, 403);
  });

  test('không xoá được bảo vệ đã có bảng công', () async {
    final g = await tuan();
    expect((await ctx.call('DELETE', '/guards/${g['id']}', token: token)).status, 409);
  });
}
