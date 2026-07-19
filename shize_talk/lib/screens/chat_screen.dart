import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/chat_attachment_compress.dart';
import '../theme/app_theme.dart';

class Message {
  final String id;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime createdAt; // всегда хранится в local time (см. fromMap)

  // Вложение (фото или произвольный файл) — null, если сообщение только текст.
  final String? attachmentPath;
  final String? attachmentType; // 'image' | 'file'
  final String? attachmentName;
  final int? attachmentSizeBytes;
  final int? attachmentWidth;
  final int? attachmentHeight;

  bool get hasAttachment => attachmentPath != null;
  bool get isImageAttachment => attachmentType == 'image';

  Message({
    required this.id,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.createdAt,
    this.attachmentPath,
    this.attachmentType,
    this.attachmentName,
    this.attachmentSizeBytes,
    this.attachmentWidth,
    this.attachmentHeight,
  });

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as String,
      senderId: map['sender_id'] as String? ?? '',
      senderName: map['sender_name'] as String,
      content: map['content'] as String? ?? '',
      // Supabase отдаёт timestamptz в UTC — .toLocal() переводит его в
      // часовой пояс, установленный на устройстве пользователя.
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      attachmentPath: map['attachment_path'] as String?,
      attachmentType: map['attachment_type'] as String?,
      attachmentName: map['attachment_name'] as String?,
      attachmentSizeBytes: map['attachment_size_bytes'] as int?,
      attachmentWidth: map['attachment_width'] as int?,
      attachmentHeight: map['attachment_height'] as int?,
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
  bool _uploadingAttachment = false;

  // Подписанные ссылки на вложения истекают, поэтому не хранятся в БД —
  // кэшируем на время жизни экрана, чтобы не дёргать Storage на каждый
  // rebuild списка сообщений.
  final Map<String, String> _signedUrlCache = {};

  static const _maxAttachmentBytes = 20 * 1024 * 1024; // 20 МБ — см. bucket limit

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

  Future<void> _pickAttachment() async {
    final choice = await showModalBottomSheet<_AttachmentChoice>(
      context: context,
      backgroundColor: AppColors.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 16, bottom: 8),
              child: Text('Отправить', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.photo_outlined, color: AppColors.cyan),
              title: const Text('Фото'),
              subtitle: const Text('Сожмётся перед отправкой', style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.of(sheetContext).pop(_AttachmentChoice.photo),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file, color: AppColors.cyan),
              title: const Text('Файл'),
              subtitle: const Text('Любой формат, до 20 МБ', style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.of(sheetContext).pop(_AttachmentChoice.file),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (choice == null) return;
    if (choice == _AttachmentChoice.photo) {
      await _sendPhoto();
    } else {
      await _sendFile();
    }
  }

  Future<void> _sendPhoto() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    if (_myUserId == null) return;

    setState(() => _uploadingAttachment = true);
    try {
      final rawBytes = await file.readAsBytes();
      final compressed = await compressChatImage(rawBytes);

      final messageId = _generateAttachmentId();
      final path = '${widget.chatId}/$messageId.jpg';

      await Supabase.instance.client.storage.from('chat_attachments').uploadBinary(
            path,
            compressed.bytes,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );

      await _insertAttachmentMessage(
        attachmentPath: path,
        attachmentType: 'image',
        attachmentName: file.name,
        attachmentSizeBytes: compressed.bytes.lengthInBytes,
        attachmentWidth: compressed.width,
        attachmentHeight: compressed.height,
      );
    } on StorageException catch (e) {
      _showError('Не удалось загрузить фото: ${e.message}');
    } catch (e) {
      _showError('Ошибка отправки фото: $e');
    } finally {
      if (mounted) setState(() => _uploadingAttachment = false);
    }
  }

  Future<void> _sendFile() async {
    final result = await FilePicker.pickFiles(withData: true);
    if (result == null || result.files.isEmpty) return;
    if (_myUserId == null) return;

    final picked = result.files.first;
    final bytes = picked.bytes;
    if (bytes == null) {
      _showError('Не удалось прочитать файл');
      return;
    }
    if (bytes.lengthInBytes > _maxAttachmentBytes) {
      _showError('Файл больше 20 МБ — выберите файл поменьше');
      return;
    }

    setState(() => _uploadingAttachment = true);
    try {
      final messageId = _generateAttachmentId();
      final ext = picked.extension != null ? '.${picked.extension}' : '';
      final path = '${widget.chatId}/$messageId$ext';

      await Supabase.instance.client.storage.from('chat_attachments').uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'application/octet-stream'),
          );

