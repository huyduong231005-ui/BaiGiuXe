import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../api.dart';
import '../logic.dart';
import '../lot.dart';
import '../main.dart';

/// Tab Doanh thu: theo ngày (30 ngày) hoặc theo tháng (12 tháng), tách vé lượt (phí lúc xe ra) và vé tháng
/// (khoản thu khi duyệt đơn), tổng theo loại xe, xuất báo cáo Excel.
class RevenueScreen extends StatefulWidget {
  const RevenueScreen({super.key});

  @override
  State<RevenueScreen> createState() => _RevenueScreenState();
}

class _RevenueScreenState extends State<RevenueScreen> {
  String group = 'day';
  Rec? data;
  String? error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      await vehicleTypes();
      final r = await api.get('/stats/revenue', {'group': group}) as Rec;
      if (mounted) {
        setState(() {
          data = r;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _export() async {
    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    try {
      final bytes = await api.getBytes('/reports/monthly.xlsx', {'month': month});
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(bytes, name: 'bao-cao-$month.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')],
        fileNameOverrides: ['bao-cao-$month.xlsx'],
      ));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final d = data;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(child: Text('Doanh thu', style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
          IconButton(onPressed: _export, icon: const Icon(Icons.file_download_outlined), tooltip: 'Báo cáo Excel tháng này'),
        ]),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'day', label: Text('30 ngày'), icon: Icon(Icons.calendar_view_day)),
            ButtonSegment(value: 'month', label: Text('12 tháng'), icon: Icon(Icons.calendar_month)),
          ],
          selected: {group},
          onSelectionChanged: (v) {
            setState(() {
              group = v.first;
              data = null;
            });
            _reload();
          },
        ),
        const SizedBox(height: 16),
        if (d == null)
          Center(child: Padding(padding: const EdgeInsets.all(32), child: error != null ? Text(error!, style: TextStyle(color: s.error)) : const CircularProgressIndicator()))
        else ...[
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 2.1,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            children: [
              _Stat('Tổng', vnd(d['total'] as num), Icons.payments_outlined, s.primary),
              _Stat('Vé lượt (khách)', vnd(d['visitor'] as num), Icons.confirmation_number_outlined, s.secondary),
              _Stat('Vé tháng (cư dân)', vnd(d['monthly'] as num), Icons.event_repeat, s.tertiary),
              _Stat('Lượt xe ra', '${d['sessions']}', Icons.logout, s.outline),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 8),
                  child: Row(children: [
                    _Legend(s.secondary, 'Vé lượt'),
                    const SizedBox(width: 12),
                    _Legend(s.tertiary, 'Vé tháng'),
                  ]),
                ),
                SizedBox(height: 200, child: RevenueBars((d['rows'] as List).cast<Rec>(), monthly: group == 'month')),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          Text('Theo loại xe', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              if ((d['byType'] as List).isEmpty) const ListTile(title: Text('Chưa có doanh thu trong khoảng này')),
              for (final r in (d['byType'] as List).cast<Rec>())
                ListTile(
                  leading: Icon(vehicleIcon(r['vehicle_type'] as String?)),
                  title: Text(r['name'] as String),
                  subtitle: Text('${r['sessions']} lượt · vé lượt ${vnd(r['visitor'] as num)} · vé tháng ${vnd(r['monthly'] as num)}'),
                  trailing: Text(vnd((r['visitor'] as num) + (r['monthly'] as num)), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
          const SizedBox(height: 16),
          Text(group == 'day' ? 'Từng ngày' : 'Từng tháng', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              for (final r in (d['rows'] as List).cast<Rec>().reversed.where((r) => (r['total'] as num) > 0 || (r['sessions'] as num) > 0))
                ListTile(
                  dense: true,
                  title: Text(_label(r['period'] as String, long: true)),
                  subtitle: Text('${r['sessions']} lượt · vé lượt ${vnd(r['visitor'] as num)} · vé tháng ${vnd(r['monthly'] as num)}'),
                  trailing: Text(vnd(r['total'] as num), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// "2026-10-30" -> "30/10", "2026-10" -> "T10" (long: "Tháng 10/2026", "30/10/2026").
String _label(String period, {bool long = false}) {
  final p = period.split('-');
  if (p.length == 2) return long ? 'Tháng ${p[1]}/${p[0]}' : 'T${int.parse(p[1])}';
  return long ? '${p[2]}/${p[1]}/${p[0]}' : '${int.parse(p[2])}/${int.parse(p[1])}';
}

/// Cột chồng: vé lượt (dưới) + vé tháng (trên) cho từng ngày / tháng.
class RevenueBars extends StatelessWidget {
  const RevenueBars(this.rows, {super.key, this.monthly = false});

  final List<Rec> rows;
  final bool monthly;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final maxTotal = rows.fold<num>(0, (a, r) => (r['total'] as num) > a ? r['total'] as num : a);
    final step = rows.length > 14 ? 5 : 1; // 30 ngày: nhãn cách 5 ngày
    return BarChart(BarChartData(
      maxY: maxTotal == 0 ? 10000 : maxTotal * 1.2,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      barTouchData: BarTouchData(
        touchTooltipData: BarTouchTooltipData(
          getTooltipColor: (_) => s.inverseSurface,
          getTooltipItem: (g, _, _, _) {
            final r = rows[g.x];
            return BarTooltipItem('${_label(r['period'] as String)}\n${vnd(r['total'] as num)}\n${r['sessions']} lượt',
                TextStyle(color: s.onInverseSurface, fontSize: 12));
          },
        ),
      ),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(),
        rightTitles: const AxisTitles(),
        leftTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 40,
            getTitlesWidget: (v, meta) => v == meta.max || v == 0
                ? const SizedBox.shrink()
                : Text(v >= 1e6 ? '${(v / 1e6).toStringAsFixed(1)}tr' : '${(v / 1000).round()}k', style: t.labelSmall),
          ),
        ),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            getTitlesWidget: (v, _) {
              final i = v.toInt();
              if (i % step != 0 && i != rows.length - 1) return const SizedBox.shrink();
              return Padding(padding: const EdgeInsets.only(top: 4), child: Text(_label(rows[i]['period'] as String), style: t.labelSmall));
            },
          ),
        ),
      ),
      barGroups: [
        for (final (i, r) in rows.indexed)
          BarChartGroupData(x: i, barRods: [
            BarChartRodData(
              toY: (r['total'] as num).toDouble(),
              width: monthly ? 16 : 6,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
              rodStackItems: [
                BarChartRodStackItem(0, (r['visitor'] as num).toDouble(), s.secondary),
                BarChartRodStackItem((r['visitor'] as num).toDouble(), (r['total'] as num).toDouble(), s.tertiary),
              ],
            ),
          ]),
      ],
    ));
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, this.icon, this.color);

  final String label, value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: t.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              FittedBox(child: Text(value, style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.text);

  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 4),
        Text(text, style: Theme.of(context).textTheme.labelSmall),
      ]);
}
