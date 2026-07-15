import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/invite_screen.dart';
import 'screens/chat_screen.dart';

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
      title: 'Messenger',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      routes: {
        '/': (_) => const RootGate(),
      },
      initialRoute: '/',
    );
  }
}

// Проверяет: есть ли активная сессия. Если да — сразу в чат,
// если нет — экран ввода инвайт-токена.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Supabase.instance.client.auth.currentSession;
    if (session != null) {
      return const ChatScreen();
    }
    return const InviteScreen();
  }
}
