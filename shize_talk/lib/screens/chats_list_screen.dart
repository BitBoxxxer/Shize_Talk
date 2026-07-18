import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'friends_screen.dart';
import 'profile_screen.dart';

class ChatsListScreen extends StatefulWidget {
  const ChatsListScreen({super.key});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  List<Map<String, dynamic>> _chats = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
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
              : _chats.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 120),
                        Center(
                          child: Text(
                            'Пока нет чатов.\nДобавьте друга по юзернейму, чтобы начать.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: _chats.length,
                      itemBuilder: (context, i) {
                        final c = _chats[i];
                        final title = (c['chat_title'] as String?) ??
                            (c['other_display_name'] as String?) ??
                            (c['other_username'] != null ? '@${c['other_username']}' : 'Чат');
                        final preview = c['last_message'] as String?;

                        return Card(
                          color: AppColors.surface,
                          margin: const EdgeInsets.only(bottom: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.blue.withOpacity(0.3),
                              child: Text(
                                title.isNotEmpty ? title[0].toUpperCase() : '?',
                                style: const TextStyle(
                                    color: AppColors.textPrimary, fontWeight: FontWeight.bold),
                              ),
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
                                      ),
                                    ),
                                  )
                                  .then((_) => _loadChats());
                            },
                          ),
                        );
                      },
                    ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.purple,
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FriendsScreen()),
          );
          _loadChats();
        },
        child: const Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}
