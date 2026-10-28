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
  String query = '';

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
    final saved = await Navigator.push<bool>(
        context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => CardForm(card)));
    if (saved == true) _load();
  }

  Future<void> _delete(Rec c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Xoá thẻ?'),
        content: Text('Thẻ ${c['uid']}${c['plate'] != null ? ' (${c['plate']})' : ''} sẽ bị xoá.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _db.from('cards').delete().eq('uid', c['uid']);
      _load();
    } catch (e) {
      // Thẻ đã có lượt gửi thì FK chặn xoá: khoá thẻ thay vì xoá.
      if (mounted) showError(context, 'Không xoá được (thẻ đã có lịch sử) - hãy mở thẻ và tắt "Đang hoạt động". $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final q = query.toUpperCase();
    final shown = q.isEmpty
        ? cards
        : cards.where((c) => [c['uid'], c['plate'], c['owner']].any((v) => '${v ?? ''}'.toUpperCase().contains(q))).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add_card),
        label: const Text('Thêm thẻ'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: TextField(
            decoration: const InputDecoration(hintText: 'Tìm UID, biển số, chủ xe', prefixIcon: Icon(Icons.search)),
            onChanged: (v) => setState(() => query = v.trim()),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Text('${shown.length} thẻ', style: TextStyle(color: s.onSurfaceVariant)),
            const Spacer(),
            Text('${cards.where((c) => c['kind'] == 'monthly').length} vé tháng',
                style: TextStyle(color: s.onSurfaceVariant)),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: shown.isEmpty
                ? ListView(children: [
                    const SizedBox(height: 80),
                    Icon(Icons.credit_card_off, size: 64, color: s.outline),
                    const SizedBox(height: 12),
                    Text(cards.isEmpty ? 'Chưa có thẻ nào. Bấm "Thêm thẻ" để bắt đầu.' : 'Không tìm thấy thẻ',
                        textAlign: TextAlign.center, style: TextStyle(color: s.onSurfaceVariant)),
                  ])
                : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 96), children: [
                    for (final c in shown) _CardTile(c, onTap: () => _edit(c), onDelete: () => _delete(c)),
                  ]),
          ),
        ),
      ]),
    );
  }
}

class _CardTile extends StatelessWidget {
  const _CardTile(this.c, {required this.onTap, required this.onDelete});

  final Rec c;
  final VoidCallback onTap, onDelete;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final monthly = c['kind'] == 'monthly';
    final active = c['active'] == true;
    final plate = c['plate'] as String?;
    final info = [if (plate != null) 'UID ${c['uid']}', if (c['owner'] != null) c['owner']].join(' · ');
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        leading: CircleAvatar(
          backgroundColor: !active ? s.surfaceContainerHighest : monthly ? s.tertiaryContainer : s.primaryContainer,
          child: Icon(monthly ? Icons.event_repeat : Icons.credit_card,
              color: !active ? s.outline : monthly ? s.onTertiaryContainer : s.onPrimaryContainer),
        ),
        title: Text(plate ?? c['uid'] as String,
            style: TextStyle(fontWeight: FontWeight.w600, color: active ? null : s.outline)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (info.isNotEmpty) Text(info),
          const SizedBox(height: 4),
          Wrap(spacing: 6, children: [
            _Tag(monthly ? 'Vé tháng' : 'Vé lượt', monthly ? s.tertiary : s.primary),
            if (!active) _Tag('Đã khoá', s.error),
          ]),
        ]),
        isThreeLine: info.isNotEmpty,
        onTap: onTap,
        trailing: IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Xoá', onPressed: onDelete),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}

/// Thêm / sửa thẻ. Thêm mới: tự chờ quẹt thẻ ở cổng bất kỳ để lấy UID (vẫn nhập tay được).
class CardForm extends StatefulWidget {
  const CardForm(this.card, {super.key});

  final Rec? card;

  @override
  State<CardForm> createState() => _CardFormState();
}

class _CardFormState extends State<CardForm> {
  late final uid = TextEditingController(text: widget.card?['uid'] as String?);
  late final plate = TextEditingController(text: widget.card?['plate'] as String?);
  late final owner = TextEditingController(text: widget.card?['owner'] as String?);
  late String kind = widget.card?['kind'] as String? ?? 'guest';
  late bool active = widget.card?['active'] as bool? ?? true;
  RealtimeChannel? listening;
  Rec? existing; // thẻ vừa quẹt đã có trong hệ thống
  String? error;
  bool saving = false;

  bool get isNew => widget.card == null;

  @override
  void initState() {
    super.initState();
    if (isNew) _waitScan();
  }

