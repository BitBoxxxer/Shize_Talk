import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Генерирует компактное статичное превью (JPEG) для аватарки — то, что
/// показывается в списке чатов, друзьях, результатах поиска и т.д. вместо
/// полноразмерной картинки/гифки. Ровно то, как это делает YouTube с
/// превью видео: маленькая лёгкая копия для ленты, полный файл — только
/// когда открываешь сам объект (у нас — экран профиля).
///
/// Работает и для статичных картинок, и для гифок (берётся только первый
/// кадр — превью не обязано быть анимированным, это и есть основная
/// экономия). Тяжёлая часть (decode/resize/encode) считается в отдельном
/// изоляте через compute(), чтобы не подвесить UI на большом файле.
Future<Uint8List> generateAvatarThumbnail(
  Uint8List sourceBytes, {
  int size = 160,
  int quality = 72,
}) {
  return compute(_generateSync, _ThumbnailArgs(sourceBytes, size, quality));
}

class _ThumbnailArgs {
  final Uint8List bytes;
  final int size;
  final int quality;
  const _ThumbnailArgs(this.bytes, this.size, this.quality);
}

Uint8List _generateSync(_ThumbnailArgs args) {
  final decoded = img.decodeImage(args.bytes);
  if (decoded == null) {
    throw const FormatException('Не удалось прочитать изображение для превью');
  }

  // Если это гифка — decodeImage вернёт все кадры в .frames, для превью
  // берём только первый (статичная картинка) — секунда экономии на каждый
  // элемент списка чатов.
  final frame = decoded.frames.isNotEmpty ? decoded.frames.first : decoded;

  // Кроппер уже отдаёт квадратные картинки, но на всякий случай не
  // полагаемся на это и ресайзим по большей стороне с обрезкой до квадрата.
  final square = frame.width == frame.height
      ? frame
      : img.copyCrop(
          frame,
          x: frame.width > frame.height ? (frame.width - frame.height) ~/ 2 : 0,
          y: frame.height > frame.width ? (frame.height - frame.width) ~/ 2 : 0,
          width: frame.width < frame.height ? frame.width : frame.height,
          height: frame.width < frame.height ? frame.width : frame.height,
        );

  final resized = img.copyResize(square, width: args.size, height: args.size);
  return Uint8List.fromList(img.encodeJpg(resized, quality: args.quality));
}
