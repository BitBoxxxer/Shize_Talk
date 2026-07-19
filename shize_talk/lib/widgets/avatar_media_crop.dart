import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'avatar_cropper.dart';

/// Применяет [region] к статичному изображению (jpg/png/webp/...) и
/// ресайзит результат до [targetSize] x [targetSize] (квадрат для аватарки).
Uint8List cropStaticImage({
  required Uint8List bytes,
  required CropRegion region,
  int targetSize = 512,
}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Не удалось распознать изображение');
  }
  final rect = region.toPixelRect(decoded.width, decoded.height);
  final cropped = img.copyCrop(
    decoded,
    x: rect.left,
    y: rect.top,
    width: rect.side,
    height: rect.side,
  );
  final resized = img.copyResize(cropped, width: targetSize, height: targetSize);
  return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
}

/// Покадрово кропает анимированную гифку по одной и той же [region] на всех
/// кадрах и пересобирает GIF. Кадры, кроме первого, ресайзятся аккуратно —
/// это относительно тяжёлая CPU-операция, поэтому стоит вызывать её через
/// compute()/isolate на больших гифках (см. вызов в avatar_screen.dart).
Uint8List cropAnimatedGif({
  required Uint8List bytes,
  required CropRegion region,
  int targetSize = 320, // гифки держим компактнее статичных аватарок
}) {
  // В image ^4.x нет отдельной decodeGifAnimation — decodeGif без указания
  // frame сам возвращает Image со всеми кадрами анимации в .frames
  // (первый элемент .frames — это же изображение целиком, см. доку Image.frames).
  final anim = img.decodeGif(bytes);
  if (anim == null || anim.frames.isEmpty) {
    throw const FormatException('Не удалось распознать гифку');
  }

  final firstFrame = anim.frames.first;
  final rect = region.toPixelRect(firstFrame.width, firstFrame.height);

  final encoder = img.GifEncoder();
  for (final frame in anim.frames) {
    final cropped = img.copyCrop(
      frame,
      x: rect.left,
      y: rect.top,
      width: rect.side,
      height: rect.side,
    );
    final resized = img.copyResize(cropped, width: targetSize, height: targetSize);
    // frame.frameDuration у декодированного кадра хранится в миллисекундах,
    // а GifEncoder.addFrame ожидает duration в 1/100 сек — конвертируем.
    final durationCentiseconds = (frame.frameDuration / 10).round().clamp(1, 1000);
    encoder.addFrame(resized, duration: durationCentiseconds);
  }

  final output = encoder.finish();
  if (output == null) {
    throw const FormatException('Не удалось собрать гифку из кадров');
  }
  return Uint8List.fromList(output);
}
