import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic.dart';
import '../main.dart';

final _db = Supabase.instance.client;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onChangeRole});

  final VoidCallback onChangeRole;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final capacity = TextEditingController();
  final priceDay = TextEditingController();
  final priceNight = TextEditingController();
  final nightMark = TextEditingController();
  List<Rec> shifts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _db.from('settings').select().single();
      if (!mounted) return;
      setState(() {
        capacity.text = '${s['capacity']}';
        priceDay.text = '${s['price_day']}';
        priceNight.text = '${s['price_night']}';
        nightMark.text = (s['night_mark'] as String).substring(0, 5);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
    try {
      final sh = await _db.from('shift_defs').select().order('start_time');
      if (mounted) setState(() => shifts = sh);
    } catch (e) {
      debugPrint('[settings] chua co bang shift_defs (chay migration 0004): $e');
    }
  }

  /// Thêm / sửa một ca trực. Giờ kết thúc nhỏ hơn giờ bắt đầu = ca qua đêm.
  Future<void> _editShift([Rec? sh]) async {
    TimeOfDay parse(String? v, int defHour) {
      if (v == null) return TimeOfDay(hour: defHour, minute: 0);
      final p = v.split(':');
      return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
    }

    final name = TextEditingController(text: sh?['name'] as String?);
    var start = parse(sh?['start_time'] as String?, 6), end = parse(sh?['end_time'] as String?, 14);
    String fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setD) => AlertDialog(
          title: Text(sh == null ? 'Thêm ca' : 'Sửa ca'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Tên ca', prefixIcon: Icon(Icons.badge_outlined))),
            fieldGap,
            Row(children: [
              for (final (label, isStart) in [('Bắt đầu', true), ('Kết thúc', false)])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: isStart ? 6 : 0, left: isStart ? 0 : 6),
                    child: OutlinedButton(
                      onPressed: () async {
                        final v = await showTimePicker(context: c, initialTime: isStart ? start : end);
                        if (v != null) setD(() => isStart ? start = v : end = v);
                      },
                      child: Text('$label\n${fmt(isStart ? start : end)}', textAlign: TextAlign.center),
                    ),
                  ),
                ),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lưu')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (name.text.trim().isEmpty) return showError(context, 'Cần nhập tên ca');
    final row = {'name': name.text.trim(), 'start_time': fmt(start), 'end_time': fmt(end)};
    try {
      sh == null ? await _db.from('shift_defs').insert(row) : await _db.from('shift_defs').update(row).eq('id', sh['id']);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteShift(Rec sh) async {
    try {
      await _db.from('shift_defs').delete().eq('id', sh['id']); // bảng công cũ vẫn giữ tên ca đã chép
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _saveSettings() async {
    final ints = [capacity, priceDay, priceNight].map((c) => int.tryParse(c.text.trim())).toList();
    if (ints.any((v) => v == null || v < 0) || ints[0] == 0) return showError(context, 'Số không hợp lệ');
    if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(nightMark.text.trim())) {
      return showError(context, 'Mốc đêm dạng HH:MM');
    }
    try {
      await _db.from('settings').update({
        'capacity': ints[0],
        'price_day': ints[1],
        'price_night': ints[2],
        'night_mark': nightMark.text.trim(),
      }).eq('id', 1);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã lưu')));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Widget _num(TextEditingController c, String label, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
          keyboardType: TextInputType.number,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final header = t.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Giá & sức chứa', style: header),
      const SizedBox(height: 12),
      _num(capacity, 'Sức chứa (xe)', Icons.local_parking),
      _num(priceDay, 'Giá lượt ban ngày (đ)', Icons.wb_sunny_outlined),
      _num(priceNight, 'Giá mỗi đêm (đ)', Icons.nightlight_outlined),
      TextField(
        controller: nightMark,
        decoration: const InputDecoration(labelText: 'Mốc tính qua đêm (HH:MM)', prefixIcon: Icon(Icons.schedule)),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: _saveSettings, icon: const Icon(Icons.save_outlined), label: const Text('Lưu cài đặt')),
      const SizedBox(height: 24),
      Row(children: [
        Expanded(child: Text('Ca trực (chấm công)', style: header)),
        TextButton.icon(onPressed: _editShift, icon: const Icon(Icons.add), label: const Text('Thêm ca')),
      ]),
      Card(
        child: Column(children: [
          if (shifts.isEmpty) const ListTile(title: Text('Chưa có ca nào')),
          for (final sh in shifts)
            ListTile(
              leading: const Icon(Icons.schedule),
              title: Text(sh['name'] as String),
              subtitle: Text('${(sh['start_time'] as String).substring(0, 5)} → ${(sh['end_time'] as String).substring(0, 5)}'),
              onTap: () => _editShift(sh),
              trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Xoá ca', onPressed: () => _deleteShift(sh)),
            ),
        ]),
      ),
      const SizedBox(height: 24),
      Text('Thiết bị', style: header),
      const SizedBox(height: 8),
      Card(
        child: Column(children: [
          ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Đổi vai trò thiết bị'), onTap: widget.onChangeRole),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('Đăng xuất', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => Supabase.instance.client.auth.signOut(),
          ),
        ]),
      ),
    ]);
  }
}
