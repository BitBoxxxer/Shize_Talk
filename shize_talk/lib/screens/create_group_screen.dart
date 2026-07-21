import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import 'image_crop_screen.dart';
import 'video_to_gif_screen.dart';
import '../services/avatar_thumbnail.dart';

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

  // --- Avatar state ---
  Uint8List? _avatarBytes;       // финальные байты после кропа (jpg или gif)
  String? _avatarMediaType;      // 'image' или 'gif'
  Uint8List? _thumbBytes;        // сгенерированное превью (jpg)
  bool _hasAvatar = false;
  bool _uploadingAvatar = false;

  static const _maxGifBytes = 3 * 1024 * 1024;

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

  // --- Выбор аватарки (аналогично AvatarScreen) ---
  Future<void> _pickAvatar() async {
    final source = await _askMediaSource();
    if (source == null) return;

    setState(() => _uploadingAvatar = true);

    try {
      Uint8List? croppedBytes;
      String mediaType;

      if (source == _MediaSource.video) {
        final picker = ImagePicker();
        final XFile? file = await picker.pickVideo(source: ImageSource.gallery);
        if (file == null) {
          setState(() => _uploadingAvatar = false);
          return;
        }
        if (!mounted) return;
        final gifBytes = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(builder: (_) => VideoToGifScreen(videoFile: File(file.path))),
        );
        if (gifBytes == null) {
          setState(() => _uploadingAvatar = false);
          return;
        }
        if (gifBytes.lengthInBytes > _maxGifBytes) {
          setState(() => _error = 'Гифка из видео больше 3 МБ – выберите более короткий участок');
          return;
        }
        croppedBytes = gifBytes;
        mediaType = 'gif';
      } else {
        final picker = ImagePicker();
        final XFile? file = await picker.pickImage(source: ImageSource.gallery);
        if (file == null) {
          setState(() => _uploadingAvatar = false);
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
          setState(() => _uploadingAvatar = false);
          return;
        }
        if (isGif && result.lengthInBytes > _maxGifBytes) {
          setState(() => _error = 'Гифка слишком большая (максимум 3 МБ)');
          return;
        }
        croppedBytes = result;
        mediaType = isGif ? 'gif' : 'image';
      }

      // Генерируем превью (thumb) – статичный JPEG из первого кадра
      Uint8List? thumb;
      try {
        thumb = await generateAvatarThumbnail(croppedBytes!);
      } catch (_) {
        // если не удалось – продолжим без превью
      }

      if (!mounted) return;
      setState(() {
        _avatarBytes = croppedBytes;
        _avatarMediaType = mediaType;
        _thumbBytes = thumb;
        _hasAvatar = true;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Ошибка выбора аватарки: $e');
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
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
              child: Text('Аватарка группы', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined, color: AppColors.cyan),
              title: const Text('Фото или гифка'),
              subtitle: const Text('Выберите область после загрузки', style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.of(sheetContext).pop(_MediaSource.imageOrGif),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined, color: AppColors.cyan),
              title: const Text('Видео → гифка'),
              subtitle: const Text('Выберите участок и область кадра', style: TextStyle(fontSize: 12)),
              onTap: () => Navigator.of(sheetContext).pop(_MediaSource.video),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // --- Создание группы с последующей загрузкой аватарки ---
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
      // 1. Создаём группу (пока без аватарки)
      final chatId = await Supabase.instance.client.rpc('create_group_chat', params: {
        'p_title': title,
        'p_member_ids': _selected.toList(),
        // avatar_url и thumb_url пока null
      }) as String;

      // 2. Если выбрана аватарка – загружаем в Storage и обновляем группу
      if (_hasAvatar && _avatarBytes != null) {
        final userId = Supabase.instance.client.auth.currentUser!.id;
        final ts = DateTime.now().millisecondsSinceEpoch;
        final ext = _avatarMediaType == 'gif' ? 'gif' : 'jpg';
        final path = 'groups/$chatId/$ts.$ext';
        final contentType = _avatarMediaType == 'gif' ? 'image/gif' : 'image/jpeg';

        // Загружаем основной файл
        await Supabase.instance.client.storage.from('avatars').uploadBinary(
              path,
              _avatarBytes!,
              fileOptions: FileOptions(contentType: contentType, upsert: true),
            );
        final publicUrl = Supabase.instance.client.storage.from('avatars').getPublicUrl(path);

        // Загружаем превью (если есть)
        String? thumbUrl;
        if (_thumbBytes != null) {
          final thumbPath = 'groups/$chatId/${ts}_thumb.jpg';
          await Supabase.instance.client.storage.from('avatars').uploadBinary(
                thumbPath,
                _thumbBytes!,
                fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
              );
          thumbUrl = Supabase.instance.client.storage.from('avatars').getPublicUrl(thumbPath);
        }

        // Обновляем запись группы
        await Supabase.instance.client.rpc('update_group_avatar', params: {
          'p_chat_id': chatId,
          'p_avatar_url': publicUrl,
          'p_thumb_url': thumbUrl,
        });
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            chatId: chatId,
            chatTitle: title,
            isGroup: true,
            // chatAvatarThumb можно передать, если нужно – но можно и не передавать,
            // ChatScreen подгрузит при необходимости. Оставим null.
          ),
        ),
      );
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка: $e');
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
                  // --- Виджет аватарки с возможностью выбора ---
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: GestureDetector(
                      onTap: _uploadingAvatar ? null : _pickAvatar,
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          CircleAvatar(
                            radius: 48,
                            backgroundColor: AppColors.purple.withValues(alpha: 0.3),
                            backgroundImage: _hasAvatar && _thumbBytes != null
                                ? MemoryImage(_thumbBytes!)
                                : null,
                            child: !_hasAvatar
                                ? const Icon(Icons.group_add, size: 36, color: AppColors.textSecondary)
                                : null,
                          ),
                          if (_uploadingAvatar)
                            const Positioned.fill(
                              child: Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan),
                                ),
                              ),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.all(5),
                              decoration: const BoxDecoration(
                                gradient: AppColors.primaryGradient,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.camera_alt, size: 16, color: Colors.white),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_hasAvatar)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Нажмите, чтобы изменить',
                        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ),
                  const SizedBox(height: 12),

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
                        onPressed: (_creating || _uploadingAvatar) ? null : _create,
                        child: _creating || _uploadingAvatar
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

enum _MediaSource { imageOrGif, video }