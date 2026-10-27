import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final email = TextEditingController();
  final pass = TextEditingController();
  String? error;
  bool busy = false;

  Future<void> _login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithPassword(email: email.text.trim(), password: pass.text);
    } on AuthException catch (e) {
      setState(() => error = e.message);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: AutofillGroup(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('Bãi giữ xe', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 24),
                  TextField(
                    controller: email,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    autofillHints: const [AutofillHints.email],
                  ),
                  TextField(
                    controller: pass,
                    decoration: const InputDecoration(labelText: 'Mật khẩu'),
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _login(),
                  ),
                  if (error != null) Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(error!, style: const TextStyle(color: Colors.red)),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(onPressed: busy ? null : _login, child: const Text('Đăng nhập')),
                ]),
              ),
            ),
          ),
        ),
      );
}
