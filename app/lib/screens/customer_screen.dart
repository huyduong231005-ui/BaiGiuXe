import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../lock.dart';
import '../logic.dart';
import '../main.dart';
import 'accounts_screen.dart' show ProfileScreen;
import 'dashboard_screen.dart' show hhmm;

const _myImages = '/me/plates/url';

String _dmy(String? ymd) {
  if (ymd == null) return '-';
  final p = ymd.substring(0, 10).split('-');
  return '${p[2]}/${p[1]}/${p[0]}';
}

/// Khách hàng = chủ vé tháng: xe của tôi, lịch sử ra vào, đơn vé tháng, thông tin bãi.
class CustomerHome extends StatefulWidget {
  const CustomerHome(this.user, {super.key});

  final ApiUser user;

  @override
  State<CustomerHome> createState() => _CustomerHomeState();
}

class _CustomerHomeState extends State<CustomerHome> {
  int tab = 0;
  static const _titles = ['Xe của tôi', 'Lịch sử ra vào', 'Vé tháng', 'Bãi xe'];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_titles[tab])),
        body: IndexedStack(index: tab, children: [
          _MyCards(onRequest: () => setState(() => tab = 2)),
          const _MyHistory(),
          const _MyRequests(),
          _LotInfo(user: widget.user),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.two_wheeler), label: 'Xe của tôi'),
            NavigationDestination(icon: Icon(Icons.history), label: 'Lịch sử'),
            NavigationDestination(icon: Icon(Icons.event_repeat), label: 'Vé tháng'),
            NavigationDestination(icon: Icon(Icons.local_parking), label: 'Bãi xe'),
          ],
        ),
      );
}

// ---------------------------------------------------------------- Xe của tôi

class _MyCards extends StatefulWidget {
  const _MyCards({required this.onRequest});

  final VoidCallback onRequest;

  @override
  State<_MyCards> createState() => _MyCardsState();
}

class _MyCardsState extends State<_MyCards> {
  List<Rec>? cards;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/me/cards') as List;
      if (mounted) setState(() => cards = r.cast<Rec>());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _lost(Rec c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        icon: const Icon(Icons.report_outlined),
        title: Text('Báo mất thẻ ${c['plate']}?'),
        content: const Text('Thẻ bị khoá ngay: ai cầm thẻ này cũng không vào / ra được. '
            'Xe đang trong bãi thì ra cổng trình giấy tờ cho bảo vệ. Liên hệ quản lý để cấp thẻ mới.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Huỷ')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Khoá thẻ'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.post('/me/cards/${c['uid']}/lost');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final list = cards;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (list == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
        if (list != null && list.isEmpty)
          Card(
            color: s.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(children: [
                Icon(Icons.event_repeat, size: 48, color: s.onSecondaryContainer),
                const SizedBox(height: 8),
                const Text('Bạn chưa có vé tháng', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                const Text('Gửi đơn đăng ký, quản lý duyệt và cấp thẻ cho bạn.', textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.icon(onPressed: widget.onRequest, icon: const Icon(Icons.add), label: const Text('Đăng ký vé tháng')),
              ]),
            ),
          ),
        for (final c in list ?? const <Rec>[]) _CardView(c, onLost: () => _lost(c), onChanged: _load),
      ]),
    );
  }
}

class _CardView extends StatelessWidget {
  const _CardView(this.c, {required this.onLost, required this.onChanged});

