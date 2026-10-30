import 'package:bai_giu_xe_api/src/db.dart';
import 'package:excel/excel.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late Ctx ctx;
  late String token;
  setUpAll(() async {
    ctx = await startApp();
    token = await loginAs(ctx, 'manager', 'quanly');
    await Card.create({'uid': '11111111', 'kind': 'guest'});
    await Card.create({'uid': '22222222', 'kind': 'monthly', 'plate': '30A99999'});
    await Session.insert({'card_uid': '11111111', 'plate_in': '59X112345', 'time_in': DateTime.parse('2026-10-05T08:00:00+07:00'),
      'time_out': DateTime.parse('2026-10-05T10:00:00+07:00'), 'fee': 3000, 'parked': false});
    await Session.insert({'card_uid': '22222222', 'plate_in': '30A99999', 'time_in': ago(1)});
    final g = await Guard.insert({'name': 'Nguyễn Văn Tuấn'});
    await Attendance.insert({'guard_id': g['id'], 'shift_name': 'Ca sáng',
      'shift_start': DateTime.parse('2026-10-05T06:00:00+07:00'), 'shift_end': DateTime.parse('2026-10-05T14:00:00+07:00'),
      'time_in': DateTime.parse('2026-10-05T06:15:00+07:00'), 'time_out': DateTime.parse('2026-10-05T14:00:00+07:00'),
      'method_in': 'finger', 'method_out': 'finger', 'on_duty': false});
  });
  tearDownAll(() => ctx.close());

  test('tra cứu xe trong bãi theo biển: khớp lệch 1 ký tự, xét cả candidates, kèm phí tạm tính', () async {
    final r = await ctx.call('GET', '/sessions/lookup?plate=30A-99998', token: token);
    expect(r.body['matches'].length, 1);
    final m = r.body['matches'][0];
    expect([m['card_uid'], m['exact'], m['feeNow']], ['22222222', false, 0]);
    final viaCandidate = await ctx.call('GET', '/sessions/lookup?plate=51F00001&candidates=30A99999', token: token);
    expect(viaCandidate.body['matches'][0]['card_kind'], 'monthly');
    expect((await ctx.call('GET', '/sessions/lookup?plate=59X112345', token: token)).body['matches'].length, 0); // đã ra
    expect((await ctx.call('GET', '/sessions/lookup', token: token)).status, 400);
  });

  test('báo cáo tháng Excel: doanh thu, lượt gửi, bảng công', () async {
    final res = await http.get(Uri.parse('${ctx.base}/reports/monthly.xlsx?month=2026-10'),
        headers: {'authorization': 'Bearer $token'});
    expect(res.statusCode, 200);
    expect(res.headers['content-disposition'], contains('bao-cao-2026-10.xlsx'));
    final wb = Excel.decodeBytes(res.bodyBytes);
    expect(wb.tables.keys.toList(), ['Doanh thu', 'Lượt gửi', 'Bảng công', 'Chi tiết chấm công']);
    List values(String sheet, int row) => [for (final c in wb.tables[sheet]!.rows[row]) c?.value.toString()];
    expect(values('Doanh thu', 1), ['2026-10-05', '1', '3000']);
    expect(values('Doanh thu', 2), ['Tổng', '1', '3000']);
    expect(values('Bảng công', 1), ['Nguyễn Văn Tuấn', '1', '7.75', '1', '15', '0', '0', '0']);
    expect((await ctx.call('GET', '/reports/monthly.xlsx?month=10-2026', token: token)).status, 400);
  });
}
