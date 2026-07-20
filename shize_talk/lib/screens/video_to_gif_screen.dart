import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb, compute;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_video_thumbnail_plus/flutter_video_thumbnail_plus.dart';
import 'package:image/image.dart' as img;
import '../theme/app_theme.dart';
import '../widgets/avatar_cropper.dart';

/// Экран выбора участка видео (обрезка по времени + квадратный кроп кадра)
/// и сборки выбранного фрагмента в гифку — аналог "выбрать область видео
/// для аватарки" в Telegram/Discord.
///
/// ВАЖНО — почему тут больше нет ffmpeg: пакеты семейства
/// ffmpeg_kit_flutter(_new/_min/...) — это неофициальные форки давно
/// заброшенного проекта ffmpeg-kit (оригинал архивирован в 2025 из-за
/// проблем с Google Play и GPL/LGPL-лицензированием бинарников). Форки
/// нестабильны вплоть до того, что отдельные версии на pub.dev физически
/// не содержат заявленных файлов (`ffmpeg_kit.dart` и т.п.) — это ломается
/// у всех, кто их ставит, а не только локально, и не чинится переустановкой.
///
/// Вместо этого видео разбирается на несколько кадров через video_thumbnail
/// (маленький нативный плагин, без тяжёлых бинарников, давно стабилен),
/// кадры кропаются и собираются в анимированный GIF пакетом image — тем же,
/// что уже используется в проекте для превьюшек. Работает на Android/iOS —
/// на Web/десктопе показываем понятное сообщение вместо падения.
class VideoToGifScreen extends StatefulWidget {
  final File videoFile;
  const VideoToGifScreen({super.key, required this.videoFile});

  @override
  State<VideoToGifScreen> createState() => _VideoToGifScreenState();
}

class _VideoToGifScreenState extends State<VideoToGifScreen> {
  late final VideoPlayerController _videoController;
  bool _initializing = true;
  bool _exporting = false;
  String? _error;

  CropRegion _region = const CropRegion(x: 0, y: 0, size: 1);
  RangeValues _trim = const RangeValues(0, 0);
  double _videoSeconds = 0;

  static const _maxGifSeconds = 4.0; // короче, чем было — кадры тут "дороже" ffmpeg-палитры
  static const _frameCount = 10; // ~ fps итоговой гифки при таком лимите секунд
  static const _targetSize = 240; // сторона квадратной гифки в пикселях

