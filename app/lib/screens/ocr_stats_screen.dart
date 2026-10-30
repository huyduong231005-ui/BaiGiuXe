import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../lot.dart';
import '../main.dart';
import 'dashboard_screen.dart' show hhmm;

String _ms(num? v) => v == null ? '-' : v >= 1000 ? '${(v / 1000).toStringAsFixed(2)} s' : '$v ms';
String _pct(num? v) => v == null ? '-' : '$v%';

/// Tốc độ + độ chính xác nhận diện biển số đo trên các lượt quẹt thật (GET /stats/ocr).
class OcrStatsScreen extends StatefulWidget {
  const OcrStatsScreen({super.key});

  @override
  State<OcrStatsScreen> createState() => _OcrStatsScreenState();
}

class _OcrStatsScreenState extends State<OcrStatsScreen> {
  int days = 30;
  Rec? data;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final r = await api.get('/stats/ocr', {'days': '$days'}) as Rec;
      if (mounted) setState(() => data = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final d = data;
    return Scaffold(
      appBar: AppBar(title: const Text('Nhận diện biển số')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 1, label: Text('Hôm nay')),
              ButtonSegment(value: 7, label: Text('7 ngày')),
              ButtonSegment(value: 30, label: Text('30 ngày')),
            ],
            selected: {days},
            onSelectionChanged: (v) {
              setState(() {
                days = v.first;
                data = null;
              });
              _reload();
            },
          ),
          const SizedBox(height: 16),
          if (d == null)
            const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
          else ...[
            Text('Tốc độ (${d['scans']} lượt quẹt)', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                _Row('Chụp + đọc biển (Plate Recognizer qua API)', d['ocrMs'] as Rec),
                const Divider(height: 1),
                _Row('Từ lúc quẹt thẻ tới lúc ESP32 có kết quả', d['totalMs'] as Rec),
              ]),
            ),
            const SizedBox(height: 16),
            Text('Độ chính xác', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                ListTile(
                  leading: const Icon(Icons.visibility_outlined),
                  title: const Text('Đọc được biển'),
                  subtitle: const Text('Lượt quẹt có ra biển số (gồm cả lần chụp lại)'),
                  trailing: Text(_pct(d['readRate'] as num?), style: t.titleMedium),
                ),
                ListTile(
                  leading: const Icon(Icons.looks_one_outlined),
                  title: const Text('Đọc rõ ngay lần chụp đầu'),
                  subtitle: const Text('Độ tin cậy ≥ 0,8 không phải chụp lại'),
                  trailing: Text(_pct(d['firstShotRate'] as num?), style: t.titleMedium),
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: const Text('Độ tin cậy trung bình'),
                  trailing: Text('${d['avgScore'] ?? '-'}', style: t.titleMedium),
                ),
                ListTile(
                  leading: const Icon(Icons.compare_arrows),
                  title: const Text('Biển lúc ra khớp biển lúc vào'),
                  subtitle: Text('${d['exits']} lượt ra đọc được biển (lệch tối đa 1 ký tự vẫn tính khớp)'),
                  trailing: Text(_pct(d['exitMatchRate'] as num?), style: t.titleMedium),
                ),
              ]),
            ),
            if ((d['reasons'] as List).isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Lý do từ chối', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Card(
                child: Column(children: [
                  for (final r in (d['reasons'] as List).cast<Rec>())
                    ListTile(dense: true, title: Text(r['message'] as String), trailing: Text('${r['count']}')),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            Text('20 lượt gần nhất', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              child: Column(children: [
                if ((d['recent'] as List).isEmpty)
                  const ListTile(title: Text('Chưa có lượt nào có số đo (cần ĐT camera bản mới)')),
                for (final r in (d['recent'] as List).cast<Rec>())
                  ListTile(
                    dense: true,
                    leading: Icon(vehicleIcon(r['vehicle_type'] as String?), color: r['plate'] == null ? s.error : null),
                    title: Text('${r['gate'] == 'in' ? 'VÀO' : 'RA'} · ${r['plate'] ?? 'không đọc được'}'
                        '${r['score'] == null ? '' : ' · ${(r['score'] as num).toStringAsFixed(3)}'}'),
                    subtitle: Text('${hhmm(r['at'] as String?)} · ${r['shots']} lần chụp · ${r['message']}'),
                    trailing: Text('${_ms(r['ocr_ms'] as num?)}\n${_ms(r['total_ms'] as num?)}', textAlign: TextAlign.end),
                  ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.title, this.v);

  final String title;
  final Rec v;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.bodyMedium),
        const SizedBox(height: 8),
        Row(children: [
          for (final (label, key) in [('Trung bình', 'avg'), ('Trung vị', 'p50'), ('95% lượt dưới', 'p95')])
            Expanded(
              child: Column(children: [
                Text(_ms(v[key] as num?), style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                Text(label, style: t.labelSmall),
              ]),
            ),
        ]),
      ]),
    );
  }
}
