import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Результат кропа: во что превратилось изображение внутри квадратной рамки,
/// в координатах "доля от исходной картинки" (0..1), не в пикселях экрана —
/// так результат не зависит от размера окна кроппера и легко применяется
/// что к статичной картинке, что к каждому кадру гифки, что к видео.
class CropRegion {
  /// Левый верхний угол вырезаемого квадрата — доля (0..1) от стороны
  /// квадрата MIN(ширина, высота), вписанного по центру исходного медиа
  /// (той самой картинки/кадра, которая покрывает весь квадратный viewport
  /// по правилам BoxFit.cover). Не доля от полной ширины/высоты исходника
  /// напрямую — см. [toPixelRect] для перевода в реальные пиксели.
  final double x;
  final double y;

  /// Сторона вырезаемого квадрата, тоже в долях от того же базового квадрата.
  final double size;

  const CropRegion({required this.x, required this.y, required this.size});

  /// Переводит регион в целочисленный квадрат пикселей исходного изображения
  /// размером [sourceWidth] x [sourceHeight]. Учитывает, что cover-вписывание
  /// уже само центрирует более длинную сторону исходника.
  ({int left, int top, int side}) toPixelRect(int sourceWidth, int sourceHeight) {
    final base = sourceWidth < sourceHeight ? sourceWidth : sourceHeight;
    final cropSidePx = (size * base).round().clamp(1, base);
    // Смещение базового cover-квадрата внутри полного исходника (центрирование
    // более длинной стороны — ровно как делает BoxFit.cover).
    final baseOffsetX = (sourceWidth - base) / 2;
    final baseOffsetY = (sourceHeight - base) / 2;
    final left = (baseOffsetX + x * base).round().clamp(0, sourceWidth - cropSidePx);
    final top = (baseOffsetY + y * base).round().clamp(0, sourceHeight - cropSidePx);
    return (left: left, top: top, side: cropSidePx);
  }

  @override
  String toString() => 'CropRegion(x: $x, y: $y, size: $size)';
}

/// Общий виджет кроп-рамки: показывает [child] (Image, VideoPlayer, любой
/// виджет с фиксированным aspect ratio [sourceAspectRatio]) под затемнением
/// с квадратным вырезом по центру. Пользователь двигает и зумит содержимое
/// пальцем — как в Телеграме/Дискорде при выборе аватарки.
class AvatarCropper extends StatefulWidget {
  final Widget child;
  final double sourceAspectRatio; // width / height исходного медиа
  final ValueChanged<CropRegion> onRegionChanged;
  final double minScale;
  final double maxScale;

  const AvatarCropper({
    super.key,
    required this.child,
    required this.sourceAspectRatio,
    required this.onRegionChanged,
    this.minScale = 1.0,
    this.maxScale = 4.0,
  });

  @override
  State<AvatarCropper> createState() => AvatarCropperState();
}

class AvatarCropperState extends State<AvatarCropper> {
  final TransformationController _controller = TransformationController();
  final GlobalKey _viewportKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_emitRegion);
    // Считаем регион после первого layout, когда размеры уже известны.
    WidgetsBinding.instance.addPostFrameCallback((_) => _emitRegion());
  }

  @override
  void dispose() {
    _controller.removeListener(_emitRegion);
    _controller.dispose();
    super.dispose();
  }

  void _emitRegion() {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final viewportSide = box.size.width; // квадрат — ширина == высота

    // При масштабе 1.0 (identity-матрица) child уже вписан через
    // FittedBox(cover) так, что весь viewport (сторона = viewportSide)
    // покрывает ровно MIN(натур. ширина, натур. высота) исходника.
    // InteractiveViewer поверх этого добавляет zoom (scale) и pan
    // (translation, в логических пикселях viewport'а).
    final matrix = _controller.value;
    final scale = matrix.getMaxScaleOnAxis();
    if (scale <= 0 || !scale.isFinite) return;
    final translation = matrix.getTranslation();

    // Вырезаемый квадрат — это то, что видно во viewport'е, посчитанное
    // "назад" в пространство исходного cover-изображения (масштаб 1.0):
    // сторона выреза = viewportSide / scale, в долях от viewportSide.
    final size = (1 / scale).clamp(0.0001, 1.0);

    // translation — это сдвиг content'а на экране в логических пикселях.
    // Видимый верхний левый угол в пространстве content'а (масштаб 1.0) —
    // это -translation / scale. Переводим в долю от стороны viewport'а.
    final x = ((-translation.x / scale) / viewportSide).clamp(0.0, 1.0 - size);
    final y = ((-translation.y / scale) / viewportSide).clamp(0.0, 1.0 - size);

    widget.onRegionChanged(CropRegion(
      x: x.isFinite ? x : 0,
      y: y.isFinite ? y : 0,
      size: size,
    ));
  }

  /// Сбросить зум/пан к исходному состоянию (центр, без приближения).
  void reset() {
    _controller.value = Matrix4.identity();
    _emitRegion();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth < constraints.maxHeight
            ? constraints.maxWidth
            : constraints.maxHeight;
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRect(
                  key: _viewportKey,
                  child: InteractiveViewer(
                    transformationController: _controller,
                    minScale: widget.minScale,
                    maxScale: widget.maxScale,
                    boundaryMargin: const EdgeInsets.all(0),
                    // cover: содержимое всегда полностью закрывает квадрат,
                    // не оставляя пустых полей — ровно как крутилка аватарки
                    // в мессенджерах.
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: widget.sourceAspectRatio >= 1 ? 1000 * widget.sourceAspectRatio : 1000,
                        height: widget.sourceAspectRatio >= 1 ? 1000 : 1000 / widget.sourceAspectRatio,
                        child: widget.child,
                      ),
                    ),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _MaskPainter(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Рисует затемнение вне видимой области + светлую рамку — сам вырез уже
/// равен всему квадратному viewport'у (child всегда cover'ит его целиком),
/// поэтому маска здесь чисто декоративная: обводка + уголки, как в Telegram.
class _MaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = AppColors.cyan.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(Offset.zero & size, borderPaint);

    // Сетка правил третей — помогает прицелиться, как в фото-редакторах.
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    for (final f in [1 / 3, 2 / 3]) {
      canvas.drawLine(Offset(size.width * f, 0), Offset(size.width * f, size.height), gridPaint);
      canvas.drawLine(Offset(0, size.height * f), Offset(size.width, size.height * f), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
