import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

class Message {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime createdAt;

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
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;

  const ChatScreen({super.key, required this.chatId, required this.chatTitle});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  List<Message> _messages = [];
  RealtimeChannel? _channel;
  String _displayName = '';
  String? _myUserId;

  @override
  void initState() {
    super.initState();
    _myUserId = Supabase.instance.client.auth.currentUser?.id;
    _loadProfile();
    _loadMessages();
    _subscribeToMessages();
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
    _channel = Supabase.instance.client
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
        // На случай, если Realtime тоже пришлёт это же сообщение отдельно —
        // не показываем его дважды.
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

  @override
  void dispose() {
    _channel?.unsubscribe();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.chatTitle)),
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
                          Text(
                            '${msg.createdAt.hour.toString().padLeft(2, '0')}:${msg.createdAt.minute.toString().padLeft(2, '0')}',
                            style: TextStyle(
                              fontSize: 10,
                              color: isMine
                                  ? Colors.white.withOpacity(0.75)
                                  : AppColors.textSecondary,
                            ),
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
