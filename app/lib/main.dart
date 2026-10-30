import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'api.dart';
import 'google_auth.dart';
import 'lock.dart';
import 'screens/accounts_screen.dart';
import 'screens/attendance_screen.dart';
import 'screens/customer_screen.dart';
import 'screens/camera_screen.dart';
import 'screens/cards_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/guards_screen.dart';
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
  api.restore(prefs);
  runApp(const App());
}

ThemeData _theme(Brightness b) {
  final s = ColorScheme.fromSeed(seedColor: const Color(0xFF00796B), brightness: b);
  final r12 = BorderRadius.circular(12);
  return ThemeData(
    colorScheme: s,
    useMaterial3: true,
    appBarTheme: AppBarTheme(centerTitle: true, backgroundColor: s.surface, scrolledUnderElevation: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: s.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: s.surfaceContainerHighest.withValues(alpha: 0.5),
      border: OutlineInputBorder(borderRadius: r12, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: r12, borderSide: BorderSide(color: s.primary, width: 2)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: r12)),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: r12)),
    ),
    listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: r12)),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// Khoảng cách giữa các ô nhập liệu (ô nền đặc đứng sát nhau trông như một khối).
const fieldGap = SizedBox(height: 12);

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Bãi giữ xe',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        // Tài khoản API (quản lý / bảo vệ) ưu tiên; không có thì phiên Supabase của ĐT camera.
        home: ValueListenableBuilder<ApiUser?>(
          valueListenable: api.session,
          builder: (_, user, _) => user != null
              ? AppLock(
                  key: ValueKey(user.username),
                  child: user.isStaff
                      ? ManagerHome(admin: user.role == 'admin')
                      : user.isCustomer
                          ? CustomerHome(user)
                          : GuardHome(user),
                )
              : StreamBuilder<AuthState>(
                  stream: Supabase.instance.client.auth.onAuthStateChange,
                  builder: (_, _) =>
                      Supabase.instance.client.auth.currentSession == null ? const LoginScreen() : const RoleHome(),
                ),
        ),
      );
}

/// Đăng xuất cả tài khoản API lẫn phiên Supabase (thiết bị camera).
Future<void> signOutAll() async {
  await googleSignOut();
  await api.logout();
  if (Supabase.instance.client.auth.currentSession != null) await Supabase.instance.client.auth.signOut();
}

/// Tài khoản bảo vệ: xem chỗ trống và bảng công của mình.
class GuardHome extends StatelessWidget {
  const GuardHome(this.user, {super.key});

  final ApiUser user;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('Xin chào, ${user.displayName}'),
          actions: [IconButton(onPressed: signOutAll, icon: const Icon(Icons.logout), tooltip: 'Đăng xuất')],
        ),
        body: user.guardId == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Tài khoản chưa được gắn với hồ sơ bảo vệ.\nNhờ quản trị viên gắn để xem bảng công.',
                      textAlign: TextAlign.center),
                ),
              )
            : const AttendanceScreen(path: '/me/attendance', embedded: true),
      );
}

/// Chọn vai trò một lần trên mỗi thiết bị: 'manager' | 'in' | 'out' | 'both'.
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
          appBar: AppBar(title: const Text('Thiết bị này dùng để')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            _RoleCard(Icons.dashboard, 'Quản lý', 'Xem xe trong bãi, lịch sử, thẻ, cài đặt', () => _set('manager')),
            // camera package không hỗ trợ macOS
            if (!Platform.isMacOS) ...[
              _RoleCard(Icons.login, 'Camera cổng vào', 'Gắn cố định nhìn biển số xe vào', () => _set('in')),
              _RoleCard(Icons.logout, 'Camera cổng ra', 'Gắn cố định nhìn biển số xe ra', () => _set('out')),
              _RoleCard(Icons.compare_arrows, 'Camera cả 2 cổng', 'Chỉ có 1 điện thoại cho cả cổng vào và cổng ra',
                  () => _set('both')),
            ],
          ]),
        ),
    };
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard(this.icon, this.title, this.subtitle, this.onTap);

  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
            radius: 24, backgroundColor: s.primaryContainer, child: Icon(icon, color: s.onPrimaryContainer)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

class ManagerHome extends StatefulWidget {
  const ManagerHome({super.key, this.onChangeRole, this.onShowCamera, this.admin = false});

  final VoidCallback? onChangeRole; // chỉ có trên thiết bị đăng nhập Supabase (chọn vai trò theo máy)
  final bool admin; // admin có thêm tab Tài khoản (quản trị người dùng)
  final VoidCallback? onShowCamera; // có trên ĐT camera: thêm mục "Camera" ở thanh dưới

  @override
  State<ManagerHome> createState() => _ManagerHomeState();
}

class _ManagerHomeState extends State<ManagerHome> {
  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const DashboardScreen(),
      const HistoryScreen(),
      const CardsScreen(),
      const GuardsScreen(),
      if (widget.admin) const AccountsScreen(embedded: true),
      SettingsScreen(onChangeRole: widget.onChangeRole),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        // Mục cuối "Camera" (chỉ trên ĐT camera) không phải trang: quay về màn camera.
        onDestinationSelected: (i) => i == pages.length ? widget.onShowCamera!() : setState(() => tab = i),
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected, // 6 mục: hiện hết nhãn thì chật
        destinations: [
          const NavigationDestination(icon: Icon(Icons.local_parking), label: 'Tổng quan'),
          const NavigationDestination(icon: Icon(Icons.history), label: 'Lịch sử'),
          const NavigationDestination(icon: Icon(Icons.credit_card), label: 'Thẻ'),
          const NavigationDestination(icon: Icon(Icons.security), label: 'Bảo vệ'),
          if (widget.admin) const NavigationDestination(icon: Icon(Icons.manage_accounts), label: 'Tài khoản'),
          const NavigationDestination(icon: Icon(Icons.settings), label: 'Cài đặt'),
          if (widget.onShowCamera != null) const NavigationDestination(icon: Icon(Icons.videocam), label: 'Camera'),
        ],
      ),
    );
  }
}

/// Snackbar báo lỗi dùng chung cho các màn hình.
void showError(BuildContext context, Object e) {
  final msg = e is PostgrestException ? e.message : e.toString();
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
}

/// Ảnh biển số trong bucket private 'plates' (API cấp link ký có hạn 1 giờ).
/// Khách hàng dùng [endpoint] '/me/plates/url': chỉ xem được ảnh xe của mình.
class PlateImage extends StatelessWidget {
  const PlateImage(this.path, {super.key, this.height = 200, this.endpoint = '/plates/url'});

  final String? path;
  final double height;
  final String endpoint;

  @override
  Widget build(BuildContext context) {
    if (path == null) return SizedBox(height: height, child: const Center(child: Text('Không có ảnh')));
    return FutureBuilder<String>(
      future: api.get(endpoint, {'path': path!}).then((r) => r['url'] as String),
      builder: (_, s) => s.hasData
          ? Image.network(s.data!, height: height, fit: BoxFit.contain,
              errorBuilder: (_, _, _) => SizedBox(
                  height: height, child: const Center(child: Text('Không tải được ảnh, kéo xuống để thử lại'))))
          : SizedBox(height: height, child: Center(child: s.hasError ? Text('${s.error}') : const CircularProgressIndicator())),
    );
  }
}