  final Rec c;
  final VoidCallback onLost, onChanged;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final lost = c['lost_at'] != null;
    final valid = c['valid'] == true;
    final parked = c['session_id'] != null;
    final (label, color) = lost
        ? ('Đã báo mất', s.error)
        : !valid
            ? ('Hết hạn ${_dmy(c['valid_until'] as String?)}', s.error)
            : c['valid_until'] == null
                ? ('Vé tháng', Colors.green.shade700)
                : ('Còn hạn đến ${_dmy(c['valid_until'] as String?)}', Colors.green.shade700);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(c['plate'] as String? ?? '-',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
            ),
          ]),
          if (c['owner'] != null) Text('Chủ xe: ${c['owner']}'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: (parked ? s.primaryContainer : s.surfaceContainerHighest).withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              Icon(parked ? Icons.local_parking : Icons.directions_bike_outlined, color: parked ? s.primary : s.outline),
              const SizedBox(width: 12),
              Expanded(
                child: Text(parked
                    ? 'Xe đang trong bãi từ ${hhmm(c['parked_since'] as String)}'
                        '${(c['fee_now'] as int? ?? 0) > 0 ? ' · phí nếu ra bây giờ ${c['fee_now']} đ' : ' · miễn phí (vé tháng)'}'
                    : 'Xe không ở trong bãi'),
              ),
            ]),
          ),
          if (parked && c['parked_img'] != null) ...[
            const SizedBox(height: 8),
            PlateImage(c['parked_img'] as String, height: 140, endpoint: _myImages),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (!lost)
              FilledButton.tonalIcon(
                onPressed: () => showDialog(context: context, builder: (_) => _TicketQr(c)),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Mã QR vé'),
              ),
            OutlinedButton.icon(
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => RequestForm(renewCard: c)));
                onChanged();
              },
              icon: const Icon(Icons.update),
              label: const Text('Gia hạn'),
            ),
            if (!lost)
              TextButton.icon(
                onPressed: onLost,
                style: TextButton.styleFrom(foregroundColor: s.error),
                icon: const Icon(Icons.report_outlined),
                label: const Text('Báo mất thẻ'),
              ),
          ]),
        ]),
      ),
    );
  }
}

/// Mã QR vé xe: API ký, hết hạn sau 10 phút nên tự lấy mã mới mỗi 9 phút. Quản lý quét để tra xe đang gửi.
class _TicketQr extends StatefulWidget {
  const _TicketQr(this.card);

  final Rec card;

  @override
  State<_TicketQr> createState() => _TicketQrState();
}

class _TicketQrState extends State<_TicketQr> {
  String? qr, error;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _fetch();
    timer = Timer.periodic(const Duration(minutes: 9), (_) => _fetch());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final r = await api.get('/me/cards/${widget.card['uid']}/qr') as Rec;
      if (mounted) setState(() => qr = r['qr'] as String);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Vé xe ${widget.card['plate']}', textAlign: TextAlign.center),
        content: SizedBox(
          width: 260,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (qr != null)
              Container(color: Colors.white, padding: const EdgeInsets.all(8), child: QrImageView(data: qr!, size: 240))
            else
              SizedBox(height: 240, child: Center(child: error != null ? Text(error!) : const CircularProgressIndicator())),
            const SizedBox(height: 8),
            const Text('Đưa mã cho bảo vệ / quản lý quét. Mã tự đổi sau mỗi 10 phút.', textAlign: TextAlign.center),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Đóng'))],
      );
}

// ---------------------------------------------------------------- Lịch sử ra vào

class _MyHistory extends StatefulWidget {
  const _MyHistory();

  @override
  State<_MyHistory> createState() => _MyHistoryState();
}

class _MyHistoryState extends State<_MyHistory> {
  List<Rec>? rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/me/sessions') as List;
      if (mounted) setState(() => rows = r.cast<Rec>());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _show(Rec s) => showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('${s['plate_in'] ?? '?'} → ${s['plate_out'] ?? (s['time_out'] == null ? 'đang gửi' : '?')}'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Vào ${hhmm(s['time_in'] as String)}'),
              PlateImage(s['img_in'] as String?, height: 180, endpoint: _myImages),
              if (s['time_out'] != null) ...[
                const SizedBox(height: 8),
                Text('Ra ${hhmm(s['time_out'] as String)} · phí ${s['fee'] ?? 0} đ'),
                PlateImage(s['img_out'] as String?, height: 180, endpoint: _myImages),
              ],
              if (s['override_name'] != null) Text('Bảo vệ ${s['override_name']} mở tay'),
              const SizedBox(height: 8),
              const Text('Không phải bạn lấy xe? Báo ngay cho bảo vệ / quản lý bãi.', style: TextStyle(fontStyle: FontStyle.italic)),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          if (rows == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
          if (rows != null && rows!.isEmpty) const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('Chưa có lượt gửi nào'))),
          for (final s in rows ?? const <Rec>[])
            ListTile(
              leading: Icon(s['time_out'] == null ? Icons.local_parking : Icons.logout,
                  color: s['time_out'] == null ? Colors.green.shade700 : null),
              title: Text(s['plate_in'] as String? ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('Vào ${hhmm(s['time_in'] as String)} · Ra ${hhmm(s['time_out'] as String?)}'),
              trailing: Text(s['time_out'] == null ? 'Đang gửi' : '${s['fee'] ?? 0} đ'),
              onTap: () => _show(s),
            ),
        ]),
      );
}

