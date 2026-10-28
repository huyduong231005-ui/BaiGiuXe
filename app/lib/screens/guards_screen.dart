import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic.dart';
import '../main.dart';
import 'attendance_screen.dart';

final _db = Supabase.instance.client;
final _pinRe = RegExp(r'^\d{4,8}$');

/// Bảo vệ: tên, PIN mở cổng (phím A) và vân tay (đăng ký ở ESP32 bằng phím B).
class GuardsScreen extends StatefulWidget {
  const GuardsScreen({super.key});

  @override
  State<GuardsScreen> createState() => _GuardsScreenState();
}

class _GuardsScreenState extends State<GuardsScreen> {
  List<Rec> guards = [];
  Map<int, Rec> onDuty = {}; // guard_id -> lượt chấm công đang mở
  late final RealtimeChannel _ch;

  @override
  void initState() {
    super.initState();
    _load();
    // Bảng guards không có realtime. ĐT cổng ra ghi gate_events(override) ngay sau khi gán vân tay
    // -> tải lại để thấy "Vân tay #id" mà không phải kéo làm mới.
    _ch = _db
        .channel('guards-refresh')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'gate_events',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'kind', value: 'override'),
          callback: (_) => _load(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _db.removeChannel(_ch);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final g = await _db.from('guards').select('id, name, finger_id, pin_hash').order('id');
      if (mounted) setState(() => guards = g);
      // Tách riêng: chưa chạy migration 0004 thì vẫn hiện được danh sách bảo vệ.
      final a = await _db.from('attendance').select('guard_id, shift_name, time_in').isFilter('time_out', null);
      if (mounted) setState(() => onDuty = {for (final x in a) x['guard_id'] as int: x});
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
      await _db.from('guards').delete().eq('id', g['id']);
      _load();
    } catch (e) {
      if (mounted) showError(context, 'Bảo vệ đã có lịch sử mở cổng hoặc chấm công, không xoá được. $e');
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
              subtitle: Text(onDuty.isEmpty ? 'Chưa ai trong ca' : '${onDuty.length} người đang trực'),
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
                    _Status(Icons.pin_outlined, g['pin_hash'] == null ? 'Chưa có PIN' : 'Có PIN', g['pin_hash'] != null),
                    _Status(Icons.fingerprint,
                        g['finger_id'] == null ? 'Chưa có vân tay' : 'Vân tay #${g['finger_id']}', g['finger_id'] != null),
                    if (onDuty[g['id']] case final a?)
                      _Status(Icons.badge_outlined,
                          'Đang trực · ${a['shift_name'] ?? 'ngoài ca'} từ ${hm(DateTime.parse(a['time_in'] as String).toLocal())}', true),
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
