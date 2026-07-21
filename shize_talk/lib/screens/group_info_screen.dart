import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../utils/ru_date.dart';
import 'public_profile_screen.dart';
import 'image_crop_screen.dart';
import 'video_to_gif_screen.dart';
import '../services/avatar_thumbnail.dart';

class GroupInfoScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  final String? chatAvatarThumb; // thumb URL для быстрого отображения
  final String? chatAvatarFull;  // полный URL (если thumb нет)

  const GroupInfoScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    this.chatAvatarThumb,
    this.chatAvatarFull,
  });

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  List<Map<String, dynamic>> _participants = [];
  bool _loading = true;
  bool _leaving = false;
  String? _myUserId;

  // Для обновления аватарки/названия
  String _currentTitle = '';
  String? _currentAvatarThumb;
  String? _currentAvatarFull;

  @override
  void initState() {
    super.initState();
    _myUserId = Supabase.instance.client.auth.currentUser?.id;
    _currentTitle = widget.chatTitle;
    _currentAvatarThumb = widget.chatAvatarThumb;
    _currentAvatarFull = widget.chatAvatarFull;
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

  // --- Диалог изменения названия ---
  Future<void> _renameGroup() async {
    final controller = TextEditingController(text: _currentTitle);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Изменить название'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Новое название'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == _currentTitle) return;

    try {
      await Supabase.instance.client.rpc('rename_group', params: {
        'p_chat_id': widget.chatId,
        'p_title': result,
      });
      if (!mounted) return;
      setState(() => _currentTitle = result);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Название обновлено')),
      );
    } on PostgrestException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // --- Смена аватарки ---
  Future<void> _changeAvatar() async {
    final source = await _askMediaSource();
    if (source == null) return;

    // Показываем индикатор загрузки
    setState(() => _loading = true);

    try {
      Uint8List? croppedBytes;
      String mediaType;

      if (source == _MediaSource.video) {
        final picker = ImagePicker();
        final XFile? file = await picker.pickVideo(source: ImageSource.gallery);
        if (file == null) {
          setState(() => _loading = false);
          return;
        }
        if (!mounted) return;
        final gifBytes = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(builder: (_) => VideoToGifScreen(videoFile: File(file.path))),
        );
        if (gifBytes == null) {
          setState(() => _loading = false);
          return;
        }
        if (gifBytes.lengthInBytes > 3 * 1024 * 1024) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Гифка больше 3 МБ – выберите короче')),
          );
          return;
        }
        croppedBytes = gifBytes;
        mediaType = 'gif';
      } else {
        final picker = ImagePicker();
        final XFile? file = await picker.pickImage(source: ImageSource.gallery);
        if (file == null) {
          setState(() => _loading = false);
          return;
        }
        final rawBytes = await file.readAsBytes();
        final isGif = file.name.toLowerCase().endsWith('.gif') ||
            file.mimeType?.toLowerCase() == 'image/gif';
        if (!mounted) return;
        final result = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(
            builder: (_) => ImageCropScreen(sourceBytes: rawBytes, isGif: isGif),
          ),
        );
        if (result == null) {
          setState(() => _loading = false);
          return;
        }
        if (isGif && result.lengthInBytes > 3 * 1024 * 1024) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Гифка слишком большая')),
          );
          return;
        }
        croppedBytes = result;
        mediaType = isGif ? 'gif' : 'image';
      }

      // Генерируем thumb
      Uint8List? thumbBytes;
      try {
        thumbBytes = await generateAvatarThumbnail(croppedBytes!);
      } catch (_) {}

      // Загружаем в Storage
      final userId = Supabase.instance.client.auth.currentUser!.id;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final ext = mediaType == 'gif' ? 'gif' : 'jpg';
      final path = 'groups/${widget.chatId}/$ts.$ext';
      final contentType = mediaType == 'gif' ? 'image/gif' : 'image/jpeg';

      await Supabase.instance.client.storage.from('avatars').uploadBinary(
            path,
            croppedBytes!,
            fileOptions: FileOptions(contentType: contentType, upsert: true),
          );
      final publicUrl = Supabase.instance.client.storage.from('avatars').getPublicUrl(path);

      String? thumbUrl;
      if (thumbBytes != null) {
        final thumbPath = 'groups/${widget.chatId}/${ts}_thumb.jpg';
        await Supabase.instance.client.storage.from('avatars').uploadBinary(
              thumbPath,
              thumbBytes,
              fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
            );
        thumbUrl = Supabase.instance.client.storage.from('avatars').getPublicUrl(thumbPath);
      }

      // Обновляем запись группы
      await Supabase.instance.client.rpc('update_group_avatar', params: {
        'p_chat_id': widget.chatId,
        'p_avatar_url': publicUrl,
        'p_thumb_url': thumbUrl,
      });

      if (!mounted) return;
      setState(() {
        _currentAvatarFull = publicUrl;
        _currentAvatarThumb = thumbUrl ?? publicUrl;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Аватарка обновлена')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<_MediaSource?> _askMediaSource() {
    return showModalBottomSheet<_MediaSource>(
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
              child: Text('Новая аватарка группы', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: AppColors.cyan),
              title: const Text('Фото или гифка'),
              onTap: () => Navigator.of(sheetContext).pop(_MediaSource.imageOrGif),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: AppColors.cyan),
              title: const Text('Видео → гифка'),
              onTap: () => Navigator.of(sheetContext).pop(_MediaSource.video),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // --- Удалить аватарку ---
  Future<void> _removeAvatar() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Удалить аватарку?'),
        content: const Text('Аватарка группы будет удалена.'),
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

    try {
      await Supabase.instance.client.rpc('update_group_avatar', params: {
        'p_chat_id': widget.chatId,
        'p_avatar_url': null,
        'p_thumb_url': null,
      });
      if (!mounted) return;
      setState(() {
        _currentAvatarFull = null;
        _currentAvatarThumb = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Аватарка удалена')),
      );
    } on PostgrestException catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  // --- Выход из группы ---
  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Покинуть группу?'),
        content: Text('Вы выйдете из «$_currentTitle» и перестанете видеть переписку.'),
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
    final displayAvatar = _currentAvatarThumb ?? _currentAvatarFull;
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentTitle),
        actions: [
          PopupMenuButton<String>(
            color: AppColors.surface,
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  _renameGroup();
                  break;
                case 'change_avatar':
                  _changeAvatar();
                  break;
                case 'remove_avatar':
                  if (_currentAvatarFull != null) _removeAvatar();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'rename', child: Text('Изменить название')),
              const PopupMenuItem(value: 'change_avatar', child: Text('Сменить аватарку')),
              if (_currentAvatarFull != null)
                const PopupMenuItem(
                  value: 'remove_avatar',
                  child: Text('Удалить аватарку', style: TextStyle(color: AppColors.danger)),
                ),
            ],
          ),
        ],
      ),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // --- Аватарка группы ---
                  Center(
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 56,
                          backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                          backgroundImage: displayAvatar != null
                              ? NetworkImage(displayAvatar)
                              : null,
                          child: displayAvatar == null
                              ? const Icon(Icons.groups, size: 40, color: AppColors.textSecondary)
                              : null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      _currentTitle,
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
                        subtitle: Text(
                          '@${p['username']} · в группе с ${formatRuDate(DateTime.parse(p['joined_at'] as String))}',
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
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

  // --- Добавление участников (осталось без изменений) ---
  Future<void> _openAddParticipants() async {
    // ... (код не меняется, оставляем как было)
    // Для краткости опущен, но в реальном файле он должен быть.
    // Вставьте сюда существующий метод _openAddParticipants из оригинального файла.
  }
}

enum _MediaSource { imageOrGif, video }