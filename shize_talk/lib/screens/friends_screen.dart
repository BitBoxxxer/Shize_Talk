import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();

  List<Map<String, dynamic>> _searchResults = [];
  List<Map<String, dynamic>> _requests = [];
  List<Map<String, dynamic>> _friends = [];
  bool _searching = false;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadRequests();
    _loadFriends();
  }

  Future<void> _loadRequests() async {
    final data = await Supabase.instance.client.rpc('list_friend_requests');
    if (!mounted) return;
    setState(() => _requests = List<Map<String, dynamic>>.from(data as List));
  }

  Future<void> _loadFriends() async {
    final data = await Supabase.instance.client.rpc('list_friends');
    if (!mounted) return;
    setState(() => _friends = List<Map<String, dynamic>>.from(data as List));
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    try {
      final data = await Supabase.instance.client.rpc('search_users', params: {'p_query': q});
      if (!mounted) return;
      setState(() => _searchResults = List<Map<String, dynamic>>.from(data as List));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _sendRequest(String username) async {
    setState(() => _actionError = null);
    try {
      await Supabase.instance.client.rpc('send_friend_request', params: {'p_username': username});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Заявка отправлена @$username')),
      );
    } on PostgrestException catch (e) {
      setState(() => _actionError = e.message);
    }
  }

  Future<void> _respond(String requestId, bool accept) async {
    try {
      await Supabase.instance.client.rpc('respond_friend_request', params: {
        'p_request_id': requestId,
        'p_accept': accept,
      });
      await _loadRequests();
      await _loadFriends();
    } on PostgrestException catch (e) {
      setState(() => _actionError = e.message);
    }
  }

  Future<void> _openChatWith(String friendId, String? title) async {
    try {
      final chatId = await Supabase.instance.client
          .rpc('get_or_create_direct_chat', params: {'p_other_user_id': friendId}) as String;
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(chatId: chatId, chatTitle: title ?? 'Чат'),
        ),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Друзья'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.cyan,
          labelColor: AppColors.textPrimary,
          unselectedLabelColor: AppColors.textSecondary,
          tabs: [
            const Tab(text: 'Поиск'),
            Tab(text: 'Заявки${_requests.isNotEmpty ? ' (${_requests.length})' : ''}'),
            const Tab(text: 'Мои друзья'),
          ],
        ),
      ),
      body: RetroBackground(
        child: TabBarView(
          controller: _tabController,
          children: [
            _buildSearchTab(),
            _buildRequestsTab(),
            _buildFriendsTab(),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchTab() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search, color: AppColors.textSecondary),
              hintText: 'Юзернейм друга',
            ),
            onChanged: _search,
          ),
          if (_actionError != null) ...[
            const SizedBox(height: 8),
            Text(_actionError!, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 12),
          if (_searching) const LinearProgressIndicator(color: AppColors.cyan),
          Expanded(
            child: ListView.builder(
              itemCount: _searchResults.length,
              itemBuilder: (context, i) {
                final u = _searchResults[i];
                return _UserTile(
                  title: '@${u['username']}',
                  subtitle: u['display_name'] as String? ?? '',
                  trailing: TextButton(
                    onPressed: () => _sendRequest(u['username'] as String),
                    child: const Text('Добавить'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestsTab() {
    if (_requests.isEmpty) {
      return const Center(
        child: Text('Нет входящих заявок', style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _requests.length,
      itemBuilder: (context, i) {
        final r = _requests[i];
        return _UserTile(
          title: '@${r['requester_username']}',
          subtitle: r['requester_display_name'] as String? ?? '',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.check_circle, color: AppColors.success),
                onPressed: () => _respond(r['request_id'] as String, true),
              ),
              IconButton(
                icon: const Icon(Icons.cancel, color: AppColors.danger),
                onPressed: () => _respond(r['request_id'] as String, false),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFriendsTab() {
    if (_friends.isEmpty) {
      return const Center(
        child: Text('Пока нет друзей — найдите их по юзернейму',
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _friends.length,
      itemBuilder: (context, i) {
        final f = _friends[i];
        final title = (f['display_name'] as String?)?.isNotEmpty == true
            ? f['display_name'] as String
            : '@${f['username']}';
        return _UserTile(
          title: title,
          subtitle: '@${f['username']}',
          onTap: () => _openChatWith(f['friend_id'] as String, title),
          trailing: const Icon(Icons.chat_bubble_outline, color: AppColors.cyan),
        );
      },
    );
  }
}

class _UserTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _UserTile({required this.title, required this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: AppColors.purple.withOpacity(0.3),
          child: Text(
            title.isNotEmpty ? title[0].toUpperCase() : '?',
            style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle.isNotEmpty
            ? Text(subtitle, style: const TextStyle(color: AppColors.textSecondary))
            : null,
        trailing: trailing,
      ),
    );
  }
}
