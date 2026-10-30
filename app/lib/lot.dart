import 'package:flutter/material.dart';

import 'api.dart';
import 'logic.dart';

/// Loại xe + bảng giá từ API (GET /vehicle-types), nhớ trong phiên chạy app. Sửa giá xong gọi [reloadVehicleTypes].
List<Rec>? _types;

Future<List<Rec>> vehicleTypes({bool reload = false}) async {
  if (_types == null || reload) _types = ((await api.get('/vehicle-types')) as List).cast<Rec>();
  return _types!;
}

Future<List<Rec>> reloadVehicleTypes() => vehicleTypes(reload: true);

const _names = {'motorbike': 'Xe máy', 'car': 'Ô tô', 'bicycle': 'Xe đạp'};

String vehicleName(String? code) =>
    _types?.firstWhere((t) => t['code'] == code, orElse: () => const {})['name'] as String? ?? _names[code] ?? code ?? 'Xe máy';

IconData vehicleIcon(String? code) => switch (code) {
      'car' => Icons.directions_car,
      'bicycle' => Icons.pedal_bike,
      _ => Icons.two_wheeler,
    };

/// "1.500.000đ"
String vnd(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer(v < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return '$bđ';
}

/// Màu từng trạng thái ô: trống (khách vãng lai), ô riêng cư dân (đang trống), có xe, tạm khoá.
Color slotColor(ColorScheme s, String state) => switch (state) {
      'parked' => s.error,
      'resident' => s.tertiary,
      'off' => s.outline,
      _ => Colors.green,
    };

const slotStateNames = {'free': 'Trống', 'resident': 'Ô cư dân', 'parked': 'Có xe', 'off': 'Tạm khoá'};

/// Sơ đồ bãi: mỗi khu là một lưới ô, tô màu theo trạng thái. [highlight] = ô cần chỉ (ô của cư dân / ô vừa chỉ cho khách).
class LotMapView extends StatelessWidget {
  const LotMapView(this.map, {super.key, this.highlight, this.onSlot, this.onZone, this.compact = false});

  final Rec map; // GET /lot/map hoặc /lot/map/public
  final String? highlight;
  final void Function(Rec slot)? onSlot;
  final void Function(Rec zone)? onZone;
  final bool compact; // màn camera cổng: ô nhỏ, không chú thích

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final zones = (map['zones'] as List).cast<Rec>();
    if (zones.isEmpty) {
      return const Padding(padding: EdgeInsets.all(24), child: Text('Chưa vẽ sơ đồ bãi', textAlign: TextAlign.center));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!compact)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(spacing: 12, runSpacing: 4, children: [
            for (final e in slotStateNames.entries)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 12, height: 12, decoration: BoxDecoration(color: slotColor(s, e.key), borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: 4),
                Text(e.value, style: t.labelSmall),
              ]),
          ]),
        ),
      for (final z in zones) ...[
        InkWell(
          onTap: onZone == null ? null : () => onZone!(z),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Icon(vehicleIcon(z['vehicle_type'] as String?), size: 18),
              const SizedBox(width: 6),
              Text('Khu ${z['name']} · ${vehicleName(z['vehicle_type'] as String?)}', style: t.titleSmall),
              const Spacer(),
              Text('${(z['slots'] as List).where((x) => x['state'] == 'free').length} trống', style: t.labelMedium),
              if (onZone != null) const Icon(Icons.more_vert, size: 18),
            ]),
          ),
        ),
        _ZoneGrid(z, highlight: highlight, onSlot: onSlot, compact: compact),
        const SizedBox(height: 8),
      ],
      if (!compact)
        Row(children: [
          Icon(Icons.login, size: 16, color: s.onSurfaceVariant),
          const SizedBox(width: 4),
          Text('Cổng vào ở phía trên: khu đầu tiên gần cổng nhất', style: t.labelSmall?.copyWith(color: s.onSurfaceVariant)),
        ]),
    ]);
  }
}

class _ZoneGrid extends StatelessWidget {
  const _ZoneGrid(this.zone, {this.highlight, this.onSlot, this.compact = false});

  final Rec zone;
  final String? highlight;
  final void Function(Rec slot)? onSlot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final cols = zone['cols'] as int;
    final slots = (zone['slots'] as List).cast<Rec>();
    return GridView.count(
      crossAxisCount: cols,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 4,
      crossAxisSpacing: 4,
      childAspectRatio: compact ? 1.4 : 1.1,
      children: [
        for (final sl in slots)
          () {
            final hit = sl['code'] == highlight;
            final c = slotColor(s, sl['state'] as String);
            return Material(
              color: c.withValues(alpha: hit ? 1 : 0.18),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: BorderSide(color: hit ? s.onSurface : c, width: hit ? 3 : 1),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onSlot == null ? null : () => onSlot!(sl),
                child: Center(
                  child: FittedBox(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Text(
                        (sl['code'] as String).split('-').last,
                        style: TextStyle(fontWeight: FontWeight.bold, color: hit ? s.surface : null),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }(),
      ],
    );
  }
}