// ---------------------------------------------------------------- Đơn vé tháng

const _statusNames = {'pending': 'Chờ duyệt', 'approved': 'Đã duyệt', 'rejected': 'Từ chối', 'cancelled': 'Đã huỷ'};

Color statusColor(BuildContext context, String status) => switch (status) {
      'approved' => Colors.green.shade700,
      'rejected' => Theme.of(context).colorScheme.error,
      'pending' => Colors.orange.shade800,
      _ => Theme.of(context).colorScheme.outline,
    };

class _MyRequests extends StatefulWidget {
  const _MyRequests();

  @override
  State<_MyRequests> createState() => _MyRequestsState();
}

class _MyRequestsState extends State<_MyRequests> {
  List<Rec>? rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/me/requests') as List;
      if (mounted) setState(() => rows = r.cast<Rec>());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _open([Rec? r]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => RequestForm(request: r)));
    _load();
  }

  Future<void> _delete(Rec r) async {
    try {
      await api.delete('/me/requests/${r['id']}');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
            onPressed: _open, icon: const Icon(Icons.add), label: const Text('Đăng ký vé tháng')),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
            if (rows == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
            if (rows != null && rows!.isEmpty)
              const Padding(padding: EdgeInsets.all(48), child: Center(child: Text('Chưa có đơn nào', textAlign: TextAlign.center))),
            for (final r in rows ?? const <Rec>[])
              Card(
                child: ListTile(
                  title: Text('${r['plate']} · ${r['months']} tháng', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text([
                    '${r['card_uid'] != null ? 'Gia hạn' : 'Đăng ký mới'} · gửi ${hhmm(r['created_at'] as String)}',
                    if (r['reply'] != null) 'Quản lý: ${r['reply']}',
                  ].join('\n')),
                  isThreeLine: r['reply'] != null,
                  leading: Icon(Icons.circle, size: 14, color: statusColor(context, r['status'] as String)),
                  trailing: r['status'] == 'pending'
                      ? IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Huỷ đơn', onPressed: () => _delete(r))
                      : Text(_statusNames[r['status']] ?? '', style: TextStyle(color: statusColor(context, r['status'] as String))),
                  onTap: r['status'] == 'pending' ? () => _open(r) : null,
                ),
              ),
          ]),
        ),
      );
}

/// Gửi / sửa đơn vé tháng. [renewCard]: gia hạn thẻ đang có (biển, chủ xe điền sẵn).
class RequestForm extends StatefulWidget {
  const RequestForm({super.key, this.request, this.renewCard});

  final Rec? request;
  final Rec? renewCard;

  @override
  State<RequestForm> createState() => _RequestFormState();
}

class _RequestFormState extends State<RequestForm> {
  late final plate = TextEditingController(text: (widget.request ?? widget.renewCard)?['plate'] as String?);
  late final owner = TextEditingController(
      text: widget.request?['owner_name'] as String? ?? widget.renewCard?['owner'] as String? ?? api.session.value?.fullName);
  late final note = TextEditingController(text: widget.request?['note'] as String?);
  late int months = widget.request?['months'] as int? ?? 1;
  bool busy = false;

