import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import 'main.dart' show prefs, showError, signOutAll;

const _key = 'bio_lock';
final _auth = LocalAuthentication();

bool get bioLockOn => prefs.getBool(_key) ?? false;

Future<bool> _verify(String reason) async {
  try {
    return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
  } on LocalAuthException {
    return false; // huỷ, sai quá số lần, chưa cài vân tay...
  }
}

/// Phiên đăng nhập được lưu 7 ngày: bật khoá thì mỗi lần mở app phải quét vân tay / khuôn mặt của điện thoại,
/// người khác cầm máy không vào được tài khoản (quản lý mở được barrier, khách xem được xe của mình).
class AppLock extends StatefulWidget {
  const AppLock({super.key, required this.child});

  final Widget child;

  @override
  State<AppLock> createState() => _AppLockState();
}

class _AppLockState extends State<AppLock> {
  late bool locked = bioLockOn;

  @override
  void initState() {
    super.initState();
    if (locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (await _verify('Mở khoá ứng dụng Bãi giữ xe') && mounted) setState(() => locked = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!locked) return widget.child;
    final s = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.fingerprint, size: 96, color: s.primary),
          const SizedBox(height: 16),
          Text('Ứng dụng đang khoá', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: _unlock, icon: const Icon(Icons.lock_open), label: const Text('Mở khoá')),
          TextButton(onPressed: signOutAll, child: const Text('Đăng xuất, đăng nhập lại bằng mật khẩu')),
        ]),
      ),
    );
  }
}

/// Công tắc bật / tắt khoá vân tay trong Cài đặt. Bật phải quét thành công 1 lần (máy có vân tay và đúng chủ).
class BioLockTile extends StatefulWidget {
  const BioLockTile({super.key});

  @override
  State<BioLockTile> createState() => _BioLockTileState();
}

class _BioLockTileState extends State<BioLockTile> {
  bool on = bioLockOn;

  Future<void> _toggle(bool v) async {
    if (v) {
      if (!await _auth.isDeviceSupported()) {
        if (mounted) showError(context, 'Điện thoại chưa cài vân tay / khuôn mặt / mã khoá màn hình');
        return;
      }
      if (!await _verify('Xác nhận bật khoá bằng vân tay')) return;
    }
    await prefs.setBool(_key, v);
    if (mounted) setState(() => on = v);
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        secondary: const Icon(Icons.fingerprint),
        title: const Text('Khoá ứng dụng bằng vân tay'),
        subtitle: const Text('Mở app phải quét vân tay / khuôn mặt'),
        value: on,
        onChanged: _toggle,
      );
}
