import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_cropper.dart';
import '../widgets/avatar_media_crop.dart';

/// Кроп-экран для картинки или гифки: показывает медиа под AvatarCropper
/// (pinch/drag внутри квадратной рамки), по подтверждению вырезает область
/// и возвращает готовые байты (jpg для картинки, gif для гифки).
class ImageCropScreen extends StatefulWidget {
  final Uint8List sourceBytes;
  final bool isGif;

  const ImageCropScreen({super.key, required this.sourceBytes, required this.isGif});

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  CropRegion _region = const CropRegion(x: 0, y: 0, size: 1);
  bool _processing = false;
  bool _resolvingAspectRatio = true;
  String? _error;
  double _aspectRatio = 1;

  @override
  void initState() {
    super.initState();
    _resolveAspectRatio();
  }

  Future<void> _resolveAspectRatio() async {
    // instantiateImageCodec понимает и статичный первый кадр гифки — этого
    // достаточно, чтобы узнать натуральные пропорции для FittedBox(cover).
    try {
      final codec = await ui.instantiateImageCodec(widget.sourceBytes);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      setState(() {
        _aspectRatio = frame.image.width / frame.image.height;
        _resolvingAspectRatio = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось прочитать изображение: $e';
        _resolvingAspectRatio = false;
      });
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final Uint8List result = widget.isGif
          // Покадровый кроп гифки — тяжёлая операция, уводим в отдельный
          // isolate через compute(), чтобы не подвесить UI-поток.
          ? await compute(_cropGifIsolate, _GifCropArgs(widget.sourceBytes, _region))
          : await compute(_cropImageIsolate, _ImageCropArgs(widget.sourceBytes, _region));

      if (!mounted) return;
      Navigator.of(context).pop<Uint8List>(result);
    } catch (e) {
      setState(() => _error = 'Не удалось обрезать: $e');
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isGif ? 'Область гифки' : 'Область фото')),
      body: RetroBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                const Text(
                  'Сведите пальцы, чтобы приблизить, и передвиньте картинку — '
                  'в рамку попадёт то, что станет аватаркой.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Text(_error!, style: const TextStyle(color: AppColors.danger)),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: _resolvingAspectRatio
                      ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
                      : AvatarCropper(
                          sourceAspectRatio: _aspectRatio,
                          onRegionChanged: (r) => _region = r,
                          child: Image.memory(widget.sourceBytes, fit: BoxFit.cover, gaplessPlayback: true),
                        ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _processing || _resolvingAspectRatio ? null : _confirm,
                    child: _processing
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Готово'),
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

// --- Изоляты для тяжёлых CPU-операций кропа ---------------------------------

class _ImageCropArgs {
  final Uint8List bytes;
  final CropRegion region;
  const _ImageCropArgs(this.bytes, this.region);
}

class _GifCropArgs {
  final Uint8List bytes;
  final CropRegion region;
  const _GifCropArgs(this.bytes, this.region);
}

Uint8List _cropImageIsolate(_ImageCropArgs args) {
  return cropStaticImage(bytes: args.bytes, region: args.region);
}

Uint8List _cropGifIsolate(_GifCropArgs args) {
  return cropAnimatedGif(bytes: args.bytes, region: args.region);
}
