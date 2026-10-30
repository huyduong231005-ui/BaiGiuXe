import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';
import 'dashboard_screen.dart' show hhmm;
import 'revenue_chart.dart';

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  DateTime day = DateUtils.dateOnly(DateTime.now());
  final plate = TextEditingController();
  List<Rec> rows = [];
  int total = 0;
  final chart = GlobalKey<RevenueChartState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/sessions', {'date': _ymd(day), 'plate': normPlate(plate.text)}) as Rec;
      if (mounted) {
        setState(() {
          rows = (r['sessions'] as List).cast<Rec>();
          total = r['revenue'] as int;
        });
      }
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
                  '${s['override_by'] != null ? ' · bảo vệ ${s['override_name'] ?? '#${s['override_by']}'} mở tay' : ''}'),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Một ListView cuộn chung: biểu đồ 7 ngày ở đầu, rồi bộ lọc và danh sách lượt của ngày đang chọn.
    return RefreshIndicator(
      onRefresh: () async {
        await Future.wait([_load(), chart.currentState?.reload() ?? Future.value()]);
      },
      child: ListView(children: [
      Padding(padding: const EdgeInsets.fromLTRB(8, 8, 8, 0), child: RevenueChart(key: chart)),
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
      for (final s in rows)
        ListTile(
          title: Text(s['plate_in'] as String? ?? '(không rõ biển)'),
          subtitle: Text('Vào ${hhmm(s['time_in'] as String)} · Ra ${hhmm(s['time_out'] as String?)}'),
          trailing: Text(s['fee'] == null ? 'Đang gửi' : '${s['fee']} đ'),
          onTap: () => _show(s),
        ),
    ]),
    );
  }
}
