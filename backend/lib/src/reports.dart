// Báo cáo tháng ra Excel: doanh thu theo ngày, danh sách lượt gửi, bảng công bảo vệ.
import 'package:excel/excel.dart';
import 'package:shelf/shelf.dart' show Response;

import 'db.dart';
import 'guards.dart' show attendanceRows;
import 'http.dart';
import 'parking.dart';
import 'rules.dart';

final _monthRe = RegExp(r'^\d{4}-\d{2}$');
final _bold = CellStyle(bold: true);

String _local(Object? d) {
  final t = toDate(d)?.toLocal();
  if (t == null) return '';
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(t.hour)}:${p(t.minute)}:${p(t.second)} ${t.day}/${t.month}/${t.year}'; // như toLocaleString('vi-VN')
}

double _hours(num min) => (min / 60 * 100).round() / 100;

CellValue? _cell(Object? v) => switch (v) {
      null => null,
      int n => IntCellValue(n),
      double d when d == d.truncateToDouble() => IntCellValue(d.toInt()),
      double d => DoubleCellValue(d),
      _ => TextCellValue('$v'),
    };

/// Thêm 1 sheet: dòng tiêu đề in đậm, cột rộng theo tiêu đề (hoặc độ rộng truyền vào).
Sheet _addSheet(Excel wb, String name, List<(String, String, double?)> columns, List<Map> rows) {
  final ws = wb[name];
  ws.appendRow([for (final (header, _, _) in columns) TextCellValue(header)]);
  for (var c = 0; c < columns.length; c++) {
    final (header, _, width) = columns[c];
    ws.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).cellStyle = _bold;
    ws.setColumnWidth(c, width ?? (header.length + 2 > 12 ? header.length + 2 : 12).toDouble());
  }
  for (final r in rows) {
    ws.appendRow([for (final (_, key, _) in columns) _cell(r[key])]);
  }
  return ws;
}

Future<List<int>> monthlyWorkbook(String month) async {
  final [y, m] = month.split('-').map(int.parse).toList();
  final from = DateTime(y, m), to = DateTime(y, m + 1);
  final sessions = await withJoins(
      await Session.find({'time_in': {r'$gte': from, r'$lt': to}}, {'time_in': 1}), ['kind']);
  final revenue = await revenueByDay(from, to);
  final attendance = await attendanceRows(from, to, null, 1);

  final wb = Excel.createExcel();
  final first = wb.getDefaultSheet()!;
  final rev = _addSheet(wb, 'Doanh thu', [('Ngày', 'day', null), ('Số lượt ra', 'sessions', null), ('Doanh thu (đ)', 'revenue', 16)], revenue);
  rev.appendRow([
    TextCellValue('Tổng'),
    IntCellValue(revenue.fold<num>(0, (a, r) => a + r['sessions']).toInt()),
    IntCellValue(revenue.fold<num>(0, (a, r) => a + r['revenue']).toInt()),
  ]);
  final money = NumFormat.custom(formatCode: '#,##0');
  for (var r = 1; r <= revenue.length + 1; r++) {
    final total = r == revenue.length + 1;
    for (var c = 0; c < 3; c++) {
      rev.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: total, numberFormat: c == 2 ? money : NumFormat.standard_0);
    }
  }
  wb.delete(first); // sheet trống mặc định của thư viện

  _addSheet(wb, 'Lượt gửi', [
    ('Mã', 'id', 8), ('Thẻ', 'card', null), ('Loại vé', 'kind', null), ('Biển vào', 'plateIn', null),
    ('Biển ra', 'plateOut', null), ('Giờ vào', 'timeIn', 20), ('Giờ ra', 'timeOut', 20), ('Phí (đ)', 'fee', null),
    ('Bảo vệ mở tay', 'guard', 16),
  ], [
    for (final s in sessions)
      {
        'id': s['id'], 'card': s['card_uid'], 'kind': s['card_kind'] == 'monthly' ? 'Vé tháng' : 'Vé lượt',
        'plateIn': s['plate_in'], 'plateOut': s['plate_out'], 'timeIn': _local(s['time_in']),
        'timeOut': s['time_out'] == null ? 'Đang gửi' : _local(s['time_out']), 'fee': s['fee'],
        'guard': s['override_name'] ?? '',
      }
  ]);

  _addSheet(wb, 'Bảng công', [
    ('Bảo vệ', 'name', 22), ('Số ca', 'shifts', null), ('Giờ làm', 'hours', null), ('Số lần trễ', 'lateCount', null),
    ('Phút trễ', 'lateMin', null), ('Số lần về sớm', 'earlyCount', null), ('Phút về sớm', 'earlyMin', null),
    ('Quên chấm ra', 'missingOut', null),
  ], [for (final g in summarize(attendance)) {...g, 'hours': _hours(g['workedMin'])}]);

  _addSheet(wb, 'Chi tiết chấm công', [
    ('Bảo vệ', 'name', 22), ('Ca', 'shift', null), ('Vào', 'in', 20), ('Ra', 'out', 20), ('Trễ (phút)', 'late', null),
    ('Về sớm (phút)', 'early', null), ('Giờ làm', 'hours', null), ('Cách chấm', 'method', null),
  ], [
    for (final a in attendance)
      if (attStat(a) case final s)
        {
          'name': a['guard_name'], 'shift': a['shift_name'] ?? 'Ngoài ca', 'in': _local(a['time_in']),
          'out': s['open'] == true ? 'Đang trực' : s['missingOut'] == true ? 'Quên chấm ra' : _local(a['time_out']),
          'late': s['lateMin'], 'early': s['earlyMin'], 'hours': _hours(s['workedMin']),
          'method': a['method_in'] == 'pin' ? 'PIN' : 'Vân tay',
        }
  ]);
  wb.setDefaultSheet('Doanh thu');
  return wb.encode()!;
}

void reportRoutes(Router router) {
  router.get('/reports/monthly.xlsx', (req) async {
    final month = str(req.query['month']);
    if (!_monthRe.hasMatch(month)) throw HttpError(400, 'Tháng dạng YYYY-MM');
    return Response.ok(await monthlyWorkbook(month), headers: {
      'content-type': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'content-disposition': 'attachment; filename="bao-cao-$month.xlsx"',
    });
  });
}
