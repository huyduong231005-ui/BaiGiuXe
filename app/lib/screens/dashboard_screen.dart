import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';

/// Tài khoản API không có phiên Supabase nên không nghe Realtime được: tải lại định kỳ.
const _refreshEvery = Duration(seconds: 5);

String hhmm(String? iso) {
  if (iso == null) return '-';
  final t = DateTime.parse(iso).toLocal();
  return '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Rec? status;
  List<Rec> parked = [];
  List<Rec> events = [];
  Timer? timer;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    _reload();
    timer = Timer.periodic(_refreshEvery, (_) => _reload(quiet: true));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  /// quiet: lần tải định kỳ lỗi (mất mạng) thì không hiện snackbar mỗi 5 giây.
  Future<void> _reload({bool quiet = false}) async {
    if (loading) return;
    loading = true;
    try {
      final r = await Future.wait([
        api.get('/status'),
        api.get('/sessions', {'open': 'true'}),
        api.get('/events', {'limit': '20'}),
      ]);
      if (!mounted) return;
      setState(() {
        status = r[0] as Rec;
        parked = ((r[1] as Rec)['sessions'] as List).cast<Rec>();
        events = (r[2] as List).cast<Rec>();
      });
    } catch (e) {
      if (mounted && !quiet) showError(context, e);
    } finally {
      loading = false;
    }
  }

  Future<void> _openGate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Mở barrier cổng ra?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Mở')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.post('/gate/open');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Mất thẻ / xử lý tay: đóng lượt gửi, tính phí và mở cổng ra (API làm cả 3 việc).
  Future<void> _release(Rec s) async {
    final int fee;
    try {
      fee = (await api.get('/sessions/${s['id']}/fee'))['fee'] as int;
    } catch (e) {
      if (mounted) showError(context, e);
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Xe ${s['plate_in'] ?? '(không rõ biển)'}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          PlateImage(s['img_in'] as String?),
          Text('Thẻ ${s['card_uid']} · vào ${hhmm(s['time_in'] as String)}'),
          Text('Phí nếu cho ra bây giờ: $fee đ'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Đóng')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cho xe ra + mở cổng')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.post('/sessions/${s['id']}/release');
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final s = Theme.of(context).colorScheme;
    final header = t.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final free = status?['free'] as int?, cap = status?['capacity'] as int?;
    final usedRatio = (free == null || cap == null || cap == 0) ? 0.0 : ((cap - free) / cap).clamp(0.0, 1.0);
    final barColor = usedRatio >= 0.9 ? s.error : usedRatio >= 0.7 ? Colors.orange : s.primary;
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: s.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Chỗ trống', style: t.titleSmall?.copyWith(color: s.onPrimaryContainer)),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(free?.toString() ?? '...',
                    style: t.displayMedium?.copyWith(fontWeight: FontWeight.bold, color: s.onPrimaryContainer)),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10, left: 4),
                  child: Text('/ ${cap ?? '-'} xe', style: t.titleMedium?.copyWith(color: s.onPrimaryContainer)),
                ),
                const Spacer(),
                FilledButton.icon(onPressed: _openGate, icon: const Icon(Icons.lock_open), label: const Text('Mở cổng ra')),
              ]),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                    value: usedRatio, minHeight: 10, color: barColor, backgroundColor: s.surface.withValues(alpha: 0.6)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        Text('Xe trong bãi (${parked.length})', style: header),
        const SizedBox(height: 8),
        if (parked.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text('Bãi đang trống', textAlign: TextAlign.center, style: TextStyle(color: s.onSurfaceVariant)),
          ),
        for (final p in parked)
          Card(
            child: ListTile(
              leading: CircleAvatar(backgroundColor: s.secondaryContainer, child: const Icon(Icons.two_wheeler)),
              title: Text(p['plate_in'] as String? ?? '(không rõ biển)', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('Thẻ ${p['card_uid']} · vào ${hhmm(p['time_in'] as String)}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _release(p),
            ),
          ),
        const SizedBox(height: 20),
        Text('Sự kiện gần đây', style: header),
        const SizedBox(height: 8),
        Card(
          child: Column(children: [
            for (final e in events)
              ListTile(
                dense: true,
                leading: Icon(
                  e['status'] == 'denied' ? Icons.block : e['status'] == 'pending' ? Icons.hourglass_top : Icons.check_circle,
                  color: e['status'] == 'denied' ? s.error : e['status'] == 'pending' ? Colors.orange : Colors.green,
                ),
                title: Text('${e['gate'] == 'in' ? 'VÀO' : 'RA'} · ${e['kind']} · ${e['plate'] ?? e['uid'] ?? ''}'),
                subtitle: Text('${hhmm(e['created_at'] as String)} · ${e['message'] ?? e['status']}'),
                onTap: e['img'] == null
                    ? null
                    : () => showDialog(
                        context: context, builder: (_) => Dialog(child: PlateImage(e['img'] as String, height: 400))),
              ),
          ]),
        ),
      ]),
    );
  }
}
