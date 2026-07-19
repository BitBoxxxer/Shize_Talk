import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

/// Экран выбора языка. Выбор сохраняется и в профиль (public.profiles.language,
/// чтобы синхронизировался между устройствами), и локально в shared_preferences
/// (чтобы применить его мгновенно при следующем запуске, ещё до сетевого запроса).
///
/// ВАЖНО: этот экран меняет только сохранённое значение языка — полный
/// перевод текстов интерфейса (i18n со словарями ru/en/es и подключением
/// через MaterialApp.locale) сюда ещё не входит, это отдельная следующая
/// задача, чтобы не тащить полдесятка новых файлов-словарей в этот патч.
class LanguageScreen extends StatefulWidget {
  final String initialLanguage; // 'ru' | 'en' | 'es'
  const LanguageScreen({super.key, required this.initialLanguage});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();

  static const prefsKey = 'app_language';
}

class _LanguageScreenState extends State<LanguageScreen> {
  late String _language = widget.initialLanguage;
  bool _saving = false;
  String? _error;

  static const _options = [
    ('ru', 'Русский'),
    ('en', 'English'),
    ('es', 'Español'),
  ];

  Future<void> _select(String code) async {
    if (code == _language || _saving) return;
    final previous = _language;
    setState(() {
      _language = code;
      _saving = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.rpc('update_language', params: {'p_language': code});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(LanguageScreen.prefsKey, code);
    } catch (e) {
      setState(() {
        _language = previous;
        _error = 'Не удалось сохранить: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Язык')),
      body: RetroBackground(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final (code, label) in _options) ...[
              Card(
                color: AppColors.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: _language == code ? AppColors.cyan : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: ListTile(
                  onTap: () => _select(code),
                  title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: Icon(
                    _language == code ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: _language == code ? AppColors.cyan : AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 20),
            const Text(
              'Полный перевод интерфейса на выбранный язык подключим следующим '
              'шагом — сейчас выбор сохраняется в профиль и на устройстве.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
