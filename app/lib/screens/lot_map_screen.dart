import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../lot.dart';
import '../main.dart';
import 'dashboard_screen.dart' show hhmm;

const _refreshEvery = Duration(seconds: 10);

/// Sơ đồ bãi cho quản lý: xem ô trống / ô cư dân / ô có xe, thêm / sửa / xoá khu, gán ô cho cư dân, khoá ô.
class LotMapScreen extends StatefulWidget {
  const LotMapScreen({super.key});

  @override
  State<LotMapScreen> createState() => _LotMapScreenState();
}

class _LotMapScreenState extends State<LotMapScreen> {
  Rec? map;
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

  Future<void> _editZone([Rec? z]) async {
    final types = await vehicleTypes();
    if (!mounted) return;
    final name = TextEditingController(text: z?['name'] as String?);
    final rows = TextEditingController(text: '${z?['rows'] ?? 2}');
    final cols = TextEditingController(text: '${z?['cols'] ?? 5}');
    final order = TextEditingController(text: '${z?['order'] ?? ((map?['zones'] as List?)?.length ?? 0) + 1}');
    var type = z?['vehicle_type'] as String? ?? 'motorbike';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(z == null ? 'Thêm khu' : 'Sửa khu ${z['name']}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: name,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'Tên khu (VD: A, B1)', prefixIcon: Icon(Icons.grid_view)),
              ),
              fieldGap,
              DropdownButtonFormField<String>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Loại xe', prefixIcon: Icon(Icons.commute)),
                items: [for (final t in types) DropdownMenuItem(value: t['code'] as String, child: Text(t['name'] as String))],
                onChanged: (v) => setD(() => type = v!),
              ),
              fieldGap,
              Row(children: [
                Expanded(child: TextField(controller: rows, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Số hàng'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: cols, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Số ô mỗi hàng'))),
              ]),
              fieldGap,
              TextField(
                controller: order,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Thứ tự gần cổng', helperText: '1 = gần cổng nhất, khách được chỉ vào khu này trước'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lưu')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final body = {
      'name': name.text.trim().toUpperCase(),
      'vehicleType': type,
      'rows': int.tryParse(rows.text.trim()),
      'cols': int.tryParse(cols.text.trim()),
      'order': int.tryParse(order.text.trim()) ?? 0,
    };
    await _run(() => z == null ? api.post('/zones', body) : api.put('/zones/${z['id']}', body),
        z == null ? 'Đã thêm khu, các ô được tạo tự động' : 'Đã lưu khu');
  }

  Future<void> _zoneMenu(Rec z) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.edit_outlined), title: Text('Sửa khu ${z['name']}'), onTap: () => Navigator.pop(c, 'edit')),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Theme.of(c).colorScheme.error),
            title: Text('Xoá khu ${z['name']}', style: TextStyle(color: Theme.of(c).colorScheme.error)),
            subtitle: const Text('Chỉ xoá được khi không có xe và không có ô cư dân'),
            onTap: () => Navigator.pop(c, 'delete'),
          ),
        ]),
      ),
    );
    if (action == 'edit') return _editZone(z);
    if (action == 'delete') await _run(() => api.delete('/zones/${z['id']}'), 'Đã xoá khu ${z['name']}');
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
            title: Text('Ô ${sl['code']} · ${slotStateNames[state]}', style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              if (sl['plate'] != null) 'Xe ${sl['plate']} vào ${hhmm(sl['since'] as String?)}',
              if (sl['card_uid'] != null) 'Cư dân ${sl['owner'] ?? ''} · căn ${sl['apartment'] ?? '?'} · biển ${sl['resident_plate'] ?? '?'}',
              if (sl['card_uid'] == null) 'Ô cho khách vãng lai',
            ].join('\n')),
            isThreeLine: true,
          ),
          const Divider(),
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
      case 'assign':
        await _assign(sl);
      case 'free':
        await _run(() => api.patch('/slots/${sl['code']}', {'cardUid': null}), 'Đã bỏ gán ô ${sl['code']}');
      case 'toggle':
        await _run(() => api.patch('/slots/${sl['code']}', {'active': sl['active'] != true}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final m = map;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editZone(),
        icon: const Icon(Icons.add),
        label: const Text('Thêm khu'),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          Text('Sơ đồ bãi', style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          Text('Chạm ô để gán cho cư dân / khoá ô, chạm tên khu để sửa. Khách vãng lai được API chỉ vào ô xanh gần cổng nhất.',
              style: t.bodySmall),
          const SizedBox(height: 12),
          if (m == null) const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator())) else ...[
            _TypeSummary(m),
            const SizedBox(height: 12),
            LotMapView(m, onSlot: _slotSheet, onZone: _zoneMenu),
          ],
        ]),
      ),
    );
  }
}

/// Mỗi loại xe: còn trống bao nhiêu ô / tổng, bao nhiêu ô dành cho khách.
class _TypeSummary extends StatelessWidget {
  const _TypeSummary(this.map);

  final Rec map;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final by = <String, ({int total, int free, int visitor})>{};
    for (final z in (map['zones'] as List).cast<Rec>()) {
      final code = z['vehicle_type'] as String;
      var x = by[code] ?? (total: 0, free: 0, visitor: 0);
      for (final sl in (z['slots'] as List).cast<Rec>()) {
        if (sl['state'] == 'off') continue;
        x = (total: x.total + 1, free: x.free + (sl['state'] != 'parked' ? 1 : 0), visitor: x.visitor + (sl['state'] == 'free' ? 1 : 0));
      }
      by[code] = x;
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final e in by.entries)
        Chip(
          avatar: Icon(vehicleIcon(e.key), size: 18, color: s.primary),
          label: Text('${vehicleName(e.key)}: ${e.value.visitor} ô khách trống · ${e.value.total} ô'),
        ),
    ]);
  }
}
