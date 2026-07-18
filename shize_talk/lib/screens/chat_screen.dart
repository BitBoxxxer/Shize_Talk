import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

class Message {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime createdAt; // всегда хранится в local time (см. fromMap)

  Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.createdAt,
  });

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String,
      senderId: map['sender_id'] as String? ?? '',
      senderName: map['sender_name'] as String,
      content: map['content'] as String,
      // Supabase отдаёт timestamptz в UTC — .toLocal() переводит его в
      // часовой пояс, установленный на устройстве пользователя.
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  // Нужен, чтобы показывать "в сети"/"был(а) в сети" собеседника.
  // Для групповых чатов (пока не реализованы) можно не передавать.
  final String? otherUserId;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    this.otherUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  RealtimeChannel? _messagesChannel;
  RealtimeChannel? _readsChannel;
  String _displayName = '';
  String? _myUserId;

  DateTime? _otherLastReadAt;
  DateTime? _otherLastSeenAt;
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    _myUserId = Supabase.instance.client.auth.currentUser?.id;
    _loadProfile();
    _loadMessages();
    _subscribeToMessages();
    _loadReadStatus();
    _subscribeToReadStatus();
    _loadOtherPresence();

    _touchPresence();
    _presenceTimer = Timer.periodic(const Duration(seconds: 25), (_) => _touchPresence());
  }

  Future<void> _touchPresence() async {
    try {
      await Supabase.instance.client.rpc('touch_presence');
    } catch (_) {
      // тихо игнорируем — присутствие не критично для основной функциональности
    }
  }

  Future<void> _loadOtherPresence() async {
    if (widget.otherUserId == null) return;
    try {
      final result = await Supabase.instance.client
          .rpc('get_user_presence', params: {'p_user_id': widget.otherUserId});
      if (!mounted || result == null) return;
      setState(() => _otherLastSeenAt = DateTime.parse(result as String).toLocal());
    } catch (_) {}
  }

  Future<void> _loadReadStatus() async {
    try {
      final data = await Supabase.instance.client
          .rpc('get_chat_participants_read', params: {'p_chat_id': widget.chatId});
      final rows = List<Map<String, dynamic>>.from(data as List);
      final otherRow = rows.firstWhere(
        (r) => r['user_id'] != _myUserId,
        orElse: () => {},
      );
      if (!mounted || otherRow.isEmpty || otherRow['last_read_at'] == null) return;
      setState(() => _otherLastReadAt = DateTime.parse(otherRow['last_read_at'] as String).toLocal());
    } catch (_) {}
    // отмечаем чат прочитанным с моей стороны
    _markRead();
  }

  Future<void> _markRead() async {
    try {
      await Supabase.instance.client.rpc('mark_chat_read', params: {'p_chat_id': widget.chatId});
    } catch (_) {}
  }

  void _subscribeToReadStatus() {
    _readsChannel = Supabase.instance.client
        .channel('chat_reads:${widget.chatId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'chat_participants',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: widget.chatId,
          ),
          callback: (payload) {
            if (!mounted) return;
            final row = payload.newRecord;
            if (row['user_id'] == _myUserId) return; // это моя же отметка
            final raw = row['last_read_at'] as String?;
            if (raw == null) return;
            setState(() => _otherLastReadAt = DateTime.parse(raw).toLocal());
          },
        )
        .subscribe();
  }

  Future<void> _loadProfile() async {
    final userId = _myUserId;
    if (userId == null) return;

    final profile = await Supabase.instance.client
        .from('profiles')
        .select('display_name')
        .eq('id', userId)
        .maybeSingle();

    if (mounted && profile != null) {
      setState(() => _displayName = profile['display_name'] as String? ?? '');
    }
  }

  Future<void> _loadMessages() async {
    final data = await Supabase.instance.client
        .from('messages')
        .select()
        .eq('chat_id', widget.chatId)
        .order('created_at', ascending: true)
        .limit(200);

    setState(() {
      _messages = (data as List).map((m) => Message.fromMap(m)).toList();
    });
    _scrollToBottom();
  }

  void _subscribeToMessages() {
    _messagesChannel = Supabase.instance.client
        .channel('chat:${widget.chatId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'chat_id',
            value: widget.chatId,
          ),
          callback: (payload) {
            if (!mounted) return;
            final newMessage = Message.fromMap(payload.newRecord);
            setState(() {
              if (!_messages.any((m) => m.id == newMessage.id)) {
                _messages.add(newMessage);
              }
            });
            _scrollToBottom();
            // Новое сообщение пришло, пока чат открыт — сразу отмечаем прочитанным
            if (newMessage.senderId != _myUserId) {
              _markRead();
            }
          },
        )
        .subscribe();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  bool _sending = false;

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _sending) return;
    if (_myUserId == null) return;

    setState(() => _sending = true);

    try {
      final inserted = await Supabase.instance.client
          .from('messages')
          .insert({
            'chat_id': widget.chatId,
            'sender_id': _myUserId,
            'sender_name': _displayName.isEmpty ? 'Без имени' : _displayName,
            'content': text,
          })
          .select()
          .single();

      if (!mounted) return;

      final message = Message.fromMap(inserted);
      setState(() {
        if (!_messages.any((m) => m.id == message.id)) {
          _messages.add(message);
        }
      });
      _messageController.clear();
      _scrollToBottom();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось отправить: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка отправки: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  String? _presenceSubtitle() {
    if (widget.otherUserId == null) return null;
    final lastSeen = _otherLastSeenAt;
    if (lastSeen == null) return null;

    final diff = DateTime.now().difference(lastSeen);
    if (diff.inSeconds < 45) return 'в сети';

    final now = DateTime.now();
    final isToday = lastSeen.year == now.year && lastSeen.month == now.month && lastSeen.day == now.day;
    if (isToday) {
      return 'был(а) в сети в ${_formatTime(lastSeen)}';
    }
    return 'был(а) в сети ${lastSeen.day.toString().padLeft(2, '0')}.${lastSeen.month.toString().padLeft(2, '0')} в ${_formatTime(lastSeen)}';
  }

  bool _isReadByOther(Message msg) {
    if (_otherLastReadAt == null) return false;
    return !_otherLastReadAt!.isBefore(msg.createdAt);
  }

  @override
  void dispose() {
    _messagesChannel?.unsubscribe();
    _readsChannel?.unsubscribe();
    _presenceTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = _presenceSubtitle();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.chatTitle),
            if (subtitle != null)
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: subtitle == 'в сети' ? AppColors.success : AppColors.textSecondary,
                ),
              ),
          ],
        ),
      ),
      body: RetroBackground(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isMine = msg.senderId == _myUserId;
                  final isRead = isMine && _isReadByOther(msg);
                  return Align(
                    alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        gradient: isMine
                            ? const LinearGradient(colors: [AppColors.purple, AppColors.blue])
                            : null,
                        color: isMine ? null : AppColors.surface,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(isMine ? 16 : 4),
                          bottomRight: Radius.circular(isMine ? 4 : 16),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isMine)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 3),
                              child: Text(
                                msg.senderName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: AppColors.cyan,
                                ),
                              ),
                            ),
                          Text(msg.content, style: const TextStyle(color: AppColors.textPrimary)),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _formatTime(msg.createdAt),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isMine
                                      ? Colors.white.withOpacity(0.75)
                                      : AppColors.textSecondary,
                                ),
                              ),
                              if (isMine) ...[
                                const SizedBox(width: 4),
                                Icon(
                                  isRead ? Icons.done_all : Icons.done,
                                  size: 14,
                                  color: isRead
                                      ? AppColors.cyan
                                      : Colors.white.withOpacity(0.75),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(hintText: 'Сообщение...'),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: AppColors.primaryGradient,
                    ),
                    child: IconButton(
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.send, color: Colors.white),
                      onPressed: _sending ? null : _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
