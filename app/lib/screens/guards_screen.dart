import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';
import 'attendance_screen.dart';

final _pinRe = RegExp(r'^\d{4,8}$');
const _refreshEvery = Duration(seconds: 10);

/// Bảo vệ: tên, PIN mở cổng (phím A) và vân tay (đăng ký ở ESP32 bằng phím B).
class GuardsScreen extends StatefulWidget {
  const GuardsScreen({super.key});

  @override
  State<GuardsScreen> createState() => _GuardsScreenState();
}

class _GuardsScreenState extends State<GuardsScreen> {
  List<Rec> guards = []; // kèm has_pin, on_duty_shift, on_duty_since (lượt chấm công đang mở)
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    // Tải lại định kỳ để thấy "Vân tay #id" / "Đang trực" ngay sau khi bảo vệ đăng ký / chấm công ở ESP32.
    _timer = Timer.periodic(_refreshEvery, (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final g = await api.get('/guards') as List;
      if (mounted) setState(() => guards = g.cast<Rec>());
    } catch (e) {
      if (mounted && !quiet) showError(context, e);
    }
  }

  int get _onDuty => guards.where((g) => g['on_duty_since'] != null).length;

  Future<void> _editGuard([Rec? g]) async {
    final name = TextEditingController(text: g?['name'] as String?);
    final finger = TextEditingController(text: g?['finger_id']?.toString());
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(g == null ? 'Thêm bảo vệ' : 'Sửa bảo vệ'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Tên', prefixIcon: Icon(Icons.person_outline)),
            ),
            fieldGap,
            TextField(
              controller: pin,
              decoration: InputDecoration(
                labelText: g == null ? 'PIN (4-8 số)' : 'PIN mới (để trống = giữ nguyên)',
                prefixIcon: const Icon(Icons.pin_outlined),
              ),
              keyboardType: TextInputType.number,
              obscureText: true,
            ),
            fieldGap,
            TextField(
              controller: finger,
              decoration: const InputDecoration(
                labelText: 'ID vân tay (1-300)',
                prefixIcon: Icon(Icons.fingerprint),
                helperText: 'Tự điền khi đăng ký ở ESP32, thường để trống',
              ),
              keyboardType: TextInputType.number,
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lưu')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (name.text.trim().isEmpty) return showError(context, 'Cần nhập tên bảo vệ');
    // Không có PIN thì không mở cổng bằng phím A và không đăng ký vân tay được (phím B cần PIN).
    if ((g == null || pin.text.isNotEmpty) && !_pinRe.hasMatch(pin.text)) {
      return showError(context, 'PIN phải gồm 4-8 chữ số');
    }
    try {
      // API băm PIN bằng bcrypt trong Postgres; PIN để trống khi sửa = giữ nguyên.
      final row = {'name': name.text.trim(), 'pin': pin.text, 'fingerId': int.tryParse(finger.text.trim())};
      g == null ? await api.post('/guards', row) : await api.patch('/guards/${g['id']}', row);
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteGuard(Rec g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Xoá bảo vệ ${g['name']}?'),
        content: const Text('Mẫu vân tay trong cảm biến vẫn còn, cần đăng ký đè cho bảo vệ khác nếu muốn dùng lại ô đó.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/guards/${g['id']}');
      _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      showError(context, e.status == 409 ? 'Bảo vệ đã có lịch sử mở cổng hoặc chấm công, không xoá được.' : e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _editGuard,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Thêm bảo vệ'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
          Card(
            color: s.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.dialpad, color: s.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Text('Dùng ở bàn phím ESP32', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 8),
                const Text('Mở cổng ra: A → PIN → #, hoặc đặt vân tay đã đăng ký.'),
                const Text('Chấm công vào/ra ca: C → đặt vân tay, hoặc nhập PIN → #.'),
                const Text('Đăng ký vân tay: B → PIN của bảo vệ → #, đặt ngón tay, nhấc ra, đặt lại.'),
                const Text('Khi đang nhập PIN: C xoá 1 số · * xoá hết · D huỷ.'),
                const SizedBox(height: 4),
                Text('Đăng ký cần ĐT cổng ra đang mở app. Kéo xuống để làm mới sau khi đăng ký.',
                    style: t.bodySmall?.copyWith(color: s.onSecondaryContainer)),
              ]),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.event_note),
              title: const Text('Bảng công', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(_onDuty == 0 ? 'Chưa ai trong ca' : '$_onDuty người đang trực'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AttendanceScreen())),
            ),
          ),
          const SizedBox(height: 12),
          if (guards.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Text('Chưa có bảo vệ nào. Bấm "Thêm bảo vệ" để bắt đầu.',
                  textAlign: TextAlign.center, style: TextStyle(color: s.onSurfaceVariant)),
            ),
          for (final g in guards)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: s.primaryContainer,
                  child: Text('${g['id']}', style: TextStyle(color: s.onPrimaryContainer, fontWeight: FontWeight.bold)),
                ),
                title: Text('${g['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(spacing: 6, runSpacing: 4, children: [
                    _Status(Icons.pin_outlined, g['has_pin'] == true ? 'Có PIN' : 'Chưa có PIN', g['has_pin'] == true),
                    _Status(Icons.fingerprint,
                        g['finger_id'] == null ? 'Chưa có vân tay' : 'Vân tay #${g['finger_id']}', g['finger_id'] != null),
                    if (g['on_duty_since'] case final String since)
                      _Status(Icons.badge_outlined,
                          'Đang trực · ${g['on_duty_shift'] ?? 'ngoài ca'} từ ${hm(DateTime.parse(since).toLocal())}', true),
                  ]),
                ),
                onTap: () => _editGuard(g),
                trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Xoá', onPressed: () => _deleteGuard(g)),
              ),
            ),
        ]),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.icon, this.text, this.ok);

  final IconData icon;
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final c = ok ? Colors.green.shade700 : Theme.of(context).colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: c),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
