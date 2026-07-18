import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chats_list_screen.dart';
import 'username_setup_screen.dart';
import 'invite_screen.dart';

// Экран входа для пользователей, у которых УЖЕ есть аккаунт в Supabase
// (то есть они когда-то зарегались по инвайту). Новый аккаунт здесь создать
// нельзя — для этого нужен код приглашения (см. InviteScreen).
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _loading = false;
  bool _codeSent = false;
  String? _error;

  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // shouldCreateUser: false — вход отделён от регистрации по инвайту:
      // если аккаунта с таким email ещё нет, Supabase вернёт ошибку.
      await Supabase.instance.client.auth.signInWithOtp(
        email: email,
        shouldCreateUser: false,
      );
      if (!mounted) return;
      setState(() => _codeSent = true);
    } on AuthException catch (e) {
      setState(() => _error = _friendlyMessage(e.message));
    } catch (e) {
      setState(() => _error = 'Не удалось отправить код: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await Supabase.instance.client.auth.verifyOTP(
        email: email,
        token: code,
        type: OtpType.email,
      );

      if (!mounted) return;
      await _routeAfterLogin();
    } on AuthException catch (e) {
      setState(() => _error = _friendlyMessage(e.message));
    } catch (e) {
      setState(() => _error = 'Неверный код или ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // После входа проверяем, задан ли юзернейм — если нет, сперва просим его
  // придумать, иначе сразу в список чатов.
  Future<void> _routeAfterLogin() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    Widget next = const UsernameSetupScreen();

    if (userId != null) {
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('username')
          .eq('id', userId)
          .maybeSingle();
      if (profile != null && profile['username'] != null) {
        next = const ChatsListScreen();
      }
    }

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => next),
      (route) => false,
    );
  }

  String _friendlyMessage(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('signups not allowed') ||
        lower.contains('user not found') ||
        lower.contains('otp not found') ||
        lower.contains('not allowed')) {
      return 'Аккаунт с такой почтой не найден. Если у вас есть код '
          'приглашения — зарегистрируйтесь по нему.';
    }
    if (lower.contains('invalid') || lower.contains('expired')) {
      return 'Неверный или устаревший код. Запросите новый.';
    }
    return raw;
  }

  void _resetToEmailStep() {
    setState(() {
      _codeSent = false;
      _codeController.clear();
      _error = null;
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Вход')),
      body: RetroBackground(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.login, size: 56, color: AppColors.cyan),
              const SizedBox(height: 16),
              Text(
                _codeSent
                    ? 'Код отправлен на ${_emailController.text}'
                    : 'Войдите в свой аккаунт',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              if (!_codeSent) ...[
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(labelText: 'Email'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppColors.danger)),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loading ? null : _sendCode,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Отправить код для входа'),
                ),
              ] else ...[
                TextField(
                  controller: _codeController,
                  decoration: const InputDecoration(labelText: 'Код из письма'),
                  keyboardType: TextInputType.number,
                  autofocus: true,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppColors.danger)),
                ],
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _loading ? null : _verifyCode,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Войти'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _loading ? null : _resetToEmailStep,
                  child: const Text('Изменить email'),
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: _loading
                    ? null
                    : () {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const InviteScreen()),
                        );
                      },
                child: const Text('Нет аккаунта? У меня есть код приглашения'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
