import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic.dart';
import '../main.dart';
import 'dashboard_screen.dart' show hhmm;

final _db = Supabase.instance.client;

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  DateTime day = DateUtils.dateOnly(DateTime.now());
  final plate = TextEditingController();
  List<Rec> rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var q = _db
          .from('sessions')
          .select()
          .gte('time_in', day.toUtc().toIso8601String())
          .lt('time_in', day.add(const Duration(days: 1)).toUtc().toIso8601String());
      final p = normPlate(plate.text);
      if (p.isNotEmpty) q = q.or('plate_in.ilike.%$p%,plate_out.ilike.%$p%');
      final r = await q.order('time_in', ascending: false).limit(1000);
      if (mounted) setState(() => rows = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(context: context, initialDate: day, firstDate: DateTime(2024), lastDate: DateTime.now());
    if (d == null) return;
    day = d;
    _load();
  }

  void _show(Rec s) => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${s['plate_in'] ?? '?'} → ${s['plate_out'] ?? '?'}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Lúc vào'),
              PlateImage(s['img_in'] as String?),
              const Text('Lúc ra'),
              PlateImage(s['img_out'] as String?),
              Text('Thẻ ${s['card_uid']} · phí ${s['fee'] ?? '-'} đ'
                  '${s['override_by'] != null ? ' · bảo vệ #${s['override_by']} mở tay' : ''}'),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final total = rows.fold<int>(0, (a, s) => a + ((s['fee'] as int?) ?? 0));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          OutlinedButton.icon(
            onPressed: _pickDay,
            icon: const Icon(Icons.calendar_today),
            label: Text('${day.day}/${day.month}/${day.year}'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: plate,
              decoration: const InputDecoration(hintText: 'Tìm biển số', prefixIcon: Icon(Icons.search)),
              onSubmitted: (_) => _load(),
            ),
          ),
        ]),
      ),
      ListTile(
        title: Text('${rows.length} lượt · doanh thu $total đ', style: Theme.of(context).textTheme.titleMedium),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: rows.length,
          itemBuilder: (_, i) {
            final s = rows[i];
            return ListTile(
              title: Text(s['plate_in'] as String? ?? '(không rõ biển)'),
              subtitle: Text('Vào ${hhmm(s['time_in'] as String)} · Ra ${hhmm(s['time_out'] as String?)}'),
              trailing: Text(s['fee'] == null ? 'Đang gửi' : '${s['fee']} đ'),
              onTap: () => _show(s),
            );
          },
        ),
      ),
    ]);
  }
}
