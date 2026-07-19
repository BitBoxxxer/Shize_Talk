import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/device_registry.dart';
import 'chat_screen.dart';
import 'friends_screen.dart';
import 'profile_screen.dart';
import 'create_group_screen.dart';

class ChatsListScreen extends StatefulWidget {
  const ChatsListScreen({super.key});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;
  Timer? _deviceTimer;

  // Компактное превью вместо полноразмерной аватарки в списке — если его
  // ещё нет (старая аватарка, залитая до этой фичи), падаем на полный URL.
  String? _chatAvatarUrl(Map<String, dynamic> chat) =>
      (chat['other_thumb_url'] as String?) ?? (chat['other_avatar_url'] as String?);

  @override
  void initState() {
    super.initState();
    _loadChats();
    // Список чатов — главный экран, живёт весь сеанс работы с приложением,
    // поэтому именно тут держим устройство "свежим" в экране Настройки → Устройства.
    DeviceRegistry.touch();
    _deviceTimer = Timer.periodic(const Duration(minutes: 5), (_) => DeviceRegistry.touch());
  }

  @override
  void dispose() {
    _deviceTimer?.cancel();
    super.dispose();
  }

  Future<void> _openFavorites() async {
    try {
      final chatId =
          await Supabase.instance.client.rpc('get_or_create_favorites_chat') as String;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(chatId: chatId, chatTitle: 'Избранное'),
        ),
      );
      _loadChats();
    } catch (_) {
      // сеть могла подвести — просто ничего не открываем, пользователь попробует снова
    }
  }

  Future<void> _showNewChatMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt, color: AppColors.cyan),
              title: const Text('Написать другу'),
              onTap: () => Navigator.pop(context, 'friend'),
            ),
            ListTile(
              leading: const Icon(Icons.groups_outlined, color: AppColors.cyan),
              title: const Text('Новая группа'),
              onTap: () => Navigator.pop(context, 'group'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) return;

    if (choice == 'friend') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FriendsScreen()),
      );
    } else if (choice == 'group') {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
      );
    }
    _loadChats();
  }

  Future<void> _loadChats() async {
    setState(() => _loading = true);
    final data = await Supabase.instance.client.rpc('list_chats');
    if (!mounted) return;
    setState(() {
      _chats = List<Map<String, dynamic>>.from(data as List);
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shize Talk'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_add_alt),
            tooltip: 'Друзья',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const FriendsScreen()),
              );
              _loadChats();
            },
          ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            tooltip: 'Профиль',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const ProfileScreen()),
              );
            },
          ),
        ],
      ),
      body: RetroBackground(
        child: RefreshIndicator(
          color: AppColors.cyan,
          onRefresh: _loadChats,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
              : ListView(
                  padding: const EdgeInsets.all(12),
                  children: [
                    // "Избранное" — заметки самому себе, как в Телеграме/Дискорде.
                    // Показываем всегда первым пунктом, чат создаётся лениво по тапу.
                    Card(
                      color: AppColors.surface,
                      margin: const EdgeInsets.only(bottom: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            gradient: AppColors.primaryGradient,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.bookmark, color: Colors.white, size: 20),
                        ),
                        title: const Text('Избранное', style: TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: const Text('Заметки для себя',
                            style: TextStyle(color: AppColors.textSecondary)),
                        onTap: _openFavorites,
                      ),
                    ),
                    if (_chats.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 100),
                        child: Center(
                          child: Text(
                            'Пока нет чатов.\nДобавьте друга по юзернейму, чтобы начать.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      )
                    else
                      ..._chats.map((c) {
                        final isGroup = c['chat_type'] == 'group';
                        final title = (c['chat_title'] as String?) ??
                            (c['other_display_name'] as String?) ??
                            (c['other_username'] != null ? '@${c['other_username']}' : 'Чат');
                        final preview = c['last_message'] as String?;
                        final lastSeenRaw = c['other_last_seen_at'] as String?;
                        final isOnline = !isGroup &&
                            lastSeenRaw != null &&
                            DateTime.now()
                                    .difference(DateTime.parse(lastSeenRaw).toLocal())
                                    .inSeconds <
                                45;

                        return Card(
                          color: AppColors.surface,
                          margin: const EdgeInsets.only(bottom: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          child: ListTile(
                            leading: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  backgroundColor: AppColors.blue.withValues(alpha: 0.3),
                                  backgroundImage: _chatAvatarUrl(c) != null
                                      ? NetworkImage(_chatAvatarUrl(c)!)
                                      : null,
                                  child: _chatAvatarUrl(c) == null
                                      ? (isGroup
                                          ? const Icon(Icons.groups, color: AppColors.textPrimary, size: 20)
                                          : Text(
                                              title.isNotEmpty ? title[0].toUpperCase() : '?',
                                              style: const TextStyle(
                                                  color: AppColors.textPrimary,
                                                  fontWeight: FontWeight.bold),
                                            ))
                                      : null,
                                ),
                                if (isOnline)
                                  Positioned(
                                    right: -1,
                                    bottom: -1,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: AppColors.success,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: AppColors.surface, width: 2),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text(
                              preview ?? 'Нет сообщений',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppColors.textSecondary),
                            ),
                            onTap: () {
                              Navigator.of(context)
                                  .push(
                                    MaterialPageRoute(
                                      builder: (_) => ChatScreen(
                                        chatId: c['chat_id'] as String,
                                        chatTitle: title,
                                        otherUserId: c['other_user_id'] as String?,
                                      ),
                                    ),
                                  )
                                  .then((_) => _loadChats());
                            },
                          ),
                        );
                      }),
                  ],
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.purple,
        onPressed: _showNewChatMenu,
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}
