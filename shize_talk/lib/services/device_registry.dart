import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_version.dart';

/// Управляет локальным device_id (генерируется один раз, хранится в
/// shared_preferences) и регистрирует "касания" устройства в
/// public.user_devices — это то, что показывается на экране "Устройства".
///
/// Настоящий remote force-logout другого устройства отсюда не сделать
/// (anon-key клиент не может завершить чужую auth-сессию) — экран только
/// показывает список и может пометить запись как отозванную локально.
class DeviceRegistry {
  static const _prefsKey = 'device_id';
  static String? _cachedId;

  /// Стабильный идентификатор именно этой установки приложения на этом
  /// устройстве — не привязан к пользователю, переживает logout/login.
  static Future<String> getDeviceId() async {
    if (_cachedId != null) return _cachedId!;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsKey);
    if (id == null) {
      // Простой уникальный id без доп. пакетов: время + случайное число.
      id = '${DateTime.now().microsecondsSinceEpoch}-'
          '${DateTime.now().hashCode.toRadixString(16)}';
      await prefs.setString(_prefsKey, id);
    }
    _cachedId = id;
    return id;
  }

  static String _platformName() {
    if (kIsWeb) return 'Web';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Неизвестно';
  }

  /// Отметить текущее устройство активным — вызывать при старте приложения
  /// (пока есть сессия) и периодически, пока приложение открыто.
  static Future<void> touch() async {
    if (Supabase.instance.client.auth.currentUser == null) return;
    try {
      final deviceId = await getDeviceId();
      await Supabase.instance.client.rpc('touch_device', params: {
        'p_device_id': deviceId,
        'p_device_name': _platformName(),
        'p_platform': _platformName(),
        'p_app_version': appVersionFull,
      });
    } catch (_) {
      // тихо игнорируем — список устройств не критичен для основной функциональности
    }
  }
}
