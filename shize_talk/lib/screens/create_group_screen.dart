import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';

/// Экран создания группового чата: название + выбор друзей (в группу можно
/// добавлять только тех, кто уже в друзьях — это же правило проверяется и на
/// уровне БД в `create_group_chat`, экран лишь отражает его в интерфейсе).
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _titleController = TextEditingController();
  List<Map<String, dynamic>> _friends = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  Future<void> _loadFriends() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client.rpc('list_friends');
      if (!mounted) return;
      setState(() => _friends = List<Map<String, dynamic>>.from(data as List));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _create() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Укажите название группы');
      return;
    }
    if (_selected.isEmpty) {
      setState(() => _error = 'Выберите хотя бы одного друга');
      return;
    }

    setState(() {
      _error = null;
      _creating = true;
    });

    try {
      final chatId = await Supabase.instance.client.rpc('create_group_chat', params: {
        'p_title': title,
        'p_member_ids': _selected.toList(),
      }) as String;

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(chatId: chatId, chatTitle: title),
        ),
      );
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Новая группа')),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: TextField(
                      controller: _titleController,
                      decoration: const InputDecoration(
                        labelText: 'Название группы',
                        prefixIcon: Icon(Icons.groups_outlined, color: AppColors.textSecondary),
                      ),
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Добавить друзей', style: TextStyle(color: AppColors.textSecondary)),
                    ),
                  ),
                  Expanded(
                    child: _friends.isEmpty
                        ? const Center(
                            child: Text(
                              'У вас пока нет друзей, которых можно\nдобавить в группу.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: AppColors.textSecondary),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _friends.length,
                            itemBuilder: (context, i) {
                              final f = _friends[i];
                              final id = f['friend_id'] as String;
                              final title = (f['display_name'] as String?)?.isNotEmpty == true
                                  ? f['display_name'] as String
                                  : '@${f['username']}';
                              final avatarUrl = (f['thumb_url'] as String?) ?? (f['avatar_url'] as String?);
                              final checked = _selected.contains(id);
                              return Card(
                                color: AppColors.surface,
                                margin: const EdgeInsets.only(bottom: 8),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                child: CheckboxListTile(
                                  value: checked,
                                  activeColor: AppColors.cyan,
                                  controlAffinity: ListTileControlAffinity.leading,
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _selected.add(id);
                                      } else {
                                        _selected.remove(id);
                                      }
                                    });
                                  },
                                  secondary: CircleAvatar(
                                    backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                                    backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                                    child: avatarUrl == null
                                        ? Text(
                                            title.isNotEmpty ? title[0].toUpperCase() : '?',
                                            style: const TextStyle(fontWeight: FontWeight.bold),
                                          )
                                        : null,
                                  ),
                                  title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  subtitle: Text('@${f['username']}',
                                      style: const TextStyle(color: AppColors.textSecondary)),
                                ),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _creating ? null : _create,
                        child: _creating
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text('Создать группу${_selected.isNotEmpty ? ' (${_selected.length + 1})' : ''}'),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
