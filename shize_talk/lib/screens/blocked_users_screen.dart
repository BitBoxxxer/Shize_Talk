import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  List<Map<String, dynamic>> _blocked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await Supabase.instance.client.rpc('list_blocked_users');
    if (!mounted) return;
    setState(() {
      _blocked = List<Map<String, dynamic>>.from(data as List);
      _loading = false;
    });
  }

  Future<void> _unblock(String userId) async {
    await Supabase.instance.client.rpc('unblock_user', params: {'p_user_id': userId});
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Заблокированные')),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : _blocked.isEmpty
                ? const Center(
                    child: Text('Список пуст', style: TextStyle(color: AppColors.textSecondary)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _blocked.length,
                    itemBuilder: (context, i) {
                      final u = _blocked[i];
                      final avatarUrl = (u['thumb_url'] as String?) ?? (u['avatar_url'] as String?);
                      final title = (u['display_name'] as String?)?.isNotEmpty == true
                          ? u['display_name'] as String
                          : '@${u['username']}';
                      return Card(
                        color: AppColors.surface,
                        margin: const EdgeInsets.only(bottom: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                            backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                            child: avatarUrl == null
                                ? Text(title.isNotEmpty ? title[0].toUpperCase() : '?')
                                : null,
                          ),
                          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text('@${u['username']}',
                              style: const TextStyle(color: AppColors.textSecondary)),
                          trailing: TextButton(
                            onPressed: () => _unblock(u['user_id'] as String),
                            child: const Text('Разблокировать'),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}
