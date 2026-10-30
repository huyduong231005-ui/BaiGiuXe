import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';
import '../lock.dart';
import 'accounts_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onChangeRole});

  final VoidCallback? onChangeRole; // null: đăng nhập bằng tài khoản API, không gắn vai trò theo máy

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final capacity = TextEditingController();
  final priceDay = TextEditingController();
  final priceNight = TextEditingController();
  final nightMark = TextEditingController();
  final lotName = TextEditingController();
  final address = TextEditingController();
  final latLng = TextEditingController(); // "10.8017, 106.7149" (copy từ Google Maps)
  List<Rec> shifts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await api.get('/settings') as Rec;
      if (!mounted) return;
      setState(() {
        capacity.text = '${s['capacity']}';
        priceDay.text = '${s['price_day']}';
        priceNight.text = '${s['price_night']}';
        nightMark.text = (s['night_mark'] as String).substring(0, 5);
        lotName.text = s['lot_name'] as String? ?? '';
        address.text = s['address'] as String? ?? '';
        latLng.text = s['lat'] == null ? '' : '${s['lat']}, ${s['lng']}';
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
    try {
      final sh = await api.get('/shifts') as List;
      if (mounted) setState(() => shifts = sh.cast<Rec>());
    } catch (e) {
      if (mounted) showError(context, e);
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
    final row = {'name': name.text.trim(), 'startTime': fmt(start), 'endTime': fmt(end)};
    try {
      sh == null ? await api.post('/shifts', row) : await api.put('/shifts/${sh['id']}', row);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteShift(Rec sh) async {
    try {
      await api.delete('/shifts/${sh['id']}'); // bảng công cũ vẫn giữ tên ca đã chép
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
    final ll = latLng.text.split(',').map((v) => double.tryParse(v.trim())).toList();
    if (latLng.text.trim().isNotEmpty && (ll.length != 2 || ll.contains(null))) {
      return showError(context, 'Toạ độ dạng "vĩ độ, kinh độ", VD 10.8017, 106.7149');
    }
    try {
      await api.put('/settings', {
        'capacity': ints[0],
        'priceDay': ints[1],
        'priceNight': ints[2],
        'nightMark': nightMark.text.trim(),
        'lotName': lotName.text.trim(),
        'address': address.text.trim(),
        'lat': latLng.text.trim().isEmpty ? null : ll[0],
        'lng': latLng.text.trim().isEmpty ? null : ll[1],
      });
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
      const SizedBox(height: 20),
      Text('Thông tin bãi (khách xem trên bản đồ)', style: header),
      const SizedBox(height: 12),
      TextField(controller: lotName, decoration: const InputDecoration(labelText: 'Tên bãi', prefixIcon: Icon(Icons.local_parking))),
      fieldGap,
      TextField(controller: address, decoration: const InputDecoration(labelText: 'Địa chỉ', prefixIcon: Icon(Icons.place_outlined))),
      fieldGap,
      TextField(
        controller: latLng,
        decoration: const InputDecoration(
          labelText: 'Toạ độ (vĩ độ, kinh độ)',
          prefixIcon: Icon(Icons.my_location),
          helperText: 'Google Maps: nhấn giữ vị trí bãi, chép dãy số hiện ra',
        ),
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
          if (api.session.value case final u?) ...[
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(u.displayName),
              subtitle: Text('${u.email} · đổi họ tên, mật khẩu'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
            ),
            const BioLockTile(),
          ],
          if (widget.onChangeRole != null)
            ListTile(leading: const Icon(Icons.swap_horiz), title: const Text('Đổi vai trò thiết bị'), onTap: widget.onChangeRole),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('Đăng xuất', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: signOutAll,
          ),
        ]),
      ),
    ]);
  }
}
