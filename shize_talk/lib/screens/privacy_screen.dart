import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

class PrivacyScreen extends StatefulWidget {
  final String initialAvatarVisibility; // 'everyone' | 'friends'
  const PrivacyScreen({super.key, required this.initialAvatarVisibility});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  late String _avatarVisibility = widget.initialAvatarVisibility;
  bool _saving = false;
  String? _error;

  Future<void> _update(String value) async {
    if (value == _avatarVisibility || _saving) return;
    final previous = _avatarVisibility;
    setState(() {
      _avatarVisibility = value;
      _saving = true;
      _error = null;
    });
    try {
      await Supabase.instance.client
          .rpc('update_privacy_settings', params: {'p_avatar_visibility': value});
    } catch (e) {
      setState(() {
        _avatarVisibility = previous; // откатываем, если сервер не принял
        _error = 'Не удалось сохранить: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Приватность')),
      body: RetroBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8, left: 4),
              child: Text('Кто видит аватарку', style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ),
            _PrivacyOption(
              title: 'Все пользователи',
              subtitle: 'Аватарку видит любой, даже не в друзьях',
              selected: _avatarVisibility == 'everyone',
              onTap: () => _update('everyone'),
            ),
            const SizedBox(height: 8),
            _PrivacyOption(
              title: 'Только друзья',
              subtitle: 'Остальные увидят профиль без аватарки',
              selected: _avatarVisibility == 'friends',
              onTap: () => _update('friends'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 24),
            const Text(
              'Настройки приватности для описания профиля, даты рождения и '
              'даты последнего захода — в разработке, добавим следующим шагом.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrivacyOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _PrivacyOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? AppColors.cyan : Colors.transparent, width: 1.5),
      ),
      child: ListTile(
        onTap: onTap,
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
        trailing: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
          color: selected ? AppColors.cyan : AppColors.textSecondary,
        ),
      ),
    );
  }
}
