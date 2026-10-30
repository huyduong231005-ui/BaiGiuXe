import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../lot.dart';
import '../main.dart';

/// Mặt bằng mẫu cho bãi chung cư (trùng sampleLayout ở backend/lib/src/layout.dart): lối vào / ra ở tường trên,
/// khu A, B xe máy, C ô tô, D xe đạp; đường 1 chiều từ cổng vào chạy vòng tới cổng ra.
const sampleLayout = [
  '##I################O##',
  '#VVAAAAAAAAAAAAAAAA^^#',
  '#VV>>>>>>>>>>>>>>>>^^#',
  '#VVBBBBBBBBBBBBBBBB^^#',
  '#VVBBBBBBBBBBBBBBBB^^#',
  '#VV>>>>>>>>>>>>>>>>^^#',
  '#VVCCCCCCCC.DDDDDDD^^#',
  '######################',
];

const _maxSize = 40;

/// Vẽ mặt bằng bãi: chọn cọ rồi chạm / kéo trên lưới. API kiểm tra lối vào, lối ra và đường xe tới mọi ô khi lưu.
class LayoutEditorScreen extends StatefulWidget {
  const LayoutEditorScreen({super.key, required this.map});

  final Rec map; // GET /lot/map lúc mở màn

  @override
  State<LayoutEditorScreen> createState() => _LayoutEditorScreenState();
}

class _LayoutEditorScreenState extends State<LayoutEditorScreen> {
  late List<List<String>> grid = _toGrid((widget.map['layout'] as List).cast<String>());
  late List<Rec> zones = (widget.map['zones'] as List).cast<Rec>();
  String brush = '=';
  bool saving = false;
  String? error;

  static List<List<String>> _toGrid(List<String> layout) => layout.isEmpty
      ? [
          for (var r = 0; r < 10; r++)
            [for (var c = 0; c < 20; c++) r == 0 || r == 9 || c == 0 || c == 19 ? '#' : '.'],
        ]
      : [for (final l in layout) l.split('')];

  List<String> get _layout => [for (final r in grid) r.join()];

  void _paint(Offset p, double cell) {
    final r = (p.dy / cell).floor(), c = (p.dx / cell).floor();
    if (r < 0 || r >= grid.length || c < 0 || c >= grid[0].length || grid[r][c] == brush) return;
    setState(() => grid[r][c] = brush);
  }

  void _resize({int rows = 0, int cols = 0}) {
    final h = (grid.length + rows).clamp(3, _maxSize), w = (grid[0].length + cols).clamp(3, _maxSize);
    setState(() {
      grid = [
        for (var r = 0; r < h; r++) [for (var c = 0; c < w; c++) r < grid.length && c < grid[0].length ? grid[r][c] : '#'],
      ];
    });
  }

