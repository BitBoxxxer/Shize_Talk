import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'otp_screen.dart';

class InviteScreen extends StatefulWidget {
  const InviteScreen({super.key});

  @override
  State<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends State<InviteScreen> {
  final _tokenController = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _checkToken() async {
    final token = _tokenController.text.trim();
    if (token.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final isValid = await Supabase.instance.client
          .rpc('check_invite_token', params: {'p_token': token}) as bool;

      if (!mounted) return;

      if (!isValid) {
        setState(() {
          _error = 'Токен недействителен, использован или истёк';
          _loading = false;
        });
        return;
      }

      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => OtpScreen(inviteToken: token)),
      );
    } catch (e) {
      setState(() {
        _error = 'Ошибка проверки: $e';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Вход по приглашению')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.mail_outline, size: 64, color: Colors.blue),
            const SizedBox(height: 16),
            const Text(
              'Введите код приглашения',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _tokenController,
              decoration: const InputDecoration(
                labelText: 'Код приглашения',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loading ? null : _checkToken,
              child: _loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Продолжить'),
            ),
          ],
        ),
      ),
    );
  }
}
