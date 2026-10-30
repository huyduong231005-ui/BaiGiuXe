import 'package:flutter/material.dart';

import '../api.dart';
import '../logic.dart';
import '../main.dart';

const _roleNames = {'admin': 'Quản trị', 'manager': 'Quản lý', 'guard': 'Bảo vệ'};

/// Hồ sơ tài khoản API: đổi họ tên, đổi mật khẩu (phải nhập mật khẩu hiện tại).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final name = TextEditingController(text: api.session.value?.fullName);
  final current = TextEditingController();
  final next = TextEditingController();
  bool busy = false;

  Future<void> _save() async {
    if (next.text.isNotEmpty && next.text.length < 6) return showError(context, 'Mật khẩu mới tối thiểu 6 ký tự');
    setState(() => busy = true);
    try {
      await api.updateProfile({
        'fullName': name.text.trim(),
        if (next.text.isNotEmpty) ...{'currentPassword': current.text, 'newPassword': next.text},
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Đã lưu hồ sơ')));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = api.session.value;
    return Scaffold(
      appBar: AppBar(title: const Text('Hồ sơ')),
      body: SafeArea(
        top: false,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (u != null)
            Card(
              child: ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text(u.username, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('${u.email} · ${_roleNames[u.role]}'),
              ),
            ),
          const SizedBox(height: 16),
          TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Họ tên', prefixIcon: Icon(Icons.badge_outlined))),
          const SizedBox(height: 24),
          Text('Đổi mật khẩu (để trống nếu không đổi)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Mật khẩu hiện tại', prefixIcon: Icon(Icons.lock_outline), helperText: 'Tài khoản tạo bằng Google thì để trống')),
          fieldGap,
          TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'Mật khẩu mới', prefixIcon: Icon(Icons.lock_reset))),
          const SizedBox(height: 24),
          FilledButton.icon(onPressed: busy ? null : _save, icon: const Icon(Icons.save_outlined), label: const Text('Lưu')),
        ]),
      ),
    );
  }
}

/// Quản trị tài khoản API (chỉ admin): đổi vai trò, khoá, gắn tài khoản bảo vệ với hồ sơ bảo vệ, xoá.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});

  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  List<Rec> users = [];
  List<Rec> guards = [];
  String query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait([api.get('/admin/users', {'q': query}), api.get('/guards')]);
      if (!mounted) return;
      setState(() {
        users = (r[0] as List).cast<Rec>();
        guards = (r[1] as List).cast<Rec>();
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _edit(Rec u) async {
    var role = u['role'] as String;
    var active = u['active'] as bool;
    int? guardId = u['guardId'] as int?;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(c).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${u['username']} · ${u['email']}', style: Theme.of(c).textTheme.titleMedium),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: [for (final e in _roleNames.entries) ButtonSegment(value: e.key, label: Text(e.value))],
              selected: {role},
              onSelectionChanged: (v) => set(() => role = v.first),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int?>(
              initialValue: guardId,
              decoration: const InputDecoration(labelText: 'Gắn với hồ sơ bảo vệ (xem bảng công của mình)', prefixIcon: Icon(Icons.security)),
              items: [
                const DropdownMenuItem(value: null, child: Text('Không gắn')),
                for (final g in guards) DropdownMenuItem(value: g['id'] as int, child: Text('#${g['id']} ${g['name']}')),
              ],
              onChanged: (v) => set(() => guardId = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Đang hoạt động'),
              subtitle: const Text('Tắt để khoá tài khoản'),
              value: active,
              onChanged: (v) => set(() => active = v),
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Lưu')),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await api.patch('/admin/users/${u['id']}', {'role': role, 'active': active, 'guardId': guardId});
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(Rec u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Xoá tài khoản ${u['username']}?'),
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
      await api.delete('/admin/users/${u['id']}');
      _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final guardName = {for (final g in guards) g['id'] as int: g['name'] as String};
    return Scaffold(
      appBar: AppBar(title: const Text('Tài khoản')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(
            decoration: const InputDecoration(hintText: 'Tìm tên đăng nhập, email, họ tên', prefixIcon: Icon(Icons.search)),
            onChanged: (v) => query = v.trim(),
            onSubmitted: (_) => _load(),
          ),
          const SizedBox(height: 12),
          for (final u in users)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: u['active'] == true ? s.primaryContainer : s.surfaceContainerHighest,
                  child: Icon(switch (u['role']) { 'admin' => Icons.admin_panel_settings, 'manager' => Icons.manage_accounts, _ => Icons.security }),
                ),
                title: Text('${u['fullName'] == '' ? u['username'] : u['fullName']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  '@${u['username']} · ${_roleNames[u['role']]}',
                  if (u['guardId'] != null) 'Bảo vệ: ${guardName[u['guardId']] ?? '#${u['guardId']}'}',
                  if (u['active'] != true) 'Đã khoá',
                ].join(' · ')),
                onTap: () => _edit(u),
                trailing: u['id'] == api.session.value?.id
                    ? null
                    : IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Xoá', onPressed: () => _delete(u)),
              ),
            ),
        ]),
      ),
    );
  }
}
