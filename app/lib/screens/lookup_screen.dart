import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';
import 'dashboard_screen.dart' show hhmm;

/// Tra cứu xe đang trong bãi bằng camera điện thoại của quản lý (hoặc gõ biển):
/// chụp biển -> API nhận diện -> tìm lượt đang gửi khớp biển (lệch tối đa 1 ký tự) -> xem ảnh lúc vào, phí, cho ra.
/// Dùng khi khách mất thẻ, hoặc kiểm tra một xe khả nghi đang đỗ trong bãi.
class LookupScreen extends StatefulWidget {
  const LookupScreen({super.key});

  @override
  State<LookupScreen> createState() => _LookupScreenState();
}

class _LookupScreenState extends State<LookupScreen> {
  final plate = TextEditingController();
  List<Rec>? matches;
  String? note;
  bool busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// image_picker tự thu ảnh về cạnh dài 1280px, JPEG 85 (giống ảnh ĐT camera gửi ở cổng).
  Future<void> _shoot() => _run(() async {
        final shot = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1280, maxHeight: 1280, imageQuality: 85);
        if (shot == null) return;
        final r = await api.postJpeg('/plates/recognize', await shot.readAsBytes()) as Rec;
        final p = r['plate'] as String?;
        if (p == null) {
          setState(() {
            matches = null;
            note = 'Không thấy biển số trong ảnh, chụp gần và thẳng hơn hoặc gõ tay';
          });
          return;
        }
        plate.text = p;
        await _search(candidates: (r['candidates'] as List).cast<String>(), score: (r['score'] as num).toDouble());
      });

  /// Khách mở "Mã QR vé" trên app của họ; quét ra lượt đang gửi của thẻ đó (mã ký, hết hạn 10 phút).
  Future<void> _scanTicket() async {
    final raw = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const _QrScanPage()));
    if (raw == null) return;
    await _run(() async {
      final r = await api.get('/sessions/by-ticket', {'qr': raw}) as Rec;
      setState(() {
        matches = (r['matches'] as List).cast<Rec>();
        plate.clear();
        note = [
          'Vé của ${r['owner'] ?? 'khách'} · thẻ ${r['cardUid']}',
          if (r['validUntil'] != null) 'hạn đến ${r['validUntil']}',
          if (r['lost'] == true) 'THẺ ĐÃ BÁO MẤT',
          if (matches!.isEmpty) 'xe không ở trong bãi',
        ].join(' · ');
      });
    });
  }

  Future<void> _search({List<String> candidates = const [], double? score}) async {
    final p = normPlate(plate.text);
    if (p.isEmpty) return;
    final r = await api.get('/sessions/lookup', {'plate': p, 'candidates': candidates.join(',')}) as Rec;
    setState(() {
      matches = (r['matches'] as List).cast<Rec>();
      note = score == null ? null : 'Đọc được $p (độ tin cậy ${(score * 100).round()}%)';
    });
  }

  Future<void> _release(Rec s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Cho xe ${s['plate_in']} ra?'),
        content: Text('Thu ${s['feeNow']} đ, đóng lượt gửi và mở barrier cổng ra.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cho ra + mở cổng')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await api.post('/sessions/${s['id']}/release');
      await _search();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã cho xe ra, barrier đang mở')));
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Tra cứu xe trong bãi')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        FilledButton.icon(
          onPressed: busy ? null : _shoot,
          icon: const Icon(Icons.photo_camera_outlined),
          label: const Text('Chụp biển số'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: busy ? null : _scanTicket,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('Quét mã QR vé của khách'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: plate,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: 'Hoặc gõ biển số',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: busy ? null : () => _run(_search)),
          ),
          onSubmitted: (_) => _run(_search),
        ),
        if (busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
        if (note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(note!, style: TextStyle(color: s.onSurfaceVariant))),
        const SizedBox(height: 16),
        if (matches case final list? when list.isEmpty && plate.text.isNotEmpty)
          Card(
            color: s.errorContainer,
            child: ListTile(
              leading: Icon(Icons.search_off, color: s.onErrorContainer),
              title: Text('Không có xe nào trong bãi khớp biển này', style: TextStyle(color: s.onErrorContainer)),
            ),
          ),
        for (final m in matches ?? const <Rec>[])
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: Text(m['plate_in'] as String? ?? '?',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
                  ),
                  if (m['exact'] != true) Chip(label: const Text('Gần đúng'), backgroundColor: s.tertiaryContainer),
                ]),
                Text('Thẻ ${m['card_uid']} · ${m['card_kind'] == 'monthly' ? 'Vé tháng' : 'Vé lượt'}'
                    '${m['card_owner'] != null ? ' · ${m['card_owner']}' : ''}'),
                Text('Vào ${hhmm(m['time_in'] as String)} · phí nếu ra bây giờ ${m['feeNow']} đ'),
                if (m['card_lost_at'] != null)
                  Text('Chủ thẻ đã báo mất: kiểm tra giấy tờ xe trước khi cho ra',
                      style: TextStyle(color: s.error, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                PlateImage(m['img_in'] as String?, height: 160),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: busy ? null : () => _release(m), icon: const Icon(Icons.lock_open), label: const Text('Cho xe ra + mở cổng')),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Camera quét QR: trả về chuỗi mã đầu tiên đọc được.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  bool done = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Quét mã QR vé')),
        body: MobileScanner(
          onDetect: (capture) {
            final v = capture.barcodes.firstOrNull?.rawValue;
            if (v == null || done) return;
            done = true; // camera bắn nhiều lần một giây, chỉ trả kết quả đầu
            Navigator.pop(context, v);
          },
        ),
      );
}