      await _insertAttachmentMessage(
        attachmentPath: path,
        attachmentType: 'file',
        attachmentName: picked.name,
        attachmentSizeBytes: bytes.lengthInBytes,
      );
    } on StorageException catch (e) {
      _showError('Не удалось загрузить файл: ${e.message}');
    } catch (e) {
      _showError('Ошибка отправки файла: $e');
    } finally {
      if (mounted) setState(() => _uploadingAttachment = false);
    }
  }

  // Простой уникальный идентификатор для имени файла в Storage — реальный
  // id строки messages узнаём только после insert (см. _insertAttachmentMessage),
  // а путь к файлу нужен заранее, поэтому используем отдельный временный id.
  String _generateAttachmentId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_myUserId?.substring(0, 8) ?? 'anon'}';

  Future<void> _insertAttachmentMessage({
    required String attachmentPath,
    required String attachmentType,
    required String attachmentName,
    required int attachmentSizeBytes,
    int? attachmentWidth,
    int? attachmentHeight,
  }) async {
    try {
      final inserted = await Supabase.instance.client
          .from('messages')
          .insert({
            'chat_id': widget.chatId,
            'sender_id': _myUserId,
            'sender_name': _displayName.isEmpty ? 'Без имени' : _displayName,
            'content': '',
            'attachment_path': attachmentPath,
            'attachment_type': attachmentType,
            'attachment_name': attachmentName,
            'attachment_size_bytes': attachmentSizeBytes,
            if (attachmentWidth != null) 'attachment_width': attachmentWidth,
            if (attachmentHeight != null) 'attachment_height': attachmentHeight,
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
      _scrollToBottom();
    } on PostgrestException catch (e) {
      // Файл уже загружен в Storage, но запись сообщения не создалась —
      // подчищаем "осиротевший" файл, чтобы не копился мусор в бакете.
      await _tryDeleteOrphanedAttachment(attachmentPath);
      _showError('Не удалось отправить: ${e.message}');
    }
  }

  Future<void> _tryDeleteOrphanedAttachment(String path) async {
    try {
      await Supabase.instance.client.storage.from('chat_attachments').remove([path]);
    } catch (_) {
      // тихо игнорируем — не критично, просто останется неиспользуемый файл
    }
  }

  void _showError(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Подписанная ссылка на вложение — Storage bucket приватный, поэтому
  /// getPublicUrl не работает. Ссылки кэшируются на время жизни экрана
  /// (см. _signedUrlCache), срок жизни самой ссылки — сутки.
  Future<String?> _resolveAttachmentUrl(String path) async {
    final cached = _signedUrlCache[path];
    if (cached != null) return cached;
    try {
      final url = await Supabase.instance.client.storage
          .from('chat_attachments')
          .createSignedUrl(path, 60 * 60 * 24);
      _signedUrlCache[path] = url;
      return url;
    } catch (_) {
      return null;
    }
  }

  String _formatFileSize(int? bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return '$bytes Б';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }

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
                          if (msg.hasAttachment)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _AttachmentBubble(
                                message: msg,
                                resolveUrl: _resolveAttachmentUrl,
                                formatSize: _formatFileSize,
                              ),
                            ),
                          if (msg.content.trim().isNotEmpty)
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
                                      ? Colors.white.withValues(alpha: 0.75)
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
                                      : Colors.white.withValues(alpha: 0.75),
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
                  IconButton(
                    icon: _uploadingAttachment
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
                          )
                        : const Icon(Icons.attach_file, color: AppColors.cyan),
                    onPressed: _uploadingAttachment ? null : _pickAttachment,
                  ),
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

enum _AttachmentChoice { photo, file }

/// Вложение внутри пузыря сообщения — картинка с превью (тап открывает
/// полноэкранный просмотр) или карточка файла с именем/размером и кнопкой
/// открыть/скачать. Подписанная ссылка запрашивается лениво через
/// FutureBuilder, чтобы не блокировать рендер списка сообщений.
class _AttachmentBubble extends StatelessWidget {
  final Message message;
  final Future<String?> Function(String path) resolveUrl;
  final String Function(int? bytes) formatSize;

  const _AttachmentBubble({
    required this.message,
    required this.resolveUrl,
    required this.formatSize,
  });

  @override
  Widget build(BuildContext context) {
    final path = message.attachmentPath;
    if (path == null) return const SizedBox.shrink();

    return FutureBuilder<String?>(
      future: resolveUrl(path),
      builder: (context, snapshot) {
        final url = snapshot.data;

        if (message.isImageAttachment) {
          return _ImageAttachment(url: url, message: message);
        }
        return _FileAttachment(url: url, message: message, formatSize: formatSize);
      },
    );
  }
}

class _ImageAttachment extends StatelessWidget {
  final String? url;
  final Message message;
  const _ImageAttachment({required this.url, required this.message});

  @override
  Widget build(BuildContext context) {
    // Пока ссылка не готова (или картинка ещё грузится) — плейсхолдер
    // правильных пропорций, чтобы список сообщений не "прыгал" при загрузке.
    final aspectRatio = (message.attachmentWidth != null && message.attachmentHeight != null)
        ? message.attachmentWidth! / message.attachmentHeight!
        : 1.0;

    if (url == null) {
      return AspectRatio(
        aspectRatio: aspectRatio,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 240),
          decoration: BoxDecoration(
            color: AppColors.surfaceAlt,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => _FullscreenImageScreen(url: url!)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240, maxHeight: 320),
          child: Image.network(
            url!,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              width: 240,
              height: 240 / aspectRatio,
              color: AppColors.surfaceAlt,
              child: const Icon(Icons.broken_image_outlined, color: AppColors.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _FileAttachment extends StatelessWidget {
  final String? url;
  final Message message;
  final String Function(int? bytes) formatSize;
  const _FileAttachment({required this.url, required this.message, required this.formatSize});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: url == null
          ? null
          : () => launchUrl(Uri.parse(url!), mode: LaunchMode.externalApplication),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file_outlined, color: AppColors.cyan, size: 28),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.attachmentName ?? 'Файл',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    formatSize(message.attachmentSizeBytes),
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
            if (url == null)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FullscreenImageScreen extends StatelessWidget {
  final String url;
  const _FullscreenImageScreen({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(
        child: InteractiveViewer(
          child: Image.network(url),
        ),
      ),
    );
  }
}
