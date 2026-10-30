import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'api.dart';
import 'logic.dart';

/// Loại xe + bảng giá từ API (GET /vehicle-types), nhớ trong phiên chạy app. Sửa giá xong gọi [reloadVehicleTypes].
List<Rec>? _types;

Future<List<Rec>> vehicleTypes({bool reload = false}) async {
  if (_types == null || reload) _types = ((await api.get('/vehicle-types')) as List).cast<Rec>();
  return _types!;
}

Future<List<Rec>> reloadVehicleTypes() => vehicleTypes(reload: true);

const _names = {'motorbike': 'Xe máy', 'car': 'Ô tô', 'bicycle': 'Xe đạp'};

String vehicleName(String? code) =>
    _types?.firstWhere((t) => t['code'] == code, orElse: () => const {})['name'] as String? ?? _names[code] ?? code ?? 'Xe máy';

IconData vehicleIcon(String? code) => switch (code) {
      'car' => Icons.directions_car,
      'bicycle' => Icons.pedal_bike,
      _ => Icons.two_wheeler,
    };

/// "1.500.000đ"
String vnd(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '$bđ';
}

/// Màu từng trạng thái ô: trống (khách vãng lai), ô riêng cư dân (đang trống), có xe, tạm khoá.
Color slotColor(ColorScheme s, String state) => switch (state) {
      'parked' => s.error,
      'resident' => s.tertiary,
      'off' => s.outline,
      _ => Colors.green,
    };

const slotStateNames = {'free': 'Trống', 'resident': 'Ô cư dân', 'parked': 'Có xe', 'off': 'Tạm khoá'};

typedef Cell = (int, int);

/// Đường đi từ API ([[hàng, cột], ...]) -> danh sách ô.
List<Cell> cellsFrom(Object? path) => [for (final p in (path as List? ?? const [])) ((p as List)[0] as int, p[1] as int)];

/// Xoay mặt bằng 90° theo chiều kim đồng hồ: ô (hàng r, cột c) -> (c, số hàng - 1 - r).
/// Dùng khi bãi nằm ngang mà màn hình đứng (ô to hơn, dễ nhìn hơn); chữ vẫn vẽ đứng thẳng.
({List<String> layout, Map<String, Rec> slots, List<Cell> route, List<Cell> exitRoute}) rotatePlan(
    List<String> layout, Map<String, Rec> slots, List<Cell> route, List<Cell> exitRoute) {
  final rows = layout.length, cols = layout[0].length;
  Cell rot(Cell p) => (p.$2, rows - 1 - p.$1);
  return (
    layout: [for (var i = 0; i < cols; i++) String.fromCharCodes([for (var j = 0; j < rows; j++) layout[rows - 1 - j].codeUnitAt(i)])],
    slots: {
      for (final e in slots.entries)
        () {
          final p = e.key.split(',').map(int.parse).toList();
          final q = rot((p[0], p[1]));
          return '${q.$1},${q.$2}';
        }(): e.value,
    },
    route: route.map(rot).toList(),
    exitRoute: exitRoute.map(rot).toList(),
  );
}

/// Mặt bằng bãi vẽ như thật: tường, đường nhựa có vạch giữa làn, cổng VÀO / RA, vạch kẻ ô đậu tô màu theo trạng thái,
/// tên khu, và đường dẫn từ cổng tới ô (route) + từ ô ra cổng (exitRoute). Tự xoay để ô to nhất trong khung,
/// phóng to / kéo bằng ngón tay.
class LotPlanView extends StatelessWidget {
  const LotPlanView(this.map,
      {super.key, this.route = const [], this.exitRoute = const [], this.highlight, this.onSlot, this.zoomable = true, this.maxHeight});

  final Rec map; // GET /lot/map hoặc /lot/map/public
  final List<Cell> route, exitRoute;
  final String? highlight;
  final void Function(Rec slot)? onSlot;
  final bool zoomable;
  final double? maxHeight; // giới hạn chiều cao khi đặt trong danh sách cuộn

