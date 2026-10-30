import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../lot.dart';
import '../main.dart';
import 'dashboard_screen.dart' show hhmm;
import 'layout_editor_screen.dart';

const _refreshEvery = Duration(seconds: 10);

/// Sơ đồ bãi cho quản lý: mặt bằng thật (cổng, đường, khu), trạng thái từng ô, đường từ cổng tới ô,
/// gán ô cho cư dân, khoá ô, sửa mặt bằng.
class LotMapScreen extends StatefulWidget {
  const LotMapScreen({super.key});

  @override
  State<LotMapScreen> createState() => _LotMapScreenState();
}

class _LotMapScreenState extends State<LotMapScreen> {
  Rec? map;
  Rec? route; // đường tới ô đang chọn (GET /lot/route)
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _reload();
    timer = Timer.periodic(_refreshEvery, (_) => _reload(quiet: true));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _reload({bool quiet = false}) async {
    try {
      await vehicleTypes();
      final m = await api.get('/lot/map') as Rec;
      if (mounted) setState(() => map = m);
    } catch (e) {
      if (mounted && !quiet) showError(context, e);
    }
  }

  Future<void> _run(Future<void> Function() action, [String? done]) async {
    try {
      await action();
      if (done != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(done)));
      await _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _showRoute(Rec sl) async {
    try {
      final r = await api.get('/lot/route', {'slot': sl['code'] as String}) as Rec;
      if (mounted) setState(() => route = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _assign(Rec slot) async {
    final cards = ((await api.get('/cards')) as List)
        .cast<Rec>()
        .where((c) => c['kind'] == 'monthly' && (c['vehicle_type'] ?? 'motorbike') == slot['vehicle_type'])
        .toList();
    if (!mounted) return;
    final uid = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            ListTile(title: Text('Gán ô ${slot['code']} cho thẻ tháng (${vehicleName(slot['vehicle_type'] as String?)})')),
            if (cards.isEmpty) const ListTile(title: Text('Chưa có thẻ tháng nào cùng loại xe')),
            for (final card in cards)
              ListTile(
                leading: Icon(vehicleIcon(card['vehicle_type'] as String?)),
                title: Text('${card['plate'] ?? card['uid']} · ${card['apartment'] ?? 'chưa ghi căn hộ'}'),
                subtitle: Text([card['owner'], if (card['slot_code'] != null) 'đang giữ ô ${card['slot_code']}'].whereType<String>().join(' · ')),
                onTap: () => Navigator.pop(c, card['uid'] as String),
              ),
          ]),
        ),
      ),
    );
    if (uid != null) await _run(() => api.patch('/slots/${slot['code']}', {'cardUid': uid}), 'Đã gán ô ${slot['code']}');
  }

  Future<void> _slotSheet(Rec sl) async {
    final s = Theme.of(context).colorScheme;
    final state = sl['state'] as String;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ListTile(
            leading: CircleAvatar(backgroundColor: slotColor(s, state), child: Icon(vehicleIcon(sl['vehicle_type'] as String?), color: s.surface)),
            title: Text('Ô ${sl['code']} · ${vehicleName(sl['vehicle_type'] as String?)} · ${slotStateNames[state]}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              if (sl['plate'] != null) 'Xe ${sl['plate']} vào ${hhmm(sl['since'] as String?)}',
              if (sl['card_uid'] != null) 'Cư dân ${sl['owner'] ?? ''} · căn ${sl['apartment'] ?? '?'} · biển ${sl['resident_plate'] ?? '?'}',
              if (sl['card_uid'] == null) 'Ô cho khách vãng lai',
            ].join('\n')),
            isThreeLine: true,
          ),
          const Divider(),
          ListTile(leading: const Icon(Icons.route), title: const Text('Xem đường từ cổng vào tới ô'), onTap: () => Navigator.pop(c, 'route')),
          ListTile(leading: const Icon(Icons.person_add_alt), title: const Text('Gán cho cư dân (thẻ tháng)'), onTap: () => Navigator.pop(c, 'assign')),
          if (sl['card_uid'] != null)
            ListTile(leading: const Icon(Icons.person_remove_outlined), title: const Text('Bỏ gán, trả ô cho khách vãng lai'), onTap: () => Navigator.pop(c, 'free')),
          ListTile(
            leading: Icon(sl['active'] == true ? Icons.block : Icons.check_circle_outline),
            title: Text(sl['active'] == true ? 'Tạm khoá ô (sửa chữa, vật cản...)' : 'Mở lại ô'),
            onTap: () => Navigator.pop(c, 'toggle'),
          ),
        ]),
      ),
    );
    switch (action) {
      case 'route':
        await _showRoute(sl);
      case 'assign':
        await _assign(sl);
      case 'free':
        await _run(() => api.patch('/slots/${sl['code']}', {'cardUid': null}), 'Đã bỏ gán ô ${sl['code']}');
      case 'toggle':
        await _run(() => api.patch('/slots/${sl['code']}', {'active': sl['active'] != true}));
    }
  }

  Future<void> _edit() async {
    final m = map;
    if (m == null) return;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => LayoutEditorScreen(map: m)));
    if (saved == true) {
      setState(() => route = null);
      _reload();
    }
  }

  void _help() => showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Sơ đồ bãi'),
          content: const Text('Chạm ô để xem đường từ cổng vào, gán ô cho cư dân hoặc khoá ô.\n\n'
              'Khách vãng lai quẹt thẻ ở cổng được API chỉ ô trống gần cổng vào nhất theo quãng đường xe chạy, '
              'đúng loại xe, không đụng ô cư dân.\n\nDùng 2 ngón tay để phóng to, kéo để di chuyển.'),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Đã hiểu'))],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final m = map;
    final r = route;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Đầu trang 1 dòng: tiêu đề + chỗ trống cho khách theo loại xe (chữ nhỏ) + nút
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
        child: Row(children: [
          Text('Sơ đồ', style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(width: 10),
          Expanded(child: m == null ? const SizedBox.shrink() : _TypeSummary(m)),
          IconButton(onPressed: _help, icon: const Icon(Icons.info_outline), tooltip: 'Hướng dẫn', visualDensity: VisualDensity.compact),
          IconButton(onPressed: _edit, icon: const Icon(Icons.edit_outlined), tooltip: 'Sửa mặt bằng', visualDensity: VisualDensity.compact),
        ]),
      ),
      // Mặt bằng chiếm toàn bộ phần còn lại
      Expanded(
        child: m == null
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: LotPlanView(m,
                    onSlot: _slotSheet,
                    route: cellsFrom(r?['path']),
                    exitRoute: cellsFrom(r?['exitPath']),
                    highlight: r?['slot'] as String?),
              ),
      ),
      if (r != null)
        Material(
          color: s.primaryContainer,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.route, color: s.onPrimaryContainer),
            title: Text('Ô ${r['slot']} · ${r['distance']} ô từ cổng', style: TextStyle(color: s.onPrimaryContainer, fontWeight: FontWeight.w600)),
            subtitle: Text(r['hint'] as String, style: TextStyle(color: s.onPrimaryContainer, fontSize: 12)),
            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => route = null)),
          ),
        ),
      Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 6), child: LotLegend(withRoute: r != null)),
    ]);
  }
}

/// Mỗi loại xe: bao nhiêu ô khách còn trống / tổng số ô.
class _TypeSummary extends StatelessWidget {
  const _TypeSummary(this.map);

  final Rec map;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final by = <String, ({int total, int visitor})>{};
    for (final z in (map['zones'] as List).cast<Rec>()) {
      final code = z['vehicle_type'] as String;
      var x = by[code] ?? (total: 0, visitor: 0);
      for (final sl in (z['slots'] as List).cast<Rec>()) {
        if (sl['state'] == 'off') continue;
        x = (total: x.total + 1, visitor: x.visitor + (sl['state'] == 'free' ? 1 : 0));
      }
      by[code] = x;
    }
    final t = Theme.of(context).textTheme;
    return Text(
      'Trống cho khách: ${[for (final e in by.entries) '${vehicleName(e.key).toLowerCase()} ${e.value.visitor}/${e.value.total}'].join(' · ')}',
      style: t.labelSmall?.copyWith(color: s.onSurfaceVariant),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
