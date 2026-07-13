import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_screen.dart';

class OtpScreen extends StatefulWidget {
  final String inviteToken;
  const OtpScreen({super.key, required this.inviteToken});

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController();
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
      // Email OTP — работает из коробки бесплатно.
      // Для телефона (SMS) нужно подключить провайдера (Twilio и т.п.) в
      // Supabase → Authentication → Providers → Phone — тогда здесь будет
      // supabase.auth.signInWithOtp(phone: ...)
      await Supabase.instance.client.auth.signInWithOtp(email: email);
      setState(() => _codeSent = true);
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

      // Теперь auth.uid() существует — можно погасить инвайт и создать профиль
      final success = await Supabase.instance.client.rpc(
        'redeem_invite',
        params: {
          'p_token': widget.inviteToken,
          'p_display_name': _nameController.text.trim().isEmpty
              ? email
              : _nameController.text.trim(),
        },
      ) as bool;

      if (!mounted) return;

      if (!success) {
        setState(() {
          _error = 'Токен уже был использован. Обратитесь за новым приглашением.';
        });
        // Выходим из только что созданной auth-сессии, раз инвайт не удалось погасить
        await Supabase.instance.client.auth.signOut();
        return;
      }

      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ChatScreen()),
        (route) => false,
      );
    } catch (e) {
      setState(() => _error = 'Неверный код или ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Подтверждение')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_codeSent) ...[
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Ваше имя (для чата)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _sendCode,
                child: _loading
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : const Text('Отправить код'),
              ),
            ] else ...[
              Text('Код отправлен на ${_emailController.text}'),
              const SizedBox(height: 16),
              TextField(
                controller: _codeController,
                decoration: const InputDecoration(
                  labelText: 'Код из письма',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _verifyCode,
                child: _loading
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : const Text('Подтвердить'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
