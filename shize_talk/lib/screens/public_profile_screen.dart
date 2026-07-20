import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/ru_date.dart';
import 'chat_screen.dart';

/// Экран просмотра чужого профиля (открывается из поиска, списка друзей,
/// заявок или из шапки личного чата). В отличие от `ProfileScreen` (свой
/// профиль) — только просмотр и действия "добавить/удалить из друзей",
/// "написать сообщение", без редактирования.
class PublicProfileScreen extends StatefulWidget {
  final String userId;
  // Опциональные значения для мгновенного отображения, пока грузится профиль
  // (например уже известны из списка друзей) — избегаем "мигания" пустого экрана.
  final String? initialDisplayName;
  final String? initialUsername;
  final String? initialAvatarUrl;

  const PublicProfileScreen({
    super.key,
    required this.userId,
    this.initialDisplayName,
    this.initialUsername,
    this.initialAvatarUrl,
  });

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  bool _loading = true;
  String? _error;
  String? _actionError;
  bool _actionLoading = false;

  String _username = '';
  String _displayName = '';
  String _bio = '';
  String? _avatarUrl;
  bool _isFriend = false;
  bool _hasPendingRequest = false;
  bool _isMe = false;
  DateTime? _friendsSince;
  bool _isBlockedByMe = false;

  @override
  void initState() {
    super.initState();
    _displayName = widget.initialDisplayName ?? '';
    _username = widget.initialUsername ?? '';
    _avatarUrl = widget.initialAvatarUrl;
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client
          .rpc('get_public_profile', params: {'p_user_id': widget.userId});
      final row = (data as List).isNotEmpty ? data.first as Map<String, dynamic> : null;
      if (row == null) {
        _error = 'Пользователь не найден';
      } else {
        _username = (row['username'] as String?) ?? '';
        _displayName = (row['display_name'] as String?) ?? '';
        _bio = (row['bio'] as String?) ?? '';
        _avatarUrl = (row['thumb_url'] as String?) ?? (row['avatar_url'] as String?);
        _isFriend = row['is_friend'] as bool? ?? false;
        _hasPendingRequest = row['has_pending_request'] as bool? ?? false;
        _isMe = row['is_me'] as bool? ?? false;
        final rawSince = row['friends_since'] as String?;
        _friendsSince = rawSince != null ? DateTime.tryParse(rawSince) : null;
        _isBlockedByMe = row['is_blocked_by_me'] as bool? ?? false;
      }
    } catch (e) {
      _error = 'Не удалось загрузить профиль: $e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _sendRequest() async {
    if (_username.isEmpty) return;
    setState(() {
      _actionLoading = true;
      _actionError = null;
    });
    try {
      await Supabase.instance.client.rpc('send_friend_request', params: {'p_username': _username});
      if (!mounted) return;
      setState(() => _hasPendingRequest = true);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Заявка отправлена @$_username')));
    } on PostgrestException catch (e) {
      setState(() => _actionError = e.message);
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  Future<void> _removeFriend() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Удалить из друзей?'),
        content: Text('$_displayName будет удалён(а) из списка друзей.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _actionLoading = true;
      _actionError = null;
    });
    try {
      await Supabase.instance.client.rpc('remove_friend', params: {'p_friend_id': widget.userId});
      if (!mounted) return;
      setState(() => _isFriend = false);
    } on PostgrestException catch (e) {
      setState(() => _actionError = e.message);
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  Future<void> _copyUsername() async {
    await Clipboard.setData(ClipboardData(text: '@$_username'));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Юзернейм скопирован')),
    );
  }

  Future<void> _toggleBlock() async {
    final willBlock = !_isBlockedByMe;
    if (willBlock) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('Заблокировать пользователя?'),
          content: Text(
            '$_displayName не сможет отправлять вам сообщения и заявки в друзья.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Заблокировать', style: TextStyle(color: AppColors.danger)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() {
      _actionLoading = true;
      _actionError = null;
    });
    try {
      await Supabase.instance.client.rpc(
        willBlock ? 'block_user' : 'unblock_user',
        params: {'p_user_id': widget.userId},
      );
      if (!mounted) return;
      setState(() => _isBlockedByMe = willBlock);
    } on PostgrestException catch (e) {
      setState(() => _actionError = e.message);
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  Future<void> _openChat() async {
    setState(() {
      _actionLoading = true;
      _actionError = null;
    });
    try {
      final chatId = await Supabase.instance.client
          .rpc('get_or_create_direct_chat', params: {'p_other_user_id': widget.userId}) as String;
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: _displayName.isNotEmpty ? _displayName : '@$_username',
            otherUserId: widget.userId,
          ),
        ),
      );
    } on PostgrestException catch (e) {
      setState(() => _actionError = e.message);
    } finally {
      if (mounted) setState(() => _actionLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: AppColors.danger)))
                : ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      Center(
                        child: CircleAvatar(
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
                          child: GestureDetector(
                            onTap: _copyUsername,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('@$_username', style: const TextStyle(color: AppColors.textSecondary)),
                                const SizedBox(width: 4),
                                const Icon(Icons.copy, size: 14, color: AppColors.textSecondary),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (_isFriend && _friendsSince != null) ...[
                        const SizedBox(height: 4),
                        Center(
                          child: Text(
                            'Друзья с ${formatRuDate(_friendsSince!)}',
                            style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                          ),
                        ),
                      ],
                      if (_bio.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Card(
                          color: AppColors.surface,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('О себе',
                                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                                const SizedBox(height: 4),
                                Text(_bio),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 28),
                      if (_actionError != null) ...[
                        Text(_actionError!, style: const TextStyle(color: AppColors.danger)),
                        const SizedBox(height: 12),
                      ],
                      if (!_isMe) ...[
                        if (_isFriend) ...[
                          ElevatedButton.icon(
                            onPressed: _actionLoading ? null : _openChat,
                            icon: const Icon(Icons.chat_bubble_outline),
                            label: const Text('Написать сообщение'),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _actionLoading ? null : _removeFriend,
                            icon: const Icon(Icons.person_remove_outlined, color: AppColors.danger),
                            label: const Text('Удалить из друзей',
                                style: TextStyle(color: AppColors.danger)),
                            style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
                          ),
                        ] else if (_hasPendingRequest) ...[
                          const Center(
                            child: Text('Заявка в друзья отправлена — ожидание ответа',
                                style: TextStyle(color: AppColors.textSecondary)),
                          ),
                        ] else
                          ElevatedButton.icon(
                            onPressed: _actionLoading ? null : _sendRequest,
                            icon: const Icon(Icons.person_add_alt),
                            label: const Text('Добавить в друзья'),
                          ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _actionLoading ? null : _toggleBlock,
                          icon: Icon(
                            _isBlockedByMe ? Icons.block_flipped : Icons.block,
                            color: AppColors.danger,
                          ),
                          label: Text(
                            _isBlockedByMe ? 'Разблокировать' : 'Заблокировать',
                            style: const TextStyle(color: AppColors.danger),
                          ),
                          style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
                        ),
                      ],
                    ],
                  ),
      ),
    );
  }
}