  @override
  Widget build(BuildContext context) {
    final layout0 = (map['layout'] as List? ?? const []).cast<String>();
    if (layout0.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: Text('Chưa vẽ mặt bằng bãi', textAlign: TextAlign.center));
    }
    final slots0 = <String, Rec>{};
    final zoneType = <String, String>{};
    for (final z in (map['zones'] as List).cast<Rec>()) {
      zoneType[z['name'] as String] = z['vehicle_type'] as String;
      for (final s in (z['slots'] as List).cast<Rec>()) {
        slots0['${s['row']},${s['col']}'] = s;
      }
    }
    return LayoutBuilder(builder: (context, box) {
      final h = maxHeight ?? (box.maxHeight.isFinite ? box.maxHeight : double.infinity);
      double cellFor(int rows, int cols) => math.min(box.maxWidth / cols, h / rows);
      final r0 = layout0.length, c0 = layout0[0].length;
      final turn = cellFor(c0, r0) > cellFor(r0, c0) * 1.15; // xoay nếu ô to hơn rõ rệt
      final p = turn ? rotatePlan(layout0, slots0, route, exitRoute) : (layout: layout0, slots: slots0, route: route, exitRoute: exitRoute);
      final rows = p.layout.length, cols = p.layout[0].length;
      final cell = cellFor(rows, cols);
      final size = Size(cell * cols, cell * rows);
      final painted = GestureDetector(
        onTapUp: onSlot == null
            ? null
            : (d) {
                final s = p.slots['${(d.localPosition.dy / cell).floor()},${(d.localPosition.dx / cell).floor()}'];
                if (s != null) onSlot!(s);
              },
        child: CustomPaint(
          size: size,
          painter: LotPainter(
            layout: p.layout,
            slots: p.slots,
            zoneType: zoneType,
            route: p.route,
            exitRoute: p.exitRoute,
            highlight: highlight,
            scheme: Theme.of(context).colorScheme,
          ),
        ),
      );
      return Center(
        child: SizedBox.fromSize(size: size, child: zoomable ? InteractiveViewer(maxScale: 5, child: painted) : painted),
      );
    });
  }
}

class LotPainter extends CustomPainter {
  LotPainter({
    required this.layout,
    required this.slots,
    required this.zoneType,
    required this.scheme,
    this.route = const [],
    this.exitRoute = const [],
    this.highlight,
    this.grid = false,
  });

  final List<String> layout;
  final Map<String, Rec> slots; // "hàng,cột" -> ô (mã, trạng thái)
  final Map<String, String> zoneType; // chữ khu -> loại xe
  final ColorScheme scheme;
  final List<Cell> route, exitRoute;
  final String? highlight;
  final bool grid; // màn sửa mặt bằng: kẻ lưới mờ

  static const asphalt = Color(0xFF4A4F57), wall = Color(0xFF26292E), green = Color(0xFF33372F); // green: chỗ trống / cột

  String at(int r, int c) => r < 0 || r >= layout.length || c < 0 || c >= layout[0].length ? '#' : layout[r][c];
  bool road(int r, int c) => const {'=', 'I', 'O'}.contains(at(r, c));

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / layout[0].length;
    Rect rect(int r, int c) => Rect.fromLTWH(c * cell, r * cell, cell, cell);
    Offset center((int, int) p) => Offset((p.$2 + 0.5) * cell, (p.$1 + 0.5) * cell);
    final fill = Paint();

