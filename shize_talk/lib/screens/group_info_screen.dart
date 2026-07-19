import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'public_profile_screen.dart';

/// Экран управления группой: список участников, добавление новых (только из
/// друзей — то же правило, что и при создании группы, проверяется и в БД),
/// выход из группы.
class GroupInfoScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;

  const GroupInfoScreen({super.key, required this.chatId, required this.chatTitle});

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;
  bool _leaving = false;
  String? _myUserId;

  @override
  void initState() {
    super.initState();
    _myUserId = Supabase.instance.client.auth.currentUser?.id;
    _loadParticipants();
  }

  Future<void> _loadParticipants() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client
          .rpc('list_chat_participants', params: {'p_chat_id': widget.chatId});
      if (!mounted) return;
      setState(() => _participants = List<Map<String, dynamic>>.from(data as List));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openAddParticipants() async {
    List<Map<String, dynamic>> friends;
    try {
      final data = await Supabase.instance.client.rpc('list_friends');
      friends = List<Map<String, dynamic>>.from(data as List);
    } catch (_) {
      friends = [];
    }

    final existingIds = _participants.map((p) => p['user_id'] as String).toSet();
    final candidates = friends.where((f) => !existingIds.contains(f['friend_id'] as String)).toList();

    if (!mounted) return;

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Все ваши друзья уже в этой группе')),
      );
      return;
    }

    final selected = await showModalBottomSheet<Set<String>>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _AddParticipantsSheet(candidates: candidates),
    );

    if (selected == null || selected.isEmpty || !mounted) return;

    try {
      await Supabase.instance.client.rpc('add_chat_participants', params: {
        'p_chat_id': widget.chatId,
        'p_member_ids': selected.toList(),
      });
      _loadParticipants();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Покинуть группу?'),
        content: Text('Вы выйдете из «${widget.chatTitle}» и перестанете видеть переписку.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Покинуть', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _leaving = true);
    try {
      await Supabase.instance.client.rpc('leave_group', params: {'p_chat_id': widget.chatId});
      if (!mounted) return;
      // Возвращаемся сразу к списку чатов (закрываем и чат, и этот экран).
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _leaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatTitle)),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Center(
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        gradient: AppColors.primaryGradient,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.groups, color: Colors.white, size: 32),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      widget.chatTitle,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      '${_participants.length} участник${_pluralSuffix(_participants.length)}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Участники', style: TextStyle(color: AppColors.textSecondary)),
                      TextButton.icon(
                        onPressed: _openAddParticipants,
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('Добавить'),
                      ),
                    ],
                  ),
                  ..._participants.map((p) {
                    final userId = p['user_id'] as String;
                    final title = (p['display_name'] as String?)?.isNotEmpty == true
                        ? p['display_name'] as String
                        : '@${p['username']}';
                    final avatarUrl = (p['thumb_url'] as String?) ?? (p['avatar_url'] as String?);
                    final isMe = userId == _myUserId;
                    return Card(
                      color: AppColors.surface,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                          backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
                          child: avatarUrl == null
                              ? Text(title.isNotEmpty ? title[0].toUpperCase() : '?')
                              : null,
                        ),
                        title: Text('$title${isMe ? ' (вы)' : ''}',
                            style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text('@${p['username']}',
                            style: const TextStyle(color: AppColors.textSecondary)),
                        onTap: isMe
                            ? null
                            : () => Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => PublicProfileScreen(
                                      userId: userId,
                                      initialDisplayName: p['display_name'] as String?,
                                      initialUsername: p['username'] as String?,
                                      initialAvatarUrl: avatarUrl,
                                    ),
                                  ),
                                ),
                      ),
                    );
                  }),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: _leaving ? null : _leaveGroup,
                    icon: const Icon(Icons.logout, color: AppColors.danger),
                    label: Text(_leaving ? 'Выходим...' : 'Покинуть группу',
                        style: const TextStyle(color: AppColors.danger)),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
                  ),
                ],
              ),
      ),
    );
  }

  String _pluralSuffix(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return '';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 10 || mod100 >= 20)) return 'а';
    return 'ов';
  }
}

class _AddParticipantsSheet extends StatefulWidget {
  final List<Map<String, dynamic>> candidates;
  const _AddParticipantsSheet({required this.candidates});

  @override
  State<_AddParticipantsSheet> createState() => _AddParticipantsSheetState();
}

class _AddParticipantsSheetState extends State<_AddParticipantsSheet> {
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 16, bottom: 8),
              child: Text('Добавить в группу', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.candidates.length,
                itemBuilder: (context, i) {
                  final f = widget.candidates[i];
                  final id = f['friend_id'] as String;
                  final title = (f['display_name'] as String?)?.isNotEmpty == true
                      ? f['display_name'] as String
                      : '@${f['username']}';
                  final avatarUrl = (f['thumb_url'] as String?) ?? (f['avatar_url'] as String?);
                  final checked = _selected.contains(id);
                  return CheckboxListTile(
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
                          ? Text(title.isNotEmpty ? title[0].toUpperCase() : '?')
                          : null,
                    ),
                    title: Text(title),
                    subtitle: Text('@${f['username']}',
                        style: const TextStyle(color: AppColors.textSecondary)),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_selected),
                  child: Text('Добавить${_selected.isNotEmpty ? ' (${_selected.length})' : ''}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