  /// Chờ lần quẹt thẻ kế tiếp ở bất kỳ cổng nào để lấy UID.
  /// ĐT camera ghi gate_events sau khi xử lý xong lượt quẹt (~2-3s), nên cần ĐT camera đang chạy.
  void _waitScan() {
    setState(() {
      existing = null;
      listening = _db
          .channel('enroll')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'gate_events',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'kind', value: 'scan'),
            callback: (p) => _onScanned(p.newRecord['uid'] as String),
          )
          .subscribe();
    });
  }

  Future<void> _onScanned(String u) async {
    _stopScan();
    uid.text = u;
    try {
      final r = await _db.from('cards').select().eq('uid', u).maybeSingle();
      if (mounted) setState(() => existing = r);
    } catch (_) {} // không kiểm tra được thì để lúc Lưu báo trùng
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
    if (!_uidRe.hasMatch(u)) return setState(() => error = 'UID phải là 8-20 ký tự hex (0-9, A-F)');
    if (kind == 'monthly' && p.isEmpty) return setState(() => error = 'Vé tháng cần biển số');
    final row = {
      'uid': u,
      'kind': kind,
      'plate': p.isEmpty ? null : p,
      'owner': owner.text.trim().isEmpty ? null : owner.text.trim(),
      'active': active,
    };
    setState(() {
      saving = true;
      error = null;
    });
    try {
      isNew ? await _db.from('cards').insert(row) : await _db.from('cards').update(row).eq('uid', widget.card!['uid']);
      if (mounted) Navigator.pop(context, true);
    } on PostgrestException catch (e) {
      setState(() => error = e.code == '23505' ? 'Thẻ $u đã có trong hệ thống' : e.message);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'Thêm thẻ' : 'Sửa thẻ')),
      // padding riêng làm ListView bỏ khoảng an toàn đáy -> nút Lưu bị thanh điều hướng Android che
      body: SafeArea(top: false, child: ListView(padding: const EdgeInsets.all(16), children: [
        if (isNew) ...[
          _ScanPanel(
            listening: listening != null,
            uid: uid.text,
            onRescan: _waitScan,
            onCancel: _stopScan,
          ),
          if (existing != null)
            Card(
              color: s.errorContainer,
              child: ListTile(
                leading: Icon(Icons.warning_amber, color: s.onErrorContainer),
                title: Text('Thẻ này đã có', style: TextStyle(color: s.onErrorContainer, fontWeight: FontWeight.w600)),
                subtitle: Text(
                    [existing!['plate'] ?? 'chưa có biển', existing!['owner']].whereType<String>().join(' · '),
                    style: TextStyle(color: s.onErrorContainer)),
                trailing: TextButton(
                  onPressed: () => Navigator.pushReplacement(context,
                      MaterialPageRoute(fullscreenDialog: true, builder: (_) => CardForm(existing))),
                  child: const Text('Mở để sửa'),
                ),
              ),
            ),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: uid,
          enabled: isNew,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'UID thẻ', prefixIcon: Icon(Icons.nfc), helperText: 'Tự điền khi quẹt thẻ, hoặc nhập tay'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 20),
        Text('Loại vé', style: t.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'guest', label: Text('Vé lượt'), icon: Icon(Icons.credit_card)),
            ButtonSegment(value: 'monthly', label: Text('Vé tháng'), icon: Icon(Icons.event_repeat)),
          ],
          selected: {kind},
          onSelectionChanged: (v) => setState(() => kind = v.first),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: plate,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: kind == 'monthly' ? 'Biển số (bắt buộc)' : 'Biển số (không bắt buộc)',
            prefixIcon: const Icon(Icons.pin_outlined),
            helperText: kind == 'monthly' ? 'Vé tháng: xe ra phải đúng biển này' : null,
          ),
        ),
        fieldGap,
        TextField(
          controller: owner,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Chủ xe', prefixIcon: Icon(Icons.person_outline)),
        ),
        if (!isNew) ...[
          fieldGap,
          Card(
            child: SwitchListTile(
              title: const Text('Đang hoạt động'),
              subtitle: const Text('Tắt để khoá thẻ (mất thẻ, hết hạn vé tháng)'),
              value: active,
              onChanged: (v) => setState(() => active = v),
            ),
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error!, style: TextStyle(color: s.error)),
          ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: saving ? null : _save,
          icon: saving
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.check),
          label: Text(isNew ? 'Thêm thẻ' : 'Lưu thay đổi'),
        ),
      ])),
    );
  }
}

/// Khung lớn ở đầu màn thêm thẻ: đang chờ quẹt / đã nhận UID.
class _ScanPanel extends StatelessWidget {
  const _ScanPanel({required this.listening, required this.uid, required this.onRescan, required this.onCancel});

  final bool listening;
  final String uid;
  final VoidCallback onRescan, onCancel;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final got = !listening && uid.isNotEmpty;
    return Card(
      color: got ? s.primaryContainer : s.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Icon(got ? Icons.check_circle : Icons.contactless,
              size: 56, color: got ? s.onPrimaryContainer : s.onSecondaryContainer),
          const SizedBox(height: 8),
          Text(
            listening ? 'Quẹt thẻ ở đầu đọc bất kỳ' : got ? 'Đã nhận thẻ' : 'Đã dừng chờ quẹt thẻ',
            style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (got) Text(uid, style: t.headlineSmall?.copyWith(fontFamily: 'monospace', letterSpacing: 2)),
          if (listening) ...[
            const SizedBox(height: 4),
            Text('Cần ĐT camera ở cổng đang mở app', style: t.bodySmall),
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 8),
          listening
              ? TextButton(onPressed: onCancel, child: const Text('Nhập tay'))
              : TextButton.icon(onPressed: onRescan, icon: const Icon(Icons.refresh), label: const Text('Quẹt lại')),
        ]),
      ),
    );
  }
}
