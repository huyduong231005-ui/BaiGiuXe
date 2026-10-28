import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic.dart';
import '../main.dart';

final _db = Supabase.instance.client;

String _dur(int min) => '${min ~/ 60}h${(min % 60).toString().padLeft(2, '0')}';

/// Bảng công theo tháng: tổng hợp từng bảo vệ + chi tiết từng lượt vào/ra ca.
class AttendanceScreen extends StatefulWidget {
  const AttendanceScreen({super.key});

  @override
  State<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends State<AttendanceScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Rec> rows = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      final r = await _db
          .from('attendance')
          .select('*, guards(name)')
          .gte('time_in', month.toUtc().toIso8601String())
          .lt('time_in', DateTime(month.year, month.month + 1).toUtc().toIso8601String())
          .order('time_in', ascending: false);
      if (mounted) setState(() => rows = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _shift(int months) {
    month = DateTime(month.year, month.month + months);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    // Tổng hợp theo bảo vệ.
    final byGuard = <String, List<(Rec, AttStat)>>{};
    for (final r in rows) {
      byGuard.putIfAbsent((r['guards'] as Rec?)?['name'] as String? ?? '#${r['guard_id']}', () => []).add((r, attStat(r)));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Bảng công')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            IconButton.filledTonal(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text('Tháng ${month.month}/${month.year}',
                  textAlign: TextAlign.center, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
            IconButton.filledTonal(onPressed: () => _shift(1), icon: const Icon(Icons.chevron_right)),
          ]),
          const SizedBox(height: 16),
          if (loading) const Center(child: CircularProgressIndicator()),
          if (!loading && rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Text('Chưa có lượt chấm công nào trong tháng này.\nBảo vệ bấm C ở ESP32 rồi đặt vân tay hoặc nhập PIN.',
                  textAlign: TextAlign.center, style: TextStyle(color: s.onSurfaceVariant)),
            ),
          for (final e in byGuard.entries) _summary(e.key, e.value.map((x) => x.$2).toList()),
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Chi tiết', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final r in rows) _row(r, attStat(r)),
          ],
        ]),
      ),
    );
  }

  Widget _summary(String name, List<AttStat> st) {
    final s = Theme.of(context).colorScheme;
    final worked = st.fold(0, (a, x) => a + x.workedMin);
    final late = st.where((x) => x.lateMin > 0);
    final early = st.where((x) => x.earlyMin > 0);
    final missing = st.where((x) => x.missingOut).length;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16))),
            Text(_dur(worked), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: s.primary)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _chip('${st.length} ca', s.primary),
            if (late.isNotEmpty) _chip('Trễ ${late.length} lần · ${late.fold(0, (a, x) => a + x.lateMin)}p', Colors.orange.shade800),
            if (early.isNotEmpty) _chip('Về sớm ${early.length} lần · ${early.fold(0, (a, x) => a + x.earlyMin)}p', Colors.orange.shade800),
            if (missing > 0) _chip('Quên chấm ra $missing', s.error),
          ]),
        ]),
      ),
    );
  }

  Widget _row(Rec r, AttStat st) {
    final s = Theme.of(context).colorScheme;
    final inT = DateTime.parse(r['time_in'] as String).toLocal();
    final outT = r['time_out'] == null ? null : DateTime.parse(r['time_out'] as String).toLocal();
    final name = (r['guards'] as Rec?)?['name'] ?? '#${r['guard_id']}';
    final out = st.open
        ? 'đang trực'
        : st.missingOut
            ? 'quên chấm ra'
            : 'ra ${hm(outT!)}${st.earlyMin > 0 ? ' (sớm ${st.earlyMin}p)' : ''}';
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: st.open ? Colors.green.shade100 : s.surfaceContainerHighest,
          child: Text('${inT.day}', style: TextStyle(fontWeight: FontWeight.bold, color: st.open ? Colors.green.shade900 : null)),
        ),
        title: Text('$name · ${r['shift_name'] ?? 'Ngoài ca'}', style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('Vào ${hm(inT)}${st.lateMin > 0 ? ' (trễ ${st.lateMin}p)' : ''} → $out'
            '${st.workedMin > 0 ? ' · ${_dur(st.workedMin)}' : ''}'),
        trailing: Icon(r['method_in'] == 'pin' ? Icons.pin_outlined : Icons.fingerprint,
            color: s.outline, semanticLabel: r['method_in'] == 'pin' ? 'Chấm bằng PIN' : 'Chấm bằng vân tay'),
      ),
    );
  }

  Widget _chip(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(color: c, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
