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
  List<Rec> guards = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await _db.from('settings').select().single();
      final g = await _db.from('guards').select('id, name, finger_id, pin_hash').order('id');
      if (!mounted) return;
      setState(() {
        capacity.text = '${s['capacity']}';
        priceDay.text = '${s['price_day']}';
        priceNight.text = '${s['price_night']}';
        nightMark.text = (s['night_mark'] as String).substring(0, 5);
        guards = g;
      });
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

  Future<void> _editGuard([Rec? g]) async {
    final name = TextEditingController(text: g?['name'] as String?);
    final finger = TextEditingController(text: g?['finger_id']?.toString());
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(g == null ? 'Thêm bảo vệ' : 'Sửa bảo vệ'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Tên')),
          fieldGap,
          TextField(
            controller: finger,
            decoration: const InputDecoration(labelText: 'ID vân tay trên AS608 (1-300)'),
            keyboardType: TextInputType.number,
          ),
          fieldGap,
          TextField(
            controller: pin,
            decoration: InputDecoration(labelText: g == null ? 'PIN (4-8 số)' : 'PIN mới (để trống = giữ nguyên)'),
            keyboardType: TextInputType.number,
            obscureText: true,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    try {
      final row = {'name': name.text.trim(), 'finger_id': int.tryParse(finger.text.trim())};
      final id = g == null
          ? (await _db.from('guards').insert(row).select('id').single())['id']
          : (await _db.from('guards').update(row).eq('id', g['id']).select('id').single())['id'];
      if (pin.text.isNotEmpty) await _db.rpc('set_guard_pin', params: {'p_id': id, 'p_pin': pin.text});
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteGuard(Rec g) async {
    try {
      await _db.from('guards').delete().eq('id', g['id']);
      _load();
    } catch (e) {
      if (mounted) showError(context, 'Bảo vệ đã có lịch sử mở cổng, không xoá được. $e');
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
        Expanded(child: Text('Bảo vệ', style: header)),
        TextButton.icon(onPressed: _editGuard, icon: const Icon(Icons.add), label: const Text('Thêm')),
      ]),
      for (final g in guards)
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.security)),
            title: Text('#${g['id']} ${g['name']}'),
            subtitle: Text('Vân tay: ${g['finger_id'] ?? '-'} · PIN: ${g['pin_hash'] == null ? 'chưa đặt' : 'đã đặt'}'),
            onTap: () => _editGuard(g),
            trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _deleteGuard(g)),
          ),
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
