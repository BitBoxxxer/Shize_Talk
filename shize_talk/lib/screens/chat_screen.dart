import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/chat_attachment_compress.dart';
import '../theme/app_theme.dart';
import 'public_profile_screen.dart';
import 'group_info_screen.dart';

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

  // Ответ на другое сообщение — храним только id, сам текст оригинала
  // ищем в уже загруженном списке _messages (см. ChatScreen._findMessageById).
  final String? replyToId;
  final bool isPinned;

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
    this.replyToId,
    this.isPinned = false,
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
      replyToId: map['reply_to_id'] as String?,
      isPinned: map['is_pinned'] as bool? ?? false,
    );
  }
}

class ChatScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  // Нужен, чтобы показывать "в сети"/"был(а) в сети" собеседника — только
  // для личных чатов.
  final String? otherUserId;
  // Групповой чат — тап по шапке открывает GroupInfoScreen вместо профиля.
  final bool isGroup;
  // Новые параметры для аватарки группы
  final String? chatAvatarThumb;
  final String? chatAvatarFull;

  const ChatScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    this.otherUserId,
    this.isGroup = false,
    this.chatAvatarThumb,
    this.chatAvatarFull,
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

  // Ответ на сообщение — выбирается через долгое нажатие, показывается
  // плашкой над полем ввода, сбрасывается после отправки/отмены.
  Message? _replyingTo;
  List<Map<String, dynamic>> _pinnedMessages = [];

  // Локальные копии названия/аватарки группы — widget.chatTitle и
  // widget.chatAvatarThumb/Full неизменяемы (пришли из конструктора при
  // открытии чата), а GroupInfoScreen может их поменять и вернуть новое
  // значение при закрытии (см. _openGroupInfo). Без этого шапка чата
  // продолжала бы показывать то, что было на момент входа в чат.
  late String _groupTitle = widget.chatTitle;
  late String? _groupAvatarThumb = widget.chatAvatarThumb;
  late String? _groupAvatarFull = widget.chatAvatarFull;

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
    _loadPinnedMessages();

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

  Future<void> _loadPinnedMessages() async {
    try {
      final data = await Supabase.instance.client
          .rpc('list_pinned_messages', params: {'p_chat_id': widget.chatId});
      if (!mounted) return;
      setState(() => _pinnedMessages = List<Map<String, dynamic>>.from(data as List));
    } catch (_) {}
  }

  // Ищем оригинал ответа среди уже загруженных сообщений — отдельный запрос
  // не нужен, весь чат (последние 200 сообщений) и так уже в памяти.
  Message? _findMessageById(String? id) {
    if (id == null) return null;
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  void _setReplyTo(Message msg) {
    setState(() => _replyingTo = msg);
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
  }

  Future<void> _togglePin(Message msg) async {
    try {
      await Supabase.instance.client.rpc(
        msg.isPinned ? 'unpin_message' : 'pin_message',
        params: {'p_message_id': msg.id},
      );
      await _loadPinnedMessages();
      await _loadMessages();
    } on PostgrestException catch (e) {
      _showError(e.message);
    }
  }

  Future<void> _deleteMessage(Message msg) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Удалить сообщение?'),
        content: const Text('Это действие нельзя отменить.'),
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

    // Сначала чистим файл в Storage (если был) — после удаления строки
    // сообщения путь к нему потеряется и файл-сирота останется навсегда.
    if (msg.attachmentPath != null) {
      await _tryDeleteOrphanedAttachment(msg.attachmentPath!);
    }

    try {
      await Supabase.instance.client.rpc('delete_message', params: {'p_message_id': msg.id});
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((m) => m.id == msg.id);
        _pinnedMessages.removeWhere((m) => m['id'] == msg.id);
      });
    } on PostgrestException catch (e) {
      _showError(e.message);
    }
  }

  void _showMessageActions(Message msg) {
    final isMine = msg.senderId == _myUserId;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceAlt,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.reply, color: AppColors.cyan),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(sheetContext);
                _setReplyTo(msg);
              },
            ),
            ListTile(
              leading: Icon(
                msg.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: AppColors.cyan,
              ),
              title: Text(msg.isPinned ? 'Открепить' : 'Закрепить'),
              onTap: () {
                Navigator.pop(sheetContext);
                _togglePin(msg);
              },
            ),
            if (isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.danger),
                title: const Text('Удалить', style: TextStyle(color: AppColors.danger)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _deleteMessage(msg);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showPinnedList() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surfaceAlt,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Закреплённые сообщения', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _pinnedMessages.length,
                  itemBuilder: (context, i) {
                    final p = _pinnedMessages[i];
                    final preview = ((p['content'] as String?)?.isNotEmpty == true)
                        ? p['content'] as String
                        : (p['attachment_type'] == 'image' ? '📷 Фото' : '📎 Файл');
                    return ListTile(
                      title: Text(p['sender_name'] as String? ?? '',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                      subtitle: Text(preview, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          await Supabase.instance.client
                              .rpc('unpin_message', params: {'p_message_id': p['id']});
                          _loadPinnedMessages();
                          _loadMessages();
                        },
                      ),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _scrollToMessage(p['id'] as String);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _scrollToMessage(String id) {
    final index = _messages.indexWhere((m) => m.id == id);
    if (index == -1 || !_scrollController.hasClients) return;
    // Приблизительная прокрутка по индексу — список без фиксированной высоты
    // элементов, поэтому точный jumpTo невозможен без доп. измерений; этого
    // достаточно, чтобы вывести нужное сообщение в область видимости.
    final estimatedOffset = (index / _messages.length) * _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      estimatedOffset.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

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
            if (_replyingTo != null) 'reply_to_id': _replyingTo!.id,
          })
          .select()
          .single();

      if (!mounted) return;

      final message = Message.fromMap(inserted);
      setState(() {
        if (!_messages.any((m) => m.id == message.id)) {
          _messages.add(message);
        }
        _replyingTo = null;
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

  // ------------------------------------------------------------
  //  Изменённый метод _sendFile — использует file_selector вместо file_picker
  // ------------------------------------------------------------
  Future<void> _sendFile() async {
    // Открываем диалог выбора одного файла с помощью file_selector
    final XFile? file = await openFile();
    if (file == null) return; // пользователь отменил выбор
    if (_myUserId == null) return;

    final bytes = await file.readAsBytes();
    if (bytes.lengthInBytes > _maxAttachmentBytes) {
      _showError('Файл больше 20 МБ — выберите файл поменьше');
      return;
    }

    setState(() => _uploadingAttachment = true);
    try {
      final messageId = _generateAttachmentId();
      final name = file.name;
      // Определяем расширение из имени файла
      final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
      final path = '${widget.chatId}/$messageId$ext';

      await Supabase.instance.client.storage.from('chat_attachments').uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(contentType: 'application/octet-stream'),
          );

      await _insertAttachmentMessage(
        attachmentPath: path,
        attachmentType: 'file',
        attachmentName: name,
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
            'attachment_width': ?attachmentWidth,
            'attachment_height': ?attachmentHeight,
            if (_replyingTo != null) 'reply_to_id': _replyingTo!.id,
          })
          .select()
          .single();

      if (!mounted) return;
      final message = Message.fromMap(inserted);
      setState(() {
        if (!_messages.any((m) => m.id == message.id)) {
          _messages.add(message);
        }
        _replyingTo = null;
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
    final displayAvatar = _groupAvatarThumb ?? _groupAvatarFull;
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: widget.isGroup
              ? () async {
                  final result = await Navigator.of(context).push<Map<String, String?>>(
                    MaterialPageRoute(
                      builder: (_) => GroupInfoScreen(
                        chatId: widget.chatId,
                        chatTitle: _groupTitle,
                        chatAvatarThumb: _groupAvatarThumb,
                        chatAvatarFull: _groupAvatarFull,
                      ),
                    ),
                  );
                  // GroupInfoScreen возвращает актуальные название/аватарку
                  // при закрытии (кнопкой или системным жестом) — без этого
                  // шапка чата так и показывала бы старые данные, введённые
                  // при открытии чата, до следующего полного перезахода.
                  if (result != null && mounted) {
                    setState(() {
                      _groupTitle = result['title'] ?? _groupTitle;
                      _groupAvatarThumb = result['avatarThumb'];
                      _groupAvatarFull = result['avatarFull'];
                    });
                  }
                }
              : widget.otherUserId == null
                  ? null
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => PublicProfileScreen(
                            userId: widget.otherUserId!,
                            initialDisplayName: widget.chatTitle,
                          ),
                        ),
                      );
                    },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.isGroup)
                CircleAvatar(
                  radius: 18,
                  backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                  backgroundImage: displayAvatar != null ? NetworkImage(displayAvatar) : null,
                  child: displayAvatar == null
                      ? const Icon(Icons.groups, size: 18, color: AppColors.textSecondary)
                      : null,
                ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.isGroup ? _groupTitle : widget.chatTitle),
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
            ],
          ),
        ),
        actions: [
          if (_pinnedMessages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.push_pin),
              tooltip: 'Закреплённые',
              onPressed: _showPinnedList,
            ),
        ],
      ),
      body: RetroBackground(
        child: Column(
          children: [
            if (_pinnedMessages.isNotEmpty)
              Material(
                color: AppColors.surfaceAlt,
                child: InkWell(
                  onTap: _showPinnedList,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.push_pin, size: 16, color: AppColors.cyan),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            ((_pinnedMessages.first['content'] as String?)?.isNotEmpty == true)
                                ? _pinnedMessages.first['content'] as String
                                : (_pinnedMessages.first['attachment_type'] == 'image'
                                    ? '📷 Фото'
                                    : '📎 Файл'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
                          ),
                        ),
                        if (_pinnedMessages.length > 1)
                          Text('${_pinnedMessages.length}',
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final msg = _messages[index];
                  final isMine = msg.senderId == _myUserId;
                  final isRead = isMine && _isReadByOther(msg);
                  final repliedTo = _findMessageById(msg.replyToId);
                  return Align(
                    alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onLongPress: () => _showMessageActions(msg),
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
                            if (msg.replyToId != null)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.18),
                                  borderRadius: BorderRadius.circular(8),
                                  border: const Border(
                                    left: BorderSide(color: AppColors.cyan, width: 2.5),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      repliedTo?.senderName ?? 'Сообщение',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.cyan,
                                      ),
                                    ),
                                    Text(
                                      repliedTo == null
                                          ? 'Сообщение недоступно'
                                          : (repliedTo.content.trim().isNotEmpty
                                              ? repliedTo.content
                                              : (repliedTo.isImageAttachment ? '📷 Фото' : '📎 Файл')),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isMine
                                            ? Colors.white.withValues(alpha: 0.85)
                                            : AppColors.textSecondary,
                                      ),
                                    ),
                                  ],
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
                                if (msg.isPinned) ...[
                                  Icon(
                                    Icons.push_pin,
                                    size: 11,
                                    color: isMine
                                        ? Colors.white.withValues(alpha: 0.75)
                                        : AppColors.textSecondary,
                                  ),
                                  const SizedBox(width: 3),
                                ],
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
                    ),
                  );
                },
              ),
            ),
            if (_replyingTo != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                color: AppColors.surfaceAlt,
                child: Row(
                  children: [
                    const Icon(Icons.reply, size: 16, color: AppColors.cyan),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _replyingTo!.senderName,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.cyan),
                          ),
                          Text(
                            _replyingTo!.content.trim().isNotEmpty
                                ? _replyingTo!.content
                                : (_replyingTo!.isImageAttachment ? '📷 Фото' : '📎 Файл'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                      onPressed: _cancelReply,
                    ),
                  ],
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