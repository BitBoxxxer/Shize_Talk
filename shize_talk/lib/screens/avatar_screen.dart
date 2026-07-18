import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'image_crop_screen.dart';
import 'video_to_gif_screen.dart';

// Галерея аватарок: можно загрузить несколько картинок/гифок и переключаться
// между ними — активная показывается везде (профиль, список чатов, друзья).
//
// Перед загрузкой пользователь выбирает область картинки/гифки/видео на
// экране-кроппере (pinch/drag, как в Telegram/Discord) — так широкие фото
// с героем не в центре можно аккуратно подогнать под квадратную аватарку.
// Видео конвертируется в гифку на устройстве через ffmpeg_kit_flutter_new
// (только Android/iOS/macOS — на Web эта опция скрыта).
class AvatarScreen extends StatefulWidget {
  const AvatarScreen({super.key});

  @override
  State<AvatarScreen> createState() => _AvatarScreenState();
}

class _AvatarScreenState extends State<AvatarScreen> {
  List<Map<String, dynamic>> _avatars = [];
  bool _loading = true;
  bool _uploading = false;
  String? _error;

  static const _maxGifBytes = 3 * 1024 * 1024; // 3 МБ — компактное хранение

  @override
  void initState() {
    super.initState();
    _loadAvatars();
  }

  Future<void> _loadAvatars() async {
    setState(() => _loading = true);
    try {
      final data = await Supabase.instance.client.rpc('list_my_avatars');
      if (!mounted) return;
      setState(() => _avatars = List<Map<String, dynamic>>.from(data as List));
    } catch (e) {
      setState(() => _error = 'Не удалось загрузить аватарки: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAndUpload() async {
    final source = await _askMediaSource();
    if (source == null) return;

    setState(() {
      _uploading = true;
      _error = null;
    });

    try {
      Uint8List uploadBytes;
      String ext;
      String mediaType;

      if (source == _MediaSource.video) {
        final picker = ImagePicker();
        final XFile? file = await picker.pickVideo(source: ImageSource.gallery);
        if (file == null) {
          setState(() => _uploading = false);
          return;
        }
        if (!mounted) return;
        final gifBytes = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(builder: (_) => VideoToGifScreen(videoFile: File(file.path))),
        );
        if (gifBytes == null) {
          setState(() => _uploading = false);
          return; // пользователь отменил на экране видео→гифка
        }
        if (gifBytes.lengthInBytes > _maxGifBytes) {
          setState(() => _error =
              'Гифка из видео получилась больше 3 МБ — выберите более короткий участок');
          return;
        }
        uploadBytes = gifBytes;
        ext = 'gif';
        mediaType = 'gif';
      } else {
        final picker = ImagePicker();
        final XFile? file = await picker.pickImage(source: ImageSource.gallery);
        if (file == null) {
          setState(() => _uploading = false);
          return;
        }

        final rawBytes = await file.readAsBytes();
        final isGif = file.name.toLowerCase().endsWith('.gif') ||
            file.mimeType?.toLowerCase() == 'image/gif';

        if (!mounted) return;
        final croppedBytes = await Navigator.of(context).push<Uint8List>(
          MaterialPageRoute(
            builder: (_) => ImageCropScreen(sourceBytes: rawBytes, isGif: isGif),
          ),
        );
        if (croppedBytes == null) {
          setState(() => _uploading = false);
          return; // пользователь отменил кроп
        }

        if (isGif) {
          if (croppedBytes.lengthInBytes > _maxGifBytes) {
            setState(() => _error =
                'Гифка слишком большая (максимум 3 МБ) — выберите файл поменьше, '
                'чтобы не раздувать базу данных');
            return;
          }
          uploadBytes = croppedBytes;
          ext = 'gif';
          mediaType = 'gif';
        } else {
          uploadBytes = croppedBytes;
          ext = 'jpg';
          mediaType = 'image';
        }
      }

      final userId = Supabase.instance.client.auth.currentUser!.id;
      final path = '$userId/${DateTime.now().millisecondsSinceEpoch}.$ext';

      await Supabase.instance.client.storage.from('avatars').uploadBinary(
            path,
            uploadBytes,
            fileOptions: FileOptions(
              contentType: mediaType == 'gif' ? 'image/gif' : 'image/jpeg',
              upsert: true,
            ),
          );

      final publicUrl = Supabase.instance.client.storage.from('avatars').getPublicUrl(path);

      await Supabase.instance.client.rpc('add_profile_avatar', params: {
        'p_storage_path': path,
        'p_public_url': publicUrl,
        'p_media_type': mediaType,
      });

      await _loadAvatars();
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка загрузки: $e');
    } finally {
      if (mounted) setState(() => _uploading = false);
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
              child: Text('Новая аватарка', style: TextStyle(fontWeight: FontWeight.w700)),
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

  Future<void> _setActive(String avatarId) async {
    try {
      await Supabase.instance.client.rpc('set_active_avatar', params: {'p_avatar_id': avatarId});
      await _loadAvatars();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(Map<String, dynamic> avatar) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surfaceAlt,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Удалить аватарку?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await Supabase.instance.client.rpc('delete_profile_avatar', params: {'p_avatar_id': avatar['id']});

      // Физический файл из Storage удаляем отдельно, чтобы не копить мусор.
      final url = avatar['public_url'] as String;
      final marker = '/avatars/';
      final idx = url.indexOf(marker);
      if (idx != -1) {
        final path = url.substring(idx + marker.length);
        await Supabase.instance.client.storage.from('avatars').remove([path]);
      }

      await _loadAvatars();
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Аватарки')),
      body: RetroBackground(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Можно загрузить несколько картинок, гифок или видео и выбрать, '
                      'какая аватарка будет активной. При добавлении можно выбрать '
                      'область картинки/гифки/видео, которая попадёт в кадр.',
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: AppColors.danger)),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: GridView.builder(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                        itemCount: _avatars.length + 1,
                        itemBuilder: (context, index) {
                          if (index == _avatars.length) {
                            return _AddTile(uploading: _uploading, onTap: _uploading ? null : _pickAndUpload);
                          }
                          final avatar = _avatars[index];
                          final isActive = avatar['is_active'] == true;
                          return GestureDetector(
                            onTap: () => _setActive(avatar['id'] as String),
                            onLongPress: () => _delete(avatar),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Image.network(
                                    avatar['public_url'] as String,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      color: AppColors.surface,
                                      child: const Icon(Icons.broken_image, color: AppColors.textSecondary),
                                    ),
                                  ),
                                ),
                                if (isActive)
                                  Positioned(
                                    right: 4,
                                    top: 4,
                                    child: Container(
                                      padding: const EdgeInsets.all(3),
                                      decoration: const BoxDecoration(
                                        color: AppColors.success,
                                        shape: BoxShape.circle,
                                      ),
                                      child: const Icon(Icons.check, size: 14, color: Colors.white),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Нажмите на аватарку, чтобы сделать её активной. '
                      'Долгое нажатие — удалить.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final bool uploading;
  final VoidCallback? onTap;
  const _AddTile({required this.uploading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.cyan.withValues(alpha: 0.4)),
        ),
        child: Center(
          child: uploading
              ? const CircularProgressIndicator(strokeWidth: 2, color: AppColors.cyan)
              : const Icon(Icons.add_a_photo_outlined, color: AppColors.cyan),
        ),
      ),
    );
  }
}

enum _MediaSource { imageOrGif, video }
