import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';

const _days = 7;

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Điền đủ [_days] ngày kết thúc ở [today] (API chỉ trả ngày có doanh thu) -> (ngày, doanh thu, số lượt).
List<({DateTime day, int revenue, int sessions})> fillDays(List<Rec> rows, DateTime today) {
  final byDay = {for (final r in rows) r['day'] as String: r};
  return [
    for (var i = _days - 1; i >= 0; i--)
      () {
        final d = DateTime(today.year, today.month, today.day - i);
        final r = byDay[_ymd(d)];
        return (day: d, revenue: (r?['revenue'] as int?) ?? 0, sessions: (r?['sessions'] as int?) ?? 0);
      }(),
  ];
}

/// Biểu đồ cột doanh thu 7 ngày gần nhất (theo giờ ra), lấy từ GET /stats/revenue.
class RevenueChart extends StatefulWidget {
  const RevenueChart({super.key});

  @override
  State<RevenueChart> createState() => RevenueChartState();
}

class RevenueChartState extends State<RevenueChart> {
  List<({DateTime day, int revenue, int sessions})>? data;
  String? error;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final r = await api.get('/stats/revenue') as Rec;
      if (mounted) setState(() => data = fillDays((r['days'] as List).cast<Rec>(), DateTime.now()));
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final d = data;
    final total = d?.fold(0, (a, x) => a + x.revenue) ?? 0;
    final maxY = d == null || d.every((x) => x.revenue == 0) ? 10000.0 : d.map((x) => x.revenue).reduce((a, b) => a > b ? a : b) * 1.25;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text('Doanh thu 7 ngày: $total đ', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 160,
            child: d == null
                ? Center(child: error != null ? Text(error!, style: TextStyle(color: s.error)) : const CircularProgressIndicator())
                : BarChart(BarChartData(
                    maxY: maxY,
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipItem: (g, _, rod, _) => BarTooltipItem(
                            '${rod.toY.round()} đ\n${d[g.x].sessions} lượt', TextStyle(color: s.onInverseSurface, fontSize: 12)),
                        getTooltipColor: (_) => s.inverseSurface,
                      ),
                    ),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          getTitlesWidget: (v, meta) => v == meta.max || v == 0
                              ? const SizedBox.shrink()
                              : Text('${(v / 1000).round()}k', style: t.labelSmall),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (v, _) => Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text('${d[v.toInt()].day.day}/${d[v.toInt()].day.month}', style: t.labelSmall),
                          ),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (final (i, x) in d.indexed)
                        BarChartGroupData(x: i, barRods: [
                          BarChartRodData(
                            toY: x.revenue.toDouble(),
                            width: 18,
                            color: i == d.length - 1 ? s.primary : s.primary.withValues(alpha: 0.55),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                          ),
                        ]),
                    ],
                  )),
          ),
        ]),
      ),
    );
  }
}
