import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Экран "Изменить профиль" — как в Телеграме: только поля профиля,
/// без кнопок аккаунта (они переехали на экран настроек).
class EditProfileScreen extends StatefulWidget {
  final String initialUsername;
  final String initialDisplayName;
  final String initialBio;
  final DateTime? initialBirthDate;

  const EditProfileScreen({
    super.key,
    required this.initialUsername,
    required this.initialDisplayName,
    required this.initialBio,
    required this.initialBirthDate,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  late final _usernameController = TextEditingController(text: widget.initialUsername);
  late final _displayNameController = TextEditingController(text: widget.initialDisplayName);
  late final _bioController = TextEditingController(text: widget.initialBio);
  final _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');

  late DateTime? _birthDate = widget.initialBirthDate;
  bool _saving = false;
  String? _error;

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
      setState(() => _error = 'Юзернейм: 3-20 символов, латиница/цифры/подчёркивание');
      return;
    }
    if (displayName.isEmpty) {
      setState(() => _error = 'Имя не может быть пустым');
      return;
    }
    if (bio.length > 200) {
      setState(() => _error = 'Описание профиля слишком длинное (максимум 200 символов)');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await Supabase.instance.client.rpc('set_username', params: {'p_username': username});
      await Supabase.instance.client.rpc('update_profile_details', params: {
        'p_display_name': displayName,
        'p_bio': bio.isEmpty ? null : bio,
        'p_birth_date': _birthDate?.toIso8601String().split('T').first,
      });
      if (!mounted) return;
      Navigator.of(context).pop(true); // true — профиль обновился, экран выше перечитает данные
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
      appBar: AppBar(
        title: const Text('Изменить профиль'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Готово'),
          ),
        ],
      ),
      body: RetroBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
            ],
          ),
        ),
      ),
    );
  }
}