  bool get renew => widget.renewCard != null || widget.request?['card_uid'] != null;

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      final body = {
        'plate': plate.text,
        'ownerName': owner.text.trim(),
        'months': months,
        'note': note.text.trim(),
        if (widget.renewCard != null) 'cardUid': widget.renewCard!['uid'],
      };
      widget.request == null ? await api.post('/me/requests', body) : await api.patch('/me/requests/${widget.request!['id']}', body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã gửi đơn, chờ quản lý duyệt')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.request != null ? 'Sửa đơn' : renew ? 'Gia hạn vé tháng' : 'Đăng ký vé tháng')),
        body: SafeArea(
          top: false,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            TextField(
              controller: plate,
              enabled: !renew,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Biển số xe', prefixIcon: Icon(Icons.pin_outlined), helperText: 'VD: 59X1-123.45'),
            ),
            fieldGap,
            TextField(
              controller: owner,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Tên chủ xe', prefixIcon: Icon(Icons.person_outline)),
            ),
            const SizedBox(height: 20),
            Text('Số tháng: $months', style: Theme.of(context).textTheme.titleSmall),
            Slider(value: months.toDouble(), min: 1, max: 12, divisions: 11, label: '$months tháng',
                onChanged: (v) => setState(() => months = v.round())),
            TextField(
              controller: note,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Ghi chú (loại xe, màu, số điện thoại...)', prefixIcon: Icon(Icons.notes)),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(onPressed: busy ? null : _save, icon: const Icon(Icons.send), label: const Text('Gửi đơn')),
          ]),
        ),
      );
}

// ---------------------------------------------------------------- Bãi xe + tài khoản

class _LotInfo extends StatefulWidget {
  const _LotInfo({required this.user});

  final ApiUser user;

  @override
  State<_LotInfo> createState() => _LotInfoState();
}

class _LotInfoState extends State<_LotInfo> {
  Rec? lot;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/lot') as Rec;
      if (mounted) setState(() => lot = r);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Mở Google Maps (hoặc app bản đồ mặc định) chỉ đường tới bãi.
  Future<void> _directions(num lat, num lng) async {
    final url = Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication) && mounted) showError(context, 'Không mở được bản đồ');
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final l = lot;
    final lat = l?['lat'] as num?, lng = l?['lng'] as num?;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (l == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
        if (l != null) ...[
          Card(
            color: s.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l['name'] as String, style: t.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: s.onPrimaryContainer)),
                if (l['address'] != null) Text(l['address'] as String, style: TextStyle(color: s.onPrimaryContainer)),
                const SizedBox(height: 12),
                Text('Còn trống ${l['free']} / ${l['capacity']} chỗ', style: t.headlineSmall?.copyWith(color: s.onPrimaryContainer)),
                Text('Giá ngày ${l['priceDay']} đ · mỗi đêm ${l['priceNight']} đ (qua ${l['nightMark']}) · vé tháng miễn phí lượt',
                    style: TextStyle(color: s.onPrimaryContainer)),
              ]),
            ),
          ),
          if (lat != null && lng != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                height: 220,
                child: FlutterMap(
                  options: MapOptions(initialCenter: LatLng(lat.toDouble(), lng.toDouble()), initialZoom: 16),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'vn.baigiuxe.bai_giu_xe'),
                    MarkerLayer(markers: [
                      Marker(point: LatLng(lat.toDouble(), lng.toDouble()), width: 44, height: 44,
                          child: Icon(Icons.location_on, size: 44, color: s.error)),
                    ]),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(onPressed: () => _directions(lat, lng), icon: const Icon(Icons.directions), label: const Text('Chỉ đường tới bãi')),
          ],
        ],
        const SizedBox(height: 20),
        Text('Tài khoản', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(widget.user.displayName),
              subtitle: Text('${widget.user.email} · đổi họ tên, mật khẩu'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen())),
            ),
            const BioLockTile(),
            ListTile(
              leading: Icon(Icons.logout, color: s.error),
              title: Text('Đăng xuất', style: TextStyle(color: s.error)),
              onTap: signOutAll,
            ),
          ]),
        ),
      ]),
    );
  }
}