  bool get _videoPickingSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    _videoController = VideoPlayerController.file(widget.videoFile);
    _init();
  }

  Future<void> _init() async {
    try {
      await _videoController.initialize();
      final totalSeconds = _videoController.value.duration.inMilliseconds / 1000.0;
      final end = totalSeconds < _maxGifSeconds ? totalSeconds : _maxGifSeconds;
      await _videoController.setLooping(true);
      await _videoController.play();
      if (!mounted) return;
      setState(() {
        _videoSeconds = totalSeconds;
        _trim = RangeValues(0, end);
        _initializing = false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось открыть видео: $e');
    }
  }

  @override
  void dispose() {
    _videoController.dispose();
    super.dispose();
  }

  void _onTrimChanged(RangeValues values) {
    var start = values.start;
    var end = values.end;
    if (end - start > _maxGifSeconds) {
      if (start != _trim.start) {
        end = start + _maxGifSeconds;
      } else {
        start = end - _maxGifSeconds;
      }
    }
    setState(() => _trim = RangeValues(start, end));
    _videoController.seekTo(Duration(milliseconds: (start * 1000).round()));
  }

  String _fmt(double seconds) {
    final d = Duration(milliseconds: (seconds * 1000).round());
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _exportGif() async {
    if (!_videoPickingSupported) {
      setState(() => _error =
          'Аватарка из видео пока доступна только в мобильном приложении (Android/iOS).');
      return;
    }

    setState(() {
      _exporting = true;
      _error = null;
    });

    try {
      final startMs = (_trim.start * 1000).round();
      final endMs = (_trim.end * 1000).round();
      final durationMs = (endMs - startMs).clamp(200, (_maxGifSeconds * 1000).round());
      final stepMs = durationMs / _frameCount;

      // 1. Вытаскиваем N кадров нужного участка через video_thumbnail —
      // лёгкая нативная операция, без временных .gif/.mp4 файлов на диске.
      final frameBytesList = <Uint8List>[];
      for (var i = 0; i < _frameCount; i++) {
        final timeMs = startMs + (stepMs * i).round();
        final bytes = await FlutterVideoThumbnailPlus.thumbnailData(
          video: widget.videoFile.path,
          imageFormat: ImageFormat.jpeg,
          timeMs: timeMs,
          quality: 80,
          maxWidth: 720, // с запасом по разрешению — обрежем/сожмём дальше сами
        );
        if (bytes != null) frameBytesList.add(bytes);
      }

      if (frameBytesList.length < 3) {
        setState(() => _error = 'Не удалось получить достаточно кадров из этого видео.');
        return;
      }

      // 2. Кроп (по той же области, что выбрана в AvatarCropper) + ресайз +
      // сборка анимированного GIF — тяжёлая часть считается в отдельном
      // изоляте, чтобы не подвесить UI.
      final gifBytes = await compute(
        _buildGifSync,
        _GifBuildArgs(
          frames: frameBytesList,
          region: _region,
          targetSize: _targetSize,
          frameDurationMs: stepMs.round(),
        ),
      );

      if (!mounted) return;
      Navigator.of(context).pop<Uint8List>(gifBytes);
    } catch (e) {
      setState(() => _error = 'Ошибка сборки гифки: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Участок видео → гифка')),
      body: RetroBackground(
        child: _initializing
            ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      if (!_videoPickingSupported)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Аватарка из видео работает только в мобильном приложении '
                            '(Android/iOS) — на вебе и десктопе сейчас недоступна.',
                            style: TextStyle(color: AppColors.danger, fontSize: 13),
                          ),
                        ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                        ),
                      const Text(
                        'Сведите пальцы, чтобы приблизить, и передвиньте кадр — '
                        'в рамку попадёт то, что станет аватаркой.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: AvatarCropper(
                          sourceAspectRatio: _videoController.value.aspectRatio,
                          onRegionChanged: (r) => _region = r,
                          child: VideoPlayer(_videoController),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Участок ${_fmt(_trim.start)}–${_fmt(_trim.end)} '
                        '(до ${_maxGifSeconds.toInt()} сек)',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                      ),
                      RangeSlider(
                        values: _trim,
                        min: 0,
                        max: _videoSeconds == 0 ? 1 : _videoSeconds,
                        activeColor: AppColors.cyan,
                        onChanged: _onTrimChanged,
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _exporting || !_videoPickingSupported ? null : _exportGif,
                          child: _exporting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Text('Сделать гифку'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _GifBuildArgs {
  final List<Uint8List> frames;
  final CropRegion region;
  final int targetSize;
  final int frameDurationMs;

  const _GifBuildArgs({
    required this.frames,
    required this.region,
    required this.targetSize,
    required this.frameDurationMs,
  });
}

/// Кропает и ресайзит каждый кадр по одной и той же области (выбранной один
/// раз в AvatarCropper — все извлечённые кадры одного видео имеют одинаковое
/// разрешение, так что пиксельный прямоугольник считается один раз по
/// первому кадру и переиспользуется для остальных), затем собирает всё в
/// один анимированный GIF. Выполняется в отдельном изоляте через compute().
Uint8List _buildGifSync(_GifBuildArgs args) {
  img.Image? firstFrame;

  for (final frameBytes in args.frames) {
    final decoded = img.decodeJpg(frameBytes);
    if (decoded == null) continue;

    final rect = args.region.toPixelRect(decoded.width, decoded.height);
    final cropped = img.copyCrop(
      decoded,
      x: rect.left,
      y: rect.top,
      width: rect.side,
      height: rect.side,
    );
    final resized = img.copyResize(cropped, width: args.targetSize, height: args.targetSize);
    resized.frameDuration = args.frameDurationMs;

    if (firstFrame == null) {
      firstFrame = resized;
    } else {
      firstFrame.addFrame(resized);
    }
  }

  if (firstFrame == null) {
    throw const FormatException('Не удалось собрать кадры видео в гифку');
  }

  firstFrame.loopCount = 0; // зациклено бесконечно
  return img.encodeGif(firstFrame);
}
