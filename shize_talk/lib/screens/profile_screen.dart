import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'avatar_screen.dart';
import 'settings_screen.dart';

/// Экран "Профиль" — как в Телеграме: просмотр (аватарка, имя, юзернейм,
/// описание, дата рождения), а редактирование и аккаунтные действия вынесены
/// в отдельные экраны (EditProfileScreen / SettingsScreen).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _username = '';
  String _displayName = '';
  String _bio = '';
  DateTime? _birthDate;
  String? _avatarUrl;
  String _avatarVisibility = 'everyone';
  String _language = 'ru';
  bool _loading = true;
  String? _error;

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
        _username = (row['username'] as String?) ?? '';
        _displayName = (row['display_name'] as String?) ?? '';
        _bio = (row['bio'] as String?) ?? '';
        _avatarUrl = row['avatar_url'] as String?;
        _avatarVisibility = (row['avatar_visibility'] as String?) ?? 'everyone';
        _language = (row['language'] as String?) ?? 'ru';
        final rawBirth = row['birth_date'] as String?;
        _birthDate = rawBirth != null ? DateTime.tryParse(rawBirth) : null;
      }
    } catch (e) {
      _error = 'Не удалось загрузить профиль: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatBirthDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          username: _username,
          displayName: _displayName,
          bio: _bio,
          birthDate: _birthDate,
          avatarVisibility: _avatarVisibility,
          language: _language,
        ),
      ),
    );
    if (changed == true) _loadProfile();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Профиль'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Настройки',
            onPressed: _openSettings,
          ),
        ],
      ),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : RefreshIndicator(
                color: AppColors.cyan,
                onRefresh: _loadProfile,
                child: ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: AppColors.danger)),
                      const SizedBox(height: 16),
                    ],
                    Center(
                      child: GestureDetector(
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const AvatarScreen()),
                          );
                          _loadProfile();
                        },
                        child: Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            CircleAvatar(
                              radius: 56,
                              backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                              backgroundImage: _avatarUrl != null ? NetworkImage(_avatarUrl!) : null,
                              child: _avatarUrl == null
                                  ? Text(
                                      _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?',
                                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
                                    )
                                  : null,
                            ),
                            Container(
                              padding: const EdgeInsets.all(7),
                              decoration: const BoxDecoration(
                                gradient: AppColors.primaryGradient,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        _displayName.isEmpty ? 'Без имени' : _displayName,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (_username.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Center(
                        child: Text('@$_username', style: const TextStyle(color: AppColors.textSecondary)),
                      ),
                    ],
                    const SizedBox(height: 28),
                    _InfoRow(
                      icon: Icons.info_outline,
                      label: 'О себе',
                      value: _bio.isEmpty ? 'Не указано' : _bio,
                    ),
                    const SizedBox(height: 12),
                    _InfoRow(
                      icon: Icons.cake_outlined,
                      label: 'Дата рождения',
                      value: _birthDate != null ? _formatBirthDate(_birthDate!) : 'Не указана',
                    ),
                    const SizedBox(height: 28),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final changed = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                            builder: (_) => SettingsScreen(
                              username: _username,
                              displayName: _displayName,
                              bio: _bio,
                              birthDate: _birthDate,
                              avatarVisibility: _avatarVisibility,
                              language: _language,
                            ),
                          ),
                        );
                        if (changed == true) _loadProfile();
                      },
                      icon: const Icon(Icons.edit_outlined, color: AppColors.cyan),
                      label: const Text('Изменить профиль'),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: AppColors.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                  const SizedBox(height: 2),
                  Text(value, style: const TextStyle(color: AppColors.textPrimary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
