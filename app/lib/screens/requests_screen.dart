import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';
import '../nfc.dart';
import 'customer_screen.dart' show statusColor;
import 'dashboard_screen.dart' show hhmm;

/// Quản lý duyệt đơn đăng ký / gia hạn vé tháng của khách.
/// Đơn gia hạn: duyệt là cộng hạn. Đơn mới: gán 1 thẻ RFID (gõ UID, đọc NFC, hoặc lấy thẻ vừa quẹt ở cổng).
class RequestsScreen extends StatefulWidget {
  const RequestsScreen({super.key});

  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen> {
  List<Rec>? rows;
  bool onlyPending = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/requests', {'status': onlyPending ? 'pending' : ''}) as List;
      if (mounted) setState(() => rows = r.cast<Rec>());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _approve(Rec r) async {
    final isNew = r['card_uid'] == null;
    final uid = TextEditingController();
    final reply = TextEditingController();
    final since = DateTime.now().toUtc().toIso8601String();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(isNew ? 'Cấp vé tháng mới' : 'Gia hạn vé tháng'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${r['plate']} · ${r['owner_name']} · ${r['months']} tháng'),
              if (!isNew) Text('Thẻ ${r['card_uid']}, hạn hiện tại ${r['card_valid_until'] ?? 'không giới hạn'}'),
              if (isNew) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: uid,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'UID thẻ RFID giao cho khách', prefixIcon: Icon(Icons.nfc)),
                ),
                Wrap(spacing: 4, children: [
                  TextButton.icon(
                    icon: const Icon(Icons.contactless_outlined),
                    label: const Text('Thẻ vừa quẹt ở cổng'),
                    onPressed: () async {
                      final s = await api.get('/scans/latest', {'since': since});
                      if (s == null) {
                        if (c.mounted) showError(c, 'Chưa có thẻ nào được quẹt từ lúc mở hộp thoại');
                        return;
                      }
                      set(() => uid.text = (s as Rec)['uid'] as String);
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.nfc),
                    label: const Text('Đọc NFC'),
                    onPressed: () async {
                      if (!await nfcAvailable()) {
                        if (c.mounted) showError(c, 'Điện thoại không có hoặc chưa bật NFC');
                        return;
                      }
                      final u = await readCardUid();
                      if (u != null) set(() => uid.text = u);
                    },
                  ),
                ]),
              ],
              const SizedBox(height: 8),
              TextField(controller: reply, decoration: const InputDecoration(labelText: 'Lời nhắn cho khách (không bắt buộc)')),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Duyệt')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final res = await api.post('/requests/${r['id']}/approve',
          {if (isNew) 'cardUid': uid.text.trim().toUpperCase(), 'reply': reply.text.trim()}) as Rec;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã duyệt: thẻ ${(res['card'] as Rec)['uid']} dùng tới hết ${(res['card'] as Rec)['valid_until']}')));
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _reject(Rec r) async {
    final reply = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Từ chối đơn'),
        content: TextField(controller: reply, autofocus: true, decoration: const InputDecoration(labelText: 'Lý do (khách sẽ thấy)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Từ chối')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.post('/requests/${r['id']}/reject', {'reply': reply.text.trim()});
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Đơn vé tháng'), actions: [
          FilterChip(
            label: const Text('Chờ duyệt'),
            selected: onlyPending,
            onSelected: (v) {
              setState(() => onlyPending = v);
              _load();
            },
          ),
          const SizedBox(width: 12),
        ]),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            if (rows == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
            if (rows != null && rows!.isEmpty) const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('Không có đơn nào'))),
            for (final r in rows ?? const <Rec>[])
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(
                        child: Text('${r['plate']} · ${r['months']} tháng',
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      ),
                      Text(r['card_uid'] == null ? 'Đăng ký mới' : 'Gia hạn',
                          style: TextStyle(color: statusColor(context, r['status'] as String))),
                    ]),
                    Text('${r['owner_name']} · @${r['username']} · ${hhmm(r['created_at'] as String)}'),
                    if (r['note'] != null) Text('Ghi chú: ${r['note']}'),
                    if (r['reply'] != null) Text('Trả lời: ${r['reply']}'),
                    if (r['status'] == 'pending')
                      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                        TextButton(onPressed: () => _reject(r), child: const Text('Từ chối')),
                        const SizedBox(width: 8),
                        FilledButton(onPressed: () => _approve(r), child: const Text('Duyệt')),
                      ]),
                  ]),
                ),
              ),
          ]),
        ),
      );
}