    // Nền: tường, chỗ trống (cột / bồn cây), đường nhựa, cổng
    for (var r = 0; r < layout.length; r++) {
      for (var c = 0; c < layout[0].length; c++) {
        final ch = layout[r][c];
        fill.color = switch (ch) {
          '#' => wall,
          '.' => green,
          'I' => Colors.green.shade700,
          'O' => Colors.red.shade700,
          _ => asphalt,
        };
        canvas.drawRect(rect(r, c), fill);
      }
    }
    // Vạch giữa làn: nét đứt trắng trên đoạn đường thẳng
    final lane = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = math.max(1, cell * 0.06);
    for (var r = 0; r < layout.length; r++) {
      for (var c = 0; c < layout[0].length; c++) {
        if (at(r, c) != '=') continue;
        final m = center((r, c));
        if (road(r, c - 1) && road(r, c + 1) && !road(r - 1, c)) {
          canvas.drawLine(m - Offset(cell * 0.2, 0), m + Offset(cell * 0.2, 0), lane);
        } else if (road(r - 1, c) && road(r + 1, c) && !road(r, c - 1)) {
          canvas.drawLine(m - Offset(0, cell * 0.2), m + Offset(0, cell * 0.2), lane);
        }
      }
    }
    // Ô đậu: tô theo trạng thái, vạch trắng ngăn ô, số ô
    final lines = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, cell * 0.05);
    for (var r = 0; r < layout.length; r++) {
      for (var c = 0; c < layout[0].length; c++) {
        final ch = layout[r][c];
        if (!RegExp('[A-Z]').hasMatch(ch) || ch == 'I' || ch == 'O') continue;
        final s = slots['$r,$c'];
        final box = rect(r, c).deflate(cell * 0.06);
        fill.color = slotColor(scheme, s?['state'] as String? ?? 'free').withValues(alpha: 0.85);
        canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(cell * 0.12)), fill);
        canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(cell * 0.12)), lines);
        final label = s == null ? ch : (s['code'] as String).split('-').last;
        if (cell >= 12) _text(canvas, label, box.center, cell * 0.42, Colors.white, bold: true);
      }
    }
    // Tên khu: chữ lớn mờ ở giữa khu, kèm loại xe
    final bounds = <String, Rect>{};
    for (var r = 0; r < layout.length; r++) {
      for (var c = 0; c < layout[0].length; c++) {
        final ch = layout[r][c];
        if (!zoneType.containsKey(ch)) continue;
        bounds[ch] = bounds[ch]?.expandToInclude(rect(r, c)) ?? rect(r, c);
      }
    }
    for (final e in bounds.entries) {
      final b = e.value;
      // Khu hẹp (1-2 cột, hay gặp khi mặt bằng bị xoay) chỉ ghi chữ cái, căn giữa trên khu: không tràn sang ô cổng bên cạnh.
      _text(canvas, b.width >= cell * 2.5 ? 'Khu ${e.key}' : e.key, Offset(b.center.dx, b.top - cell * 0.32), cell * 0.5,
          Colors.white.withValues(alpha: 0.9), bold: true);
    }
    // Cổng
    for (final (ch, label) in [('I', 'VÀO'), ('O', 'RA')]) {
      for (var r = 0; r < layout.length; r++) {
        for (var c = 0; c < layout[0].length; c++) {
          // Nâng chữ lên nửa trên ô cổng để không đè chữ tên khu bên cạnh
          if (layout[r][c] == ch) _text(canvas, label, rect(r, c).center - Offset(0, cell * 0.22), cell * 0.34, Colors.white, bold: true);
        }
      }
    }
    if (grid) {
      final g = Paint()
        ..color = Colors.white.withValues(alpha: 0.12)
        ..strokeWidth = 1;
      for (var r = 0; r <= layout.length; r++) {
        canvas.drawLine(Offset(0, r * cell), Offset(size.width, r * cell), g);
      }
      for (var c = 0; c <= layout[0].length; c++) {
        canvas.drawLine(Offset(c * cell, 0), Offset(c * cell, size.height), g);
      }
    }
    // Đường ra (nét đứt cam) rồi đường vào (xanh đậm, mũi tên ở ô cần đỗ)
    _path(canvas, exitRoute, center, cell, Colors.orange.shade400, dashed: true);
    _path(canvas, route, center, cell, Colors.lightBlueAccent);
    // Ô cần chỉ: viền dày nhấp nháy tĩnh
    for (final e in slots.entries) {
      if (e.value['code'] != highlight) continue;
      final p = e.key.split(',').map(int.parse).toList();
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect(p[0], p[1]).inflate(cell * 0.08), Radius.circular(cell * 0.2)),
        Paint()
          ..color = Colors.yellowAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2, cell * 0.14),
      );
    }
  }

  void _path(Canvas canvas, List<Cell> cells, Offset Function((int, int)) center, double cell, Color color, {bool dashed = false}) {
    if (cells.length < 2) return;
    final pts = [for (final p in cells) center(p)];
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = math.max(3, cell * (dashed ? 0.16 : 0.26));
    if (dashed) {
      for (var i = 1; i < pts.length; i++) {
        if (i.isOdd) canvas.drawLine(pts[i - 1], pts[i], stroke);
      }
    } else {
      canvas.drawPath(Path()..addPolygon(pts, false), stroke);
    }
    // Mũi tên ở cuối
    final a = pts[pts.length - 2], b = pts.last;
    final ang = math.atan2(b.dy - a.dy, b.dx - a.dx);
    final len = cell * 0.55;
    final head = Path()
      ..moveTo(b.dx, b.dy)
      ..lineTo(b.dx - len * math.cos(ang - 0.5), b.dy - len * math.sin(ang - 0.5))
      ..lineTo(b.dx - len * math.cos(ang + 0.5), b.dy - len * math.sin(ang + 0.5))
      ..close();
    canvas.drawPath(head, Paint()..color = color);
  }

  void _text(Canvas canvas, String s, Offset at, double size, Color color, {bool bold = false, bool alignLeft = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.bold : null)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, alignLeft ? at - Offset(0, tp.height / 2) : at - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  bool shouldRepaint(LotPainter old) =>
      old.layout != layout || old.slots != slots || old.route != route || old.exitRoute != exitRoute ||
      old.highlight != highlight || old.scheme != scheme || old.grid != grid;
}

/// Chú thích màu dưới mặt bằng.
class LotLegend extends StatelessWidget {
  const LotLegend({super.key, this.withRoute = false});

  final bool withRoute;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    Widget dot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 9, height: 9, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 3),
          Text(label, style: t.labelSmall?.copyWith(fontSize: 10)),
        ]);
    return Wrap(spacing: 10, runSpacing: 2, alignment: WrapAlignment.center, children: [
      for (final e in slotStateNames.entries) dot(slotColor(s, e.key), e.value),
      dot(LotPainter.asphalt, 'Đường đi'),
      dot(Colors.green.shade700, 'Cổng vào'),
      dot(Colors.red.shade700, 'Cổng ra'),
      if (withRoute) ...[dot(Colors.lightBlueAccent, 'Đường tới ô'), dot(Colors.orange.shade400, 'Đường ra')],
    ]);
  }
}
