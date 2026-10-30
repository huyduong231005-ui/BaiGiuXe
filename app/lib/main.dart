import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import 'screens/lot_map_screen.dart';
import 'screens/ocr_stats_screen.dart';
import 'screens/revenue_screen.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart';

late final SharedPreferences prefs;

/// Khoá prefs: máy này đăng nhập ở chế độ "Thiết bị camera" (chọn vai trò theo máy: quản lý / camera cổng).
const deviceModeKey = 'device_mode';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
        // Mọi thứ qua REST API. ĐT gắn ở cổng đăng nhập tài khoản quản lý ở chế độ "Thiết bị camera"
        // rồi chọn vai trò của máy (camera cổng vào / ra / cả 2, hoặc quản lý).
        home: ValueListenableBuilder<ApiUser?>(
          valueListenable: api.session,
          builder: (_, user, _) => user == null
              ? const LoginScreen()
              : user.isStaff && (prefs.getBool(deviceModeKey) ?? false)
                  ? RoleHome(admin: user.role == 'admin')
                  : AppLock(
                      key: ValueKey(user.username),
                      child: user.isStaff
                          ? ManagerHome(admin: user.role == 'admin')
                          : user.isCustomer
                              ? CustomerHome(user)
                              : GuardHome(user),
                    ),
        ),
      );
}

/// Đăng xuất (cả Google nếu có); máy camera thôi ở chế độ thiết bị.
Future<void> signOutAll() async {
  await googleSignOut();
  await prefs.remove(deviceModeKey);
  await api.logout();
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
  const RoleHome({super.key, this.admin = false});

  final bool admin;

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
      'manager' => ManagerHome(onChangeRole: reset, admin: widget.admin),
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

  final VoidCallback? onChangeRole; // chỉ có ở chế độ thiết bị camera (chọn vai trò theo máy)
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
      const LotMapScreen(),
      const RevenueScreen(),
      const CardsScreen(),
      MoreScreen(admin: widget.admin, onChangeRole: widget.onChangeRole),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: tab, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        // Mục cuối "Camera" (chỉ trên ĐT camera) không phải trang: quay về màn camera.
        onDestinationSelected: (i) => i == pages.length ? widget.onShowCamera!() : setState(() => tab = i),
        destinations: [
          const NavigationDestination(icon: Icon(Icons.local_parking), label: 'Tổng quan'),
          const NavigationDestination(icon: Icon(Icons.grid_view), label: 'Sơ đồ'),
          const NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Doanh thu'),
          const NavigationDestination(icon: Icon(Icons.credit_card), label: 'Thẻ'),
          const NavigationDestination(icon: Icon(Icons.menu), label: 'Khác'),
          if (widget.onShowCamera != null) const NavigationDestination(icon: Icon(Icons.videocam), label: 'Camera'),
        ],
      ),
    );
  }
}

/// Các màn ít dùng hơn: lịch sử, bảo vệ, tài khoản (admin), thống kê nhận diện biển, cài đặt.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key, this.admin = false, this.onChangeRole});

  final bool admin;
  final VoidCallback? onChangeRole;

  void _open(BuildContext context, String title, Widget body) => Navigator.push(context,
      MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: SafeArea(child: body))));

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.history, 'Lịch sử ra vào', 'Lượt gửi theo ngày, tìm biển số, ảnh xe', () => _open(context, 'Lịch sử', const HistoryScreen())),
      (Icons.security, 'Bảo vệ & bảng công', 'Bảo vệ, PIN, vân tay, ca trực, chấm công', () => _open(context, 'Bảo vệ', const GuardsScreen())),
      if (admin)
        (Icons.manage_accounts, 'Tài khoản', 'Phân quyền admin / quản lý / bảo vệ / khách', () => _open(context, 'Tài khoản', const AccountsScreen(embedded: true))),
      (Icons.document_scanner_outlined, 'Nhận diện biển số', 'Tốc độ, độ chính xác đo trên các lượt quẹt thật',
          () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OcrStatsScreen()))),
      (Icons.settings, 'Cài đặt', 'Loại xe & bảng giá, thông tin bãi, ca trực, đăng xuất',
          () => _open(context, 'Cài đặt', SettingsScreen(onChangeRole: onChangeRole))),
    ];
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Khác', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      for (final (icon, title, sub, onTap) in items)
        _RoleCard(icon, title, sub, onTap),
    ]);
  }
}

/// Snackbar báo lỗi dùng chung cho các màn hình.
void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'), backgroundColor: Colors.red));
}

/// Ảnh biển số lưu trên API (MongoDB), xem qua link ký có hạn 1 giờ.
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
