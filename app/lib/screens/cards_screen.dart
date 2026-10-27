
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../logic.dart';
import '../main.dart';

final _db = Supabase.instance.client;
final _uidRe = RegExp(r'^[0-9A-F]{8,20}$');

class CardsScreen extends StatefulWidget {
  const CardsScreen({super.key});

  @override
  State<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends State<CardsScreen> {
  List<Rec> cards = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _db.from('cards').select().order('created_at', ascending: false);
      if (mounted) setState(() => cards = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit([Rec? card]) async {
    final saved = await showDialog<bool>(context: context, builder: (_) => _CardDialog(card));
    if (saved == true) _load();
  }

  Future<void> _delete(Rec c) async {
    try {
      await _db.from('cards').delete().eq('uid', c['uid']);
      _load();
    } catch (e) {
      // Thẻ đã có lượt gửi thì FK chặn xoá: khoá thẻ thay vì xoá.
      if (mounted) showError(context, 'Không xoá được (thẻ đã có lịch sử) - hãy khoá thẻ. $e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _edit,
          icon: const Icon(Icons.add),
          label: const Text('Thêm thẻ'),
        ),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(children: [
            for (final c in cards)
              ListTile(
                leading: Icon(c['kind'] == 'monthly' ? Icons.event_repeat : Icons.credit_card,
                    color: c['active'] == true ? null : Colors.grey),
                title: Text('${c['uid']}${c['active'] == true ? '' : ' (khoá)'}'),
                subtitle: Text([
                  c['kind'] == 'monthly' ? 'Vé tháng' : 'Vé lượt',
                  if (c['plate'] != null) c['plate'],
                  if (c['owner'] != null) c['owner'],
                ].join(' · ')),
                onTap: () => _edit(c),
                trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(c)),
              ),
          ]),
        ),
      );
}

class _CardDialog extends StatefulWidget {
  const _CardDialog(this.card);

  final Rec? card;

  @override
  State<_CardDialog> createState() => _CardDialogState();
}

class _CardDialogState extends State<_CardDialog> {
  late final uid = TextEditingController(text: widget.card?['uid'] as String?);
  late final plate = TextEditingController(text: widget.card?['plate'] as String?);
  late final owner = TextEditingController(text: widget.card?['owner'] as String?);
  late String kind = widget.card?['kind'] as String? ?? 'guest';
  late bool active = widget.card?['active'] as bool? ?? true;
  RealtimeChannel? listening;
  String? error;

  bool get isNew => widget.card == null;

  /// Chờ lần quẹt thẻ kế tiếp ở bất kỳ cổng nào để lấy UID.
  void _waitScan() {
    setState(() => listening = _db
        .channel('enroll')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'gate_events',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'kind', value: 'scan'),
          callback: (p) {
            uid.text = p.newRecord['uid'] as String;
            _stopScan();
          },
        )
        .subscribe());
  }

  void _stopScan() {
    if (listening == null) return;
    _db.removeChannel(listening!);
    if (mounted) setState(() => listening = null);
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  Future<void> _save() async {
    final u = uid.text.trim().toUpperCase();
    final p = normPlate(plate.text);
    if (!_uidRe.hasMatch(u)) return setState(() => error = 'UID phải là 8-20 ký tự hex');
    if (kind == 'monthly' && p.isEmpty) return setState(() => error = 'Vé tháng cần biển số');
    final row = {
      'uid': u,
      'kind': kind,
      'plate': p.isEmpty ? null : p,
      'owner': owner.text.trim().isEmpty ? null : owner.text.trim(),
      'active': active,
    };
    try {
      isNew ? await _db.from('cards').insert(row) : await _db.from('cards').update(row).eq('uid', widget.card!['uid']);
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(isNew ? 'Thêm thẻ' : 'Sửa thẻ'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: uid,
              enabled: isNew,
              decoration: InputDecoration(
                labelText: 'UID thẻ',
                suffixIcon: !isNew
                    ? null
                    : listening == null
                        ? IconButton(icon: const Icon(Icons.contactless), tooltip: 'Quẹt thẻ ở cổng', onPressed: _waitScan)
                        : const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
            if (listening != null) const Text('Hãy quẹt thẻ ở đầu đọc bất kỳ...'),
            DropdownButtonFormField(
              initialValue: kind,
              decoration: const InputDecoration(labelText: 'Loại'),
              items: const [
                DropdownMenuItem(value: 'guest', child: Text('Vé lượt')),
                DropdownMenuItem(value: 'monthly', child: Text('Vé tháng')),
              ],
              onChanged: (v) => setState(() => kind = v!),
            ),
            TextField(controller: plate, decoration: const InputDecoration(labelText: 'Biển số (vé tháng)')),
            TextField(controller: owner, decoration: const InputDecoration(labelText: 'Chủ xe')),
            SwitchListTile(title: const Text('Đang hoạt động'), value: active, onChanged: (v) => setState(() => active = v)),
            if (error != null) Text(error!, style: const TextStyle(color: Colors.red)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
          FilledButton(onPressed: _save, child: const Text('Lưu')),
        ],
      );
}
