import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_cropper.dart';

/// Экран выбора участка видео (обрезка по времени + квадратный кроп кадра)
/// и конвертации выбранного фрагмента в гифку — аналог "выбрать область видео
/// для аватарки" в Telegram/Discord.
///
/// Специально без пакета video_editor: он оказался нестабильным при
/// установке в этом проекте (pub указывал версию в дереве зависимостей,
/// но файлы пакета физически не резолвились для анализатора — похоже на
/// проблему сети/антивируса именно с загрузкой архива этого пакета).
/// Вместо этого используем то, что уже стабильно стоит в проекте:
/// video_player для превью + собственный AvatarCropper (тот же виджет,
/// что и для фото/гифки — единый UX и код) + ffmpeg_kit_flutter_new
/// с ручной командой trim+crop+gif. Работает только на Android/iOS/macOS —
/// на Web показываем понятное сообщение вместо падения.
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

  static const _maxGifSeconds = 6.0; // ограничение как в мессенджерах

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
    // Не даём растянуть выделение больше максимума (двигаем "хвост" следом
    // за тем краем, который пользователь тащит).
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
    if (kIsWeb) {
      setState(() => _error =
          'Конвертация видео в гифку пока недоступна в веб-версии — только на Android/iOS/macOS-приложении.');
      return;
    }

    setState(() {
      _exporting = true;
      _error = null;
    });

    try {
      // Пиксельный размер исходного видео (video_player знает его уже после
      // initialize() — с учётом поворота, если он есть в метаданных файла).
      final videoSize = _videoController.value.size;
      final sourceWidth = videoSize.width.round();
      final sourceHeight = videoSize.height.round();
      final rect = _region.toPixelRect(sourceWidth, sourceHeight);

      final start = _trim.start;
      final duration = (_trim.end - _trim.start).clamp(0.1, _maxGifSeconds);

      final tempDir = await getTemporaryDirectory();
      final outputPath =
          '${tempDir.path}/avatar_gif_${DateTime.now().millisecondsSinceEpoch}.gif';

      // Ровно квадратный кроп по кадру (crop) + компактный размер под аватарку
      // (scale) + 12 fps + палитра (palettegen/paletteuse) для чистых цветов
      // без "грязи" от стандартного дизеринга — стандартный ffmpeg-рецепт
      // для качественных гифок.
      const targetSize = 320;
      final filter = 'crop=${rect.side}:${rect.side}:${rect.left}:${rect.top},'
          'scale=$targetSize:$targetSize:flags=lanczos,'
          'fps=12,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse';

      final command = '-ss $start -t $duration -i "${widget.videoFile.path}" '
          '-vf "$filter" -y "$outputPath"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        final bytes = await File(outputPath).readAsBytes();
        if (!mounted) return;
        Navigator.of(context).pop<Uint8List>(bytes);
      } else {
        final logs = await session.getOutput();
        setState(() => _error = 'Не получилось собрать гифку из видео.\n$logs');
      }
    } catch (e) {
      setState(() => _error = 'Ошибка конвертации: $e');
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
                      if (kIsWeb)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Конвертация видео в гифку работает только в мобильном/десктопном '
                            'приложении — веб-версия сейчас это не поддерживает.',
                            style: const TextStyle(color: AppColors.danger, fontSize: 13),
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
                      // Квадратный кроп поверх видео — тот же виджет, что и для
                      // фото/гифки (widgets/avatar_cropper.dart).
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
                          onPressed: _exporting || kIsWeb ? null : _exportGif,
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