import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../main.dart' show navigatorKey;
import '../screens/chat_screen.dart';

/// Push-уведомления о новых сообщениях (ЛС и группы), когда приложение
/// свёрнуто/закрыто. Сама отправка — на стороне Supabase Edge Function
/// (см. supabase/functions/notify-new-message), эта часть только:
/// 1) регистрирует FCM-токен устройства в public.push_tokens,
/// 2) при тапе по уведомлению открывает нужный чат.
///
/// ВАЖНО: помимо кода нужна ручная настройка Firebase (см. комментарий в
/// начале файла notify-new-message/index.ts) — без неё FCM.instance.getToken()
/// просто не будет работать (или упадёт с ошибкой, которую мы тут глотаем,
/// чтобы это не роняло остальное приложение).
class PushNotifications {
  static bool _initialized = false;

  @pragma('vm:entry-point')
  static Future<void> _onBackgroundMessage(RemoteMessage message) async {
    // На Android система сама покажет уведомление (мы отправляем блок
    // "notification" в FCM-пейлоаде) — здесь дополнительно ничего делать
    // не нужно, кроме как убедиться, что Firebase инициализирован в этом
    // отдельном изоляте.
    await Firebase.initializeApp();
  }

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;

    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      await _registerToken();
      messaging.onTokenRefresh.listen((_) => _registerToken());

      // Тап по уведомлению, когда приложение было в фоне.
      FirebaseMessaging.onMessageOpenedApp.listen(_openChatFromMessage);

      // Приложение было полностью закрыто и открылось именно по тапу на пуш.
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) _openChatFromMessage(initialMessage);
    } catch (e) {
      // Если Firebase не настроен (нет google-services.json и т.п.) — не
      // роняем остальное приложение, просто не будет пушей.
      debugPrint('Push notifications недоступны: $e');
    }
  }

  static Future<void> _registerToken() async {
    if (Supabase.instance.client.auth.currentUser == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await Supabase.instance.client.rpc('upsert_push_token', params: {
        'p_token': token,
        'p_platform': Platform.isIOS ? 'ios' : 'android',
      });
    } catch (e) {
      debugPrint('Не удалось зарегистрировать push-токен: $e');
    }
  }

  /// Вызывать при выходе из аккаунта — чтобы это устройство больше не
  /// получало пуши для уже вышедшего пользователя.
  static Future<void> unregisterCurrentDevice() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await Supabase.instance.client.rpc('delete_push_token', params: {'p_token': token});
    } catch (_) {
      // не критично — токен просто останется, пока не протухнет сам по себе
    }
  }

  static void _openChatFromMessage(RemoteMessage message) {
    final chatId = message.data['chat_id'] as String?;
    if (chatId == null) return;
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(chatId: chatId, chatTitle: message.notification?.title ?? 'Чат'),
      ),
    );
  }
}
