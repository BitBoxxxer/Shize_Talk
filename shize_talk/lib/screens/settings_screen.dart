import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_version.dart';
import '../theme/app_theme.dart';
import 'edit_profile_screen.dart';
import 'privacy_screen.dart';
import 'devices_screen.dart';
import 'language_screen.dart';

/// Экран "Настройки" — как в Телеграме: разделы + аккаунт снизу.
/// Принимает уже загруженный профиль (username/displayName/bio/birthDate/
/// avatarVisibility/language), чтобы не грузить его повторно — profile_screen
/// передаёт актуальные данные и получает сигнал, когда стоит перечитать их.
class SettingsScreen extends StatefulWidget {
  final String username;
  final String displayName;
  final String bio;
  final DateTime? birthDate;
  final String avatarVisibility;
  final String language;

  const SettingsScreen({
    super.key,
    required this.username,
    required this.displayName,
    required this.bio,
    required this.birthDate,
    required this.avatarVisibility,
    required this.language,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {

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
        content: Text('Одновременный вход в несколько аккаунтов пока в разработке — скоро добавим'),
      ),
    );
  }

  void _chatsSettingsComingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Настройки чатов пока в разработке')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: RetroBackground(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _SectionCard(children: [
              _SettingsTile(
                icon: Icons.person_outline,
                title: 'Аккаунт',
                subtitle: 'Имя, юзернейм, описание, дата рождения',
                onTap: () async {
                  final changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => EditProfileScreen(
                        initialUsername: widget.username,
                        initialDisplayName: widget.displayName,
                        initialBio: widget.bio,
                        initialBirthDate: widget.birthDate,
                      ),
                    ),
                  );
                  if (changed == true && context.mounted) {
                    Navigator.of(context).pop(true); // сигнал наверх — перечитать профиль
                  }
                },
              ),
              _SettingsTile(
                icon: Icons.chat_bubble_outline,
                title: 'Настройки чатов',
                subtitle: 'Скоро',
                onTap: _chatsSettingsComingSoon,
              ),
              _SettingsTile(
                icon: Icons.lock_outline,
                title: 'Приватность',
                subtitle: 'Кто видит вашу аватарку',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PrivacyScreen(initialAvatarVisibility: widget.avatarVisibility),
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.devices_other_outlined,
                title: 'Устройства',
                subtitle: 'Где выполнен вход в аккаунт',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DevicesScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.language,
                title: 'Язык',
                subtitle: 'Русский / English / Español',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => LanguageScreen(initialLanguage: widget.language)),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _SectionCard(children: [
              _SettingsTile(
                icon: Icons.add,
                iconColor: AppColors.cyan,
                title: 'Добавить аккаунт',
                onTap: _addAccountComingSoon,
              ),
              _SettingsTile(
                icon: Icons.logout,
                iconColor: AppColors.danger,
                title: 'Выйти из аккаунта',
                titleColor: AppColors.danger,
                onTap: _confirmSignOut,
              ),
            ]),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  'Shize Talk · версия $appVersionFull',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final List<Widget> children;
  const _SectionCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: EdgeInsets.zero,
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: iconColor ?? AppColors.textSecondary),
      title: Text(title, style: TextStyle(color: titleColor, fontWeight: FontWeight.w500)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12))
          : null,
      trailing: const Icon(Icons.chevron_right, color: AppColors.textSecondary),
      onTap: onTap,
    );
  }
}