  Future<void> _addZone() async {
    final types = await vehicleTypes();
    if (!mounted) return;
    final used = zones.map((z) => z['name']).toSet();
    final free = [for (final ch in 'ABCDEFGHJKLMNPQRSTUWXYZ'.split('')) if (!used.contains(ch)) ch];
    var name = free.first;
    var type = 'motorbike';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: const Text('Thêm khu'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: name,
              decoration: const InputDecoration(labelText: 'Tên khu (chữ dùng để vẽ ô)'),
              items: [for (final ch in free) DropdownMenuItem(value: ch, child: Text('Khu $ch'))],
              onChanged: (v) => setD(() => name = v!),
            ),
            fieldGap,
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Loại xe'),
              items: [for (final t in types) DropdownMenuItem(value: t['code'] as String, child: Text(t['name'] as String))],
              onChanged: (v) => setD(() => type = v!),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Thêm')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final z = await api.post('/zones', {'name': name, 'vehicleType': type}) as Rec;
      setState(() {
        zones = [...zones, {...z, 'slots': const []}];
        brush = name;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _zoneMenu(Rec z) async {
    final used = grid.any((r) => r.contains(z['name']));
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Xoá khu ${z['name']}?'),
        content: Text(used ? 'Khu còn ô trên mặt bằng: vẽ đè các ô đó bằng Đường / Trống rồi Lưu trước.' : 'Khu chưa có ô nào.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Đóng')),
          if (!used) FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/zones/${z['id']}');
      setState(() {
        zones = zones.where((x) => x['id'] != z['id']).toList();
        if (brush == z['name']) brush = '=';
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _useSample() async {
    final missing = [for (final ch in ['A', 'B', 'C', 'D']) if (!zones.any((z) => z['name'] == ch)) ch];
    if (missing.isNotEmpty) {
      const types = {'A': 'motorbike', 'B': 'motorbike', 'C': 'car', 'D': 'bicycle'};
      try {
        for (final ch in missing) {
          final z = await api.post('/zones', {'name': ch, 'vehicleType': types[ch]}) as Rec;
          zones = [...zones, {...z, 'slots': const []}];
        }
      } catch (e) {
        if (mounted) showError(context, e);
        return;
      }
    }
    setState(() => grid = _toGrid(sampleLayout));
  }

  Future<void> _save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await api.put('/lot/layout', {'layout': _layout});
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final zoneType = {for (final z in zones) z['name'] as String: z['vehicle_type'] as String};
    final brushes = <(String, String, Color)>[
      ('=', 'Đường 2 chiều', LotPainter.asphalt),
      ('>', '1 chiều →', LotPainter.asphalt),
      ('<', '1 chiều ←', LotPainter.asphalt),
      ('^', '1 chiều ↑', LotPainter.asphalt),
      ('V', '1 chiều ↓', LotPainter.asphalt),
      ('#', 'Tường', LotPainter.wall),
      ('.', 'Trống / cột', LotPainter.green),
      ('I', 'Lối vào', Colors.green.shade700),
      ('O', 'Lối ra', Colors.red.shade700),
      for (final z in zones) (z['name'] as String, 'Khu ${z['name']} · ${vehicleName(z['vehicle_type'] as String?)}', Colors.green),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sửa mặt bằng'),
        actions: [
          TextButton(onPressed: saving ? null : _save, child: saving ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Lưu')),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          Text('Chọn cọ rồi chạm hoặc kéo ngón tay trên lưới. Ô đậu vẽ bằng chữ của khu, phải nằm sát đường đi; '
              'cần ít nhất 1 lối vào và 1 lối ra ở mép bãi. Đường 1 chiều: xe chỉ chạy theo mũi tên, chỉ đường cũng theo mũi tên.', style: t.bodySmall),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (ch, label, color) in brushes)
              GestureDetector(
                onLongPress: zoneType.containsKey(ch) ? () => _zoneMenu(zones.firstWhere((z) => z['name'] == ch)) : null,
                child: ChoiceChip(
                  selected: brush == ch,
                  onSelected: (_) => setState(() => brush = ch),
                  avatar: Container(width: 14, height: 14, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
                  label: Text(label),
                ),
              ),
            ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Thêm khu'), onPressed: _addZone),
          ]),
          const SizedBox(height: 4),
          Text('Nhấn giữ một khu để xoá khu.', style: t.labelSmall?.copyWith(color: s.onSurfaceVariant)),
          const SizedBox(height: 10),
          LayoutBuilder(builder: (context, box) {
            final cell = box.maxWidth / grid[0].length;
            // Kéo dọc / ngang riêng (không dùng pan) để thắng cuộn của ListView: vẽ được bằng cách kéo ngón tay.
            return GestureDetector(
              onTapDown: (d) => _paint(d.localPosition, cell),
              onVerticalDragStart: (d) => _paint(d.localPosition, cell),
              onVerticalDragUpdate: (d) => _paint(d.localPosition, cell),
              onHorizontalDragStart: (d) => _paint(d.localPosition, cell),
              onHorizontalDragUpdate: (d) => _paint(d.localPosition, cell),
              child: CustomPaint(
                size: Size(box.maxWidth, cell * grid.length),
                painter: LotPainter(layout: _layout, slots: const {}, zoneType: zoneType, scheme: s, grid: true),
              ),
            );
          }),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            OutlinedButton.icon(onPressed: () => _resize(rows: 1), icon: const Icon(Icons.add), label: Text('Hàng (${grid.length})')),
            OutlinedButton.icon(onPressed: () => _resize(rows: -1), icon: const Icon(Icons.remove), label: const Text('Hàng')),
            OutlinedButton.icon(onPressed: () => _resize(cols: 1), icon: const Icon(Icons.add), label: Text('Cột (${grid[0].length})')),
            OutlinedButton.icon(onPressed: () => _resize(cols: -1), icon: const Icon(Icons.remove), label: const Text('Cột')),
            TextButton.icon(onPressed: _useSample, icon: const Icon(Icons.auto_awesome), label: const Text('Dùng mặt bằng mẫu')),
          ]),
          if (error != null)
            Card(
              color: s.errorContainer,
              margin: const EdgeInsets.only(top: 12),
              child: ListTile(leading: Icon(Icons.error_outline, color: s.onErrorContainer), title: Text(error!, style: TextStyle(color: s.onErrorContainer))),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: saving ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Lưu mặt bằng')),
        ]),
      ),
    );
  }
}
