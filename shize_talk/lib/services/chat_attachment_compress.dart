import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Результат сжатия фото для чата — байты и итоговые размеры (нужны, чтобы
/// сразу нарисовать плейсхолдер правильных пропорций в чате, ещё до
/// декодирования на приёмной стороне).
class CompressedChatImage {
  final Uint8List bytes;
  final int width;
  final int height;
  const CompressedChatImage({required this.bytes, required this.width, required this.height});
}

/// Сжимает фото перед отправкой в чат: ресайз по большей стороне до
/// [maxDimension] + перекодирование в JPEG — как делают Telegram/WhatsApp
/// для "обычного" (не "как файл") режима отправки фото. В отличие от
/// аватарки — сохраняет исходные пропорции, не обрезает до квадрата.
///
/// Тяжёлая часть считается в отдельном изоляте через compute(), чтобы не
/// подвесить UI на большом фото с камеры (сейчас это может быть 12+ Мп).
Future<CompressedChatImage> compressChatImage(
  Uint8List sourceBytes, {
  int maxDimension = 1600,
  int quality = 82,
}) {
  return compute(_compressSync, _CompressArgs(sourceBytes, maxDimension, quality));
}

class _CompressArgs {
  final Uint8List bytes;
  final int maxDimension;
  final int quality;
  const _CompressArgs(this.bytes, this.maxDimension, this.quality);
}

CompressedChatImage _compressSync(_CompressArgs args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) {
    throw const FormatException('Не удалось распознать изображение');
  }

  // Если картинка уже меньше лимита — не увеличиваем, просто перекодируем
  // (нормализация формата: HEIC/PNG/WebP → JPEG, единообразно для чата).
  final needsResize = decoded.width > args.maxDimension || decoded.height > args.maxDimension;
  final resized = needsResize
      ? (decoded.width >= decoded.height
          ? img.copyResize(decoded, width: args.maxDimension)
          : img.copyResize(decoded, height: args.maxDimension))
      : decoded;

  final bytes = Uint8List.fromList(img.encodeJpg(resized, quality: args.quality));
  return CompressedChatImage(bytes: bytes, width: resized.width, height: resized.height);
}
