import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'screens/camera_screen.dart';
import 'screens/cards_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/history_screen.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart';

const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseKey = String.fromEnvironment('SUPABASE_KEY');

late final SharedPreferences prefs;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isEmpty || supabaseKey.isEmpty) {
    runApp(const MaterialApp(
      home: Scaffold(body: Center(child: Text('Thiếu --dart-define SUPABASE_URL / SUPABASE_KEY'))),
    ));
    return;
  }
  await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseKey);
  prefs = await SharedPreferences.getInstance();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Bãi giữ xe',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: StreamBuilder<AuthState>(
          stream: Supabase.instance.client.auth.onAuthStateChange,
          builder: (_, _) =>
              Supabase.instance.client.auth.currentSession == null ? const LoginScreen() : const RoleHome(),
        ),
      );
}

/// Chọn vai trò một lần trên mỗi thiết bị: 'manager' | 'in' | 'out'.
class RoleHome extends StatefulWidget {
  const RoleHome({super.key});

  @override
  State<RoleHome> createState() => _RoleHomeState();
}

class _RoleHomeState extends State<RoleHome> {
  String? role = prefs.getString('role');

  void _set(String? r) {
    r == null ? prefs.remove('role') : prefs.setString('role', r);
    setState(() => role = r);
  }

  @override
  Widget build(BuildContext context) {
    void reset() => _set(null);
    return switch (role) {
      'in' || 'out' || 'both' => CameraScreen(gate: role!, onExit: reset),
      'manager' => ManagerHome(onChangeRole: reset),
      _ => Scaffold(
          appBar: AppBar(title: const Text('Chọn vai trò thiết bị')),
          body: ListView(children: [
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text('Quản lý'),
              onTap: () => _set('manager'),
            ),
            // camera package không hỗ trợ macOS
            if (!Platform.isMacOS) ...[
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Camera cổng vào'),
                onTap: () => _set('in'),
              ),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Camera cổng ra'),
                onTap: () => _set('out'),
              ),
              ListTile(
                leading: const Icon(Icons.compare_arrows),
                title: const Text('Camera cả 2 cổng'),
                subtitle: const Text('Chỉ có 1 điện thoại cho cả cổng vào và cổng ra'),
                onTap: () => _set('both'),
              ),
            ],
          ]),
        ),
    };
  }
}

class ManagerHome extends StatefulWidget {
  const ManagerHome({super.key, required this.onChangeRole});

  final VoidCallback onChangeRole;

  @override
  State<ManagerHome> createState() => _ManagerHomeState();
}

class _ManagerHomeState extends State<ManagerHome> {
  int tab = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: IndexedStack(index: tab, children: [
            const DashboardScreen(),
            const HistoryScreen(),
            const CardsScreen(),
            SettingsScreen(onChangeRole: widget.onChangeRole),
          ]),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.local_parking), label: 'Tổng quan'),
            NavigationDestination(icon: Icon(Icons.history), label: 'Lịch sử'),
            NavigationDestination(icon: Icon(Icons.credit_card), label: 'Thẻ'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Cài đặt'),
          ],
        ),
      );
}

/// Snackbar báo lỗi dùng chung cho các màn hình.
void showError(BuildContext context, Object e) {
  final msg = e is PostgrestException ? e.message : e.toString();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
}

/// Ảnh biển số trong bucket private 'plates'.
class PlateImage extends StatelessWidget {
  const PlateImage(this.path, {super.key, this.height = 200});

  final String? path;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (path == null) return SizedBox(height: height, child: const Center(child: Text('Không có ảnh')));
    return FutureBuilder<String>(
      future: Supabase.instance.client.storage.from('plates').createSignedUrl(path!, 3600),
      builder: (_, s) => s.hasData
          ? Image.network(s.data!, height: height, fit: BoxFit.contain)
          : SizedBox(height: height, child: Center(child: s.hasError ? Text('${s.error}') : const CircularProgressIndicator())),
    );
  }
}
