import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../google_auth.dart';
import '../main.dart' show deviceModeKey, fieldGap, prefs, showError;

/// Đăng nhập qua REST API (mật khẩu + mã OTP email, hoặc Google), 2 chế độ:
/// - Tài khoản: quản lý, bảo vệ, khách hàng.
/// - Thiết bị camera: ĐT gắn ở cổng, đăng nhập tài khoản quản lý rồi chọn vai trò của máy.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final user = TextEditingController();
  final pass = TextEditingController();
  bool device = false;
  bool busy = false;
  String? error;

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _login() => _run(() async {
        final username = user.text.trim().toLowerCase();
        final masked = await api.login(username, pass.text);
        if (!mounted) return;
        await Navigator.push(context, MaterialPageRoute(builder: (_) => OtpScreen(
              maskedEmail: masked,
              verify: (code) async {
                await prefs.setBool(deviceModeKey, device); // đặt trước khi có phiên để màn đầu tiên đúng chế độ
                return api.verifyLogin(username, code);
              },
              resend: () => api.login(username, pass.text),
            )));
      });

  Future<void> _google() => _run(() async {
        final idToken = await googleIdToken();
        if (idToken == null) return;
        await prefs.setBool(deviceModeKey, false);
        await api.loginWithGoogle(idToken);
      });

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return _AuthScaffold(
      icon: Icons.local_parking,
      title: 'Bãi giữ xe',
      subtitle: device ? 'Điện thoại gắn ở cổng: đăng nhập tài khoản quản lý' : 'Đăng nhập tài khoản quản lý / bảo vệ / khách hàng',
      child: AutofillGroup(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Tài khoản'), icon: Icon(Icons.person_outline)),
              ButtonSegment(value: true, label: Text('Thiết bị camera'), icon: Icon(Icons.videocam_outlined)),
            ],
            selected: {device},
            onSelectionChanged: (v) => setState(() {
              device = v.first;
              error = null;
            }),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: user,
            decoration: const InputDecoration(labelText: 'Tên đăng nhập', prefixIcon: Icon(Icons.person_outline)),
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
          ),
          fieldGap,
          TextField(
            controller: pass,
            decoration: const InputDecoration(labelText: 'Mật khẩu', prefixIcon: Icon(Icons.lock_outline)),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => _login(),
          ),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: s.error))),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : _login,
            child: busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Đăng nhập (gửi mã OTP)'),
          ),
          if (!device) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: busy ? null : _google,
              icon: const Icon(Icons.g_mobiledata, size: 28),
              label: const Text('Đăng nhập bằng Google'),
            ),
            TextButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterScreen())),
              child: const Text('Chưa có tài khoản? Đăng ký'),
            ),
          ],
        ]),
      ),
    );
  }
}

/// Đăng ký tài khoản API. Tài khoản mới là bảo vệ; admin nâng quyền và gắn hồ sơ bảo vệ sau.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final email = TextEditingController();
  final username = TextEditingController();
  final name = TextEditingController();
  final pass = TextEditingController();
  bool busy = false;

  Future<void> _submit() async {
    setState(() => busy = true);
    try {
      final e = email.text.trim().toLowerCase();
      final masked = await api.register(
          email: e, username: username.text.trim().toLowerCase(), password: pass.text, fullName: name.text.trim());
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute(builder: (_) => OtpScreen(
            maskedEmail: masked,
            verify: (code) => api.verifyRegister(e, code),
            resend: () => api.register(
                email: e, username: username.text.trim().toLowerCase(), password: pass.text, fullName: name.text.trim()),
          )));
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        icon: Icons.person_add_alt,
        title: 'Đăng ký',
        subtitle: 'Mã xác minh sẽ gửi tới email',
        back: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: email, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined)), keyboardType: TextInputType.emailAddress),
          fieldGap,
          TextField(controller: username, decoration: const InputDecoration(labelText: 'Tên đăng nhập (chữ thường, số, _ .)', prefixIcon: Icon(Icons.alternate_email))),
          fieldGap,
          TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Họ tên', prefixIcon: Icon(Icons.badge_outlined))),
          fieldGap,
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Mật khẩu (tối thiểu 6 ký tự)', prefixIcon: Icon(Icons.lock_outline))),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : _submit,
            child: busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Gửi mã xác minh'),
          ),
        ]),
      );
}

const _resendCooldown = 30;

/// Nhập mã OTP 6 số gửi qua email (dùng chung cho đăng ký và đăng nhập).
class OtpScreen extends StatefulWidget {
  const OtpScreen({super.key, required this.maskedEmail, required this.verify, required this.resend});

  final String maskedEmail;
  final Future<ApiUser> Function(String code) verify;
  final Future<void> Function() resend;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final code = TextEditingController();
  bool busy = false;
  int wait = _resendCooldown;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _cooldown();
  }

  void _cooldown() {
    timer?.cancel();
    setState(() => wait = _resendCooldown);
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (wait <= 1) t.cancel();
      setState(() => wait--);
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _submit() async {
    if (code.text.length != 6 || busy) return;
    setState(() => busy = true);
    try {
      await widget.verify(code.text);
      // Đã có phiên: gốc app tự chuyển màn, chỉ cần đóng các màn đăng nhập/đăng ký đang chồng lên.
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      code.clear();
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await widget.resend();
      _cooldown();
    } on ApiException catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        icon: Icons.mark_email_read_outlined,
        title: 'Nhập mã OTP',
        subtitle: 'Mã 6 số đã gửi tới ${widget.maskedEmail}',
        back: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: code,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 12, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(counterText: '', hintText: '••••••'),
            onChanged: (v) => v.length == 6 ? _submit() : null,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : _submit,
            child: busy ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Xác nhận'),
          ),
          TextButton(onPressed: wait > 0 ? null : _resend, child: Text(wait > 0 ? 'Gửi lại mã sau $wait giây' : 'Gửi lại mã')),
        ]),
      );
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.icon, required this.title, required this.subtitle, required this.child, this.back = false});

  final IconData icon;
  final String title, subtitle;
  final Widget child;
  final bool back;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: back ? AppBar() : null,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CircleAvatar(radius: 40, backgroundColor: s.primaryContainer, child: Icon(icon, size: 44, color: s.onPrimaryContainer)),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: t.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              Text(subtitle, textAlign: TextAlign.center, style: t.bodyMedium?.copyWith(color: s.onSurfaceVariant)),
              const SizedBox(height: 28),
              child,
            ]),
          ),
        ),
      ),
    );
  }
}
