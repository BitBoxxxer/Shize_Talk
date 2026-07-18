import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _usernameController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client.rpc('get_my_profile');
      final row = (data as List).isNotEmpty ? data.first as Map<String, dynamic> : null;
      if (row != null) {
        _usernameController.text = (row['username'] as String?) ?? '';
        _displayNameController.text = (row['display_name'] as String?) ?? '';
      }
    } catch (e) {
      _error = 'Не удалось загрузить профиль: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final username = _usernameController.text.trim();
    final displayName = _displayNameController.text.trim();

    if (!_usernamePattern.hasMatch(username)) {
      setState(() {
        _error = 'Юзернейм: 3-20 символов, латиница/цифры/подчёркивание';
        _success = null;
      });
      return;
    }
    if (displayName.isEmpty) {
      setState(() {
        _error = 'Имя не может быть пустым';
        _success = null;
      });
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });

    try {
      await Supabase.instance.client.rpc('set_username', params: {'p_username': username});
      await Supabase.instance.client
          .rpc('update_display_name', params: {'p_display_name': displayName});
      if (!mounted) return;
      setState(() => _success = 'Профиль обновлён');
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceAlt,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Вам потребуется email и код из письма, чтобы войти снова.',
          style: TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await Supabase.instance.client.auth.signOut();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: CircleAvatar(
                        radius: 44,
                        backgroundColor: AppColors.purple.withOpacity(0.3),
                        child: Text(
                          _displayNameController.text.isNotEmpty
                              ? _displayNameController.text[0].toUpperCase()
                              : '?',
                          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Text('Имя', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _displayNameController,
                      decoration: const InputDecoration(hintText: 'Ваше имя'),
                    ),
                    const SizedBox(height: 20),
                    const Text('Юзернейм', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _usernameController,
                      decoration: const InputDecoration(prefixText: '@', hintText: 'username'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(_error!, style: const TextStyle(color: AppColors.danger)),
                    ],
                    if (_success != null) ...[
                      const SizedBox(height: 14),
                      Text(_success!, style: const TextStyle(color: AppColors.success)),
                    ],
                    const SizedBox(height: 28),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Сохранить'),
                    ),
                    const SizedBox(height: 40),
                    OutlinedButton.icon(
                      onPressed: _confirmSignOut,
                      icon: const Icon(Icons.logout, color: AppColors.danger),
                      label: const Text('Выйти из аккаунта', style: TextStyle(color: AppColors.danger)),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
