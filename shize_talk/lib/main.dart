import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme/app_theme.dart';
import 'screens/welcome_screen.dart';
import 'screens/chats_list_screen.dart';
import 'screens/username_setup_screen.dart';
import 'services/device_registry.dart';
import 'services/push_notifications.dart';

// Глобальный ключ навигатора — нужен, чтобы открыть чат по тапу на push
// уведомление, когда неизвестно, какой BuildContext сейчас активен.
final navigatorKey = GlobalKey<NavigatorState>();

// ЗАМЕНИТЬ на свои значения из Supabase → Project Settings → API
const supabaseUrl = 'https://zethqqyaddlztgdojiwe.supabase.co';
const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpldGhxcXlhZGRsenRnZG9qaXdlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM4ODU4MzcsImV4cCI6MjA5OTQ2MTgzN30.V0wIfbpfUmzvT9p2z-0-iEqY3pU13r83dou5kRGTtH4';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Shize Talk',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.theme,
      routes: {
        '/': (_) => const RootGate(),
      },
      initialRoute: '/',
    );
  }
}

// Проверяет: есть ли активная сессия. Если да — но юзернейм ещё не задан,
// сперва просим его придумать; если задан — сразу в список чатов.
// Если сессии нет — экран выбора "Войти" / "У меня есть приглашение".
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  late final Future<Widget> _destination = _resolveDestination();

  Future<Widget> _resolveDestination() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) return const WelcomeScreen();

    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return const WelcomeScreen();

    // Регистрируем/обновляем это устройство в списке (экран "Устройства" в
    // настройках) — не блокируем UI, если запрос не удастся, тихо игнорируем.
    unawaited(DeviceRegistry.touch());
    unawaited(PushNotifications.initialize());

    try {
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('username')
          .eq('id', userId)
          .maybeSingle();

      if (profile != null && profile['username'] != null) {
        return const ChatsListScreen();
      }
      return const UsernameSetupScreen();
    } catch (_) {
      // Сессия есть, но профиль не подтянулся (например, нет сети) —
      // всё равно ведём в список чатов, экран сам покажет ошибку загрузки.
      return const ChatsListScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _destination,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: AppColors.cyan)),
          );
        }
        return snapshot.data ?? const WelcomeScreen();
      },
    );
  }
}
