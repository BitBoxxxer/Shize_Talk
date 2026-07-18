import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chats_list_screen.dart';

// По типу Телеграма: уникальный @юзернейм, по которому потом другие
// пользователи смогут находить тебя и добавлять в друзья.
class UsernameSetupScreen extends StatefulWidget {
  const UsernameSetupScreen({super.key});

  @override
  State<UsernameSetupScreen> createState() => _UsernameSetupScreenState();
}

class _UsernameSetupScreenState extends State<UsernameSetupScreen> {
  final _controller = TextEditingController();
  bool _loading = false;
  String? _error;

  final _validPattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');

  Future<void> _save() async {
    final username = _controller.text.trim();

    if (!_validPattern.hasMatch(username)) {
      setState(() => _error =
          '3-20 символов: латинские буквы, цифры и подчёркивание');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await Supabase.instance.client.rpc('set_username', params: {'p_username': username});
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ChatsListScreen()),
        (route) => false,
      );
    } on PostgrestException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Ошибка: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Придумайте юзернейм')),
      body: RetroBackground(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.alternate_email, size: 56, color: AppColors.cyan),
              const SizedBox(height: 16),
              const Text(
                'По этому юзернейму друзья смогут найти вас в Shize Talk',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  prefixText: '@',
                  labelText: 'Юзернейм',
                ),
                keyboardType: TextInputType.text,
                autocorrect: false,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _save,
                child: _loading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Сохранить и продолжить'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
