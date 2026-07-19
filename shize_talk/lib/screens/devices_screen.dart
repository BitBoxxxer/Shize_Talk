import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../services/device_registry.dart';

/// Список устройств, заходивших в аккаунт. Данные из public.user_devices,
/// обновляются через DeviceRegistry.touch() при каждом запуске приложения.
///
/// Ограничение: anon-key клиент не может принудительно завершить сессию
/// Supabase Auth на другом устройстве — кнопка "Завершить" только убирает
/// запись из списка на сервере (устройство перестанет быть видно), но само
/// устройство разлогинится лишь когда истечёт токен обновления. Полноценный
/// remote-logout потребует отдельной Edge Function с service-role ключом.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  String? _currentDeviceId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _currentDeviceId = await DeviceRegistry.getDeviceId();
      final data = await Supabase.instance.client.rpc('list_my_devices');
      if (!mounted) return;
      setState(() => _devices = List<Map<String, dynamic>>.from(data as List));
    } catch (e) {
      setState(() => _error = 'Не удалось загрузить устройства: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _revoke(String deviceId) async {
    try {
      await Supabase.instance.client.rpc('revoke_device', params: {'p_device_id': deviceId});
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  String _formatDate(String iso) {
    final dt = DateTime.parse(iso).toLocal();
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final time = '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (isToday) return 'сегодня в $time';
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} в $time';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Устройства')),
      body: RetroBackground(
        child: RefreshIndicator(
          color: AppColors.cyan,
          onRefresh: _load,
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: AppColors.cyan))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: AppColors.danger)),
                      const SizedBox(height: 12),
                    ],
                    if (_devices.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 60),
                        child: Center(
                          child: Text('Список устройств пуст', style: TextStyle(color: AppColors.textSecondary)),
                        ),
                      ),
                    for (final d in _devices) ...[
                      _DeviceTile(
                        isCurrent: d['device_id'] == _currentDeviceId,
                        name: (d['device_name'] as String?) ?? 'Неизвестное устройство',
                        platform: (d['platform'] as String?) ?? '',
                        appVersion: (d['app_version'] as String?) ?? '',
                        lastActive: _formatDate(d['last_active_at'] as String),
                        onRevoke: d['device_id'] == _currentDeviceId
                            ? null
                            : () => _revoke(d['device_id'] as String),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final bool isCurrent;
  final String name;
  final String platform;
  final String appVersion;
  final String lastActive;
  final VoidCallback? onRevoke;

  const _DeviceTile({
    required this.isCurrent,
    required this.name,
    required this.platform,
    required this.appVersion,
    required this.lastActive,
    required this.onRevoke,
  });

  IconData _platformIcon() {
    switch (platform) {
      case 'Android':
        return Icons.android;
      case 'iOS':
      case 'macOS':
        return Icons.phone_iphone;
      case 'Windows':
      case 'Linux':
        return Icons.desktop_windows_outlined;
      case 'Web':
        return Icons.public;
      default:
        return Icons.devices_other;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: Icon(_platformIcon(), color: AppColors.cyan),
        title: Row(
          children: [
            Flexible(child: Text(name, overflow: TextOverflow.ellipsis)),
            if (isCurrent) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.success.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('это устройство',
                    style: TextStyle(fontSize: 10, color: AppColors.success)),
              ),
            ],
          ],
        ),
        subtitle: Text(
          'Версия $appVersion · был(а) в сети $lastActive',
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
        ),
        trailing: onRevoke == null
            ? null
            : IconButton(
                icon: const Icon(Icons.close, color: AppColors.danger),
                tooltip: 'Завершить сессию',
                onPressed: onRevoke,
              ),
      ),
    );
  }
}
