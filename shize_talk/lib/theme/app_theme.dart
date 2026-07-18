import 'package:flutter/material.dart';

// Палитра подобрана под лого Shize Talk: чёрный фон, неоновый
// фиолетовый → синий → бирюзовый градиент, белый текст со свечением.
class AppColors {
  static const background = Color(0xFF07070C);
  static const surface = Color(0xFF121018);
  static const surfaceAlt = Color(0xFF1A1626);
  static const purple = Color(0xFF7C3AED);
  static const blue = Color(0xFF3B5BFD);
  static const cyan = Color(0xFF22D3EE);
  static const magenta = Color(0xFFE535AB);
  static const textPrimary = Color(0xFFF5F3FF);
  static const textSecondary = Color(0xFFA9A3C2);
  static const danger = Color(0xFFFF5D7A);
  static const success = Color(0xFF2EE6A6);

  static const primaryGradient = LinearGradient(
    colors: [purple, blue, cyan],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  static const backgroundGradient = LinearGradient(
    colors: [Color(0xFF0B0A14), Color(0xFF07070C)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

class AppTheme {
  static ThemeData get theme {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: base.colorScheme.copyWith(
        primary: AppColors.purple,
        secondary: AppColors.cyan,
        surface: AppColors.surface,
        error: AppColors.danger,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
        iconTheme: IconThemeData(color: AppColors.textPrimary),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: AppColors.textPrimary,
        displayColor: AppColors.textPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A2540)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFF2A2540)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.cyan, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.danger),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.cyan),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.purple,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          side: const BorderSide(color: AppColors.cyan, width: 1.4),
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      iconTheme: const IconThemeData(color: AppColors.textPrimary),
      dividerColor: const Color(0xFF241F36),
    );
  }
}

// Фоновая обёртка с градиентом + тонкими неоновыми "скан-линиями" — общий
// для всех экранов, чтобы держать единый ретро-стиль без лишних зависимостей.
class RetroBackground extends StatelessWidget {
  final Widget child;
  const RetroBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(gradient: AppColors.backgroundGradient),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _GlowPainter()),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _GlowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final glow1 = Paint()
      ..shader = RadialGradient(
        colors: [AppColors.purple.withOpacity(0.22), Colors.transparent],
      ).createShader(Rect.fromCircle(center: Offset(size.width * 0.15, size.height * 0.05), radius: 260));
    canvas.drawRect(Offset.zero & size, glow1);

    final glow2 = Paint()
      ..shader = RadialGradient(
        colors: [AppColors.cyan.withOpacity(0.16), Colors.transparent],
      ).createShader(Rect.fromCircle(center: Offset(size.width * 0.9, size.height * 0.85), radius: 260));
    canvas.drawRect(Offset.zero & size, glow2);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// Заголовок с градиентной заливкой текста (используется на welcome/логотипе)
class GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const GradientText(this.text, {super.key, required this.style});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (bounds) => AppColors.primaryGradient.createShader(bounds),
      child: Text(text, style: style.copyWith(color: Colors.white)),
    );
  }
}
