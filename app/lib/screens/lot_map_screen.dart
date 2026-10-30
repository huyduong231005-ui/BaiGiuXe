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

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final m = map;
    final r = route;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(child: Text('Sơ đồ bãi', style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
          FilledButton.tonalIcon(onPressed: _edit, icon: const Icon(Icons.edit_outlined), label: const Text('Sửa mặt bằng')),
        ]),
        Text('Chạm ô để xem đường từ cổng, gán cho cư dân hoặc khoá ô. Khách vãng lai được API chỉ ô trống gần cổng vào nhất '
            'theo quãng đường xe chạy. Dùng 2 ngón tay để phóng to.', style: t.bodySmall),
        const SizedBox(height: 12),
        if (m == null)
          const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
        else ...[
          _TypeSummary(m),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: LotPlanView(m,
                onSlot: _slotSheet,
                route: cellsFrom(r?['path']),
                exitRoute: cellsFrom(r?['exitPath']),
                highlight: r?['slot'] as String?),
          ),
          const SizedBox(height: 8),
          LotLegend(withRoute: r != null),
          if (r != null)
            Card(
              color: s.primaryContainer,
              margin: const EdgeInsets.only(top: 12),
              child: ListTile(
                leading: Icon(Icons.route, color: s.onPrimaryContainer),
                title: Text('Đường tới ô ${r['slot']} (${r['distance']} ô)', style: TextStyle(color: s.onPrimaryContainer, fontWeight: FontWeight.w600)),
                subtitle: Text(r['hint'] as String, style: TextStyle(color: s.onPrimaryContainer)),
                trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => route = null)),
              ),
            ),
        ],
      ]),
    );
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
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final e in by.entries)
        Chip(
          avatar: Icon(vehicleIcon(e.key), size: 18, color: s.primary),
          label: Text('${vehicleName(e.key)}: ${e.value.visitor} ô khách trống / ${e.value.total}'),
        ),
    ]);
  }
}
