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
  final _bioController = TextEditingController();
  final _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');

  DateTime? _birthDate;
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
        _bioController.text = (row['bio'] as String?) ?? '';
        final rawBirth = row['birth_date'] as String?;
        if (rawBirth != null) {
          _birthDate = DateTime.tryParse(rawBirth);
        }
      }
    } catch (e) {
      _error = 'Не удалось загрузить профиль: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(now.year - 100),
      lastDate: now,
      helpText: 'Дата рождения',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: AppColors.purple,
                  onPrimary: Colors.white,
                  surface: AppColors.surfaceAlt,
                ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) setState(() => _birthDate = picked);
  }

  Future<void> _save() async {
    final username = _usernameController.text.trim();
    final displayName = _displayNameController.text.trim();
    final bio = _bioController.text.trim();

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
    if (bio.length > 200) {
      setState(() {
        _error = 'Описание профиля слишком длинное (максимум 200 символов)';
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
      await Supabase.instance.client.rpc('update_profile_details', params: {
        'p_display_name': displayName,
        'p_bio': bio.isEmpty ? null : bio,
        'p_birth_date': _birthDate?.toIso8601String().split('T').first,
      });
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

  void _addAccountComingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Одновременный вход в несколько аккаунтов пока в разработке — скоро добавим',
        ),
      ),
    );
  }

  String _formatBirthDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  @override
  void dispose() {
    _usernameController.dispose();
    _displayNameController.dispose();
    _bioController.dispose();
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
                    const SizedBox(height: 8),
                    const Center(
                      child: Text(
                        'Аватарка (фото/видео/гиф) — скоро',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
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
                    const SizedBox(height: 20),
                    const Text('О себе', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _bioController,
                      maxLength: 200,
                      maxLines: 3,
                      decoration: const InputDecoration(hintText: 'Пара слов о себе'),
                    ),
                    const SizedBox(height: 12),
                    const Text('Дата рождения', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 6),
                    InkWell(
                      onTap: _pickBirthDate,
                      borderRadius: BorderRadius.circular(12),
                      child: InputDecorator(
                        decoration: const InputDecoration(),
                        child: Row(
                          children: [
                            const Icon(Icons.cake_outlined, size: 18, color: AppColors.textSecondary),
                            const SizedBox(width: 10),
                            Text(
                              _birthDate != null ? _formatBirthDate(_birthDate!) : 'Не указана',
                              style: TextStyle(
                                color: _birthDate != null ? AppColors.textPrimary : AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
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
                    const SizedBox(height: 48),
                    const Divider(),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _addAccountComingSoon,
                      icon: const Icon(Icons.add, color: AppColors.cyan),
                      label: const Text('Добавить аккаунт'),
                    ),
                    const SizedBox(height: 12),
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
