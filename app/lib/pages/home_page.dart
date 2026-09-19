import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../core/theme_scheme.dart';
import '../core/ws_client.dart';
import 'chat_page.dart';
import 'settings_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  Future<void> _newChat(BuildContext context) async {
    final session = context.read<Session>();
    final peers = session.users
        .where((u) => u.id != session.me?.id)
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));

    final picked = await showModalBottomSheet<User>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择联系人', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
            for (final u in peers)
              ListTile(
                leading: CircleAvatar(child: Text(u.displayName.isNotEmpty ? u.displayName[0] : '?')),
                title: Text(u.displayName),
                subtitle: Text('@${u.name}'),
                onTap: () => Navigator.pop(ctx, u),
              ),
            if (peers.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('还没有其他用户')),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    try {
      final convId = await session.openDM(picked.id);
      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ChatPage(convId: convId)),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final convs = session.sortedConvs();
    final meId = session.me?.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('QuickConect'),
        actions: [
          _WsStateDot(state: session.wsState),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _newChat(context),
        child: const Icon(Icons.chat_bubble_outline),
      ),
      body: session.booting
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () => session.bootstrap(),
              child: convs.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 160),
                        Center(child: Text('还没有会话\n点右下角按钮开始聊天', textAlign: TextAlign.center)),
                      ],
                    )
                  : ListView.builder(
                      itemCount: convs.length,
                      itemBuilder: (context, i) {
                        final conv = convs[i];
                        final peer = meId == null ? null : conv.peer(meId);
                        final last = conv.lastMessage;
                        final preview = last == null
                            ? '暂无消息'
                            : '${last.senderId == meId ? '你：' : ''}${messagePreview(last)}';
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(peer != null && peer.displayName.isNotEmpty
                                ? peer.displayName[0]
                                : '?'),
                          ),
                          title: Text(peer?.displayName ?? '会话 ${conv.id}'),
                          subtitle: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: conv.unread > 0
                              ? Badge(
                                  backgroundColor:
                                      qcColorsOf(context).unreadBadge,
                                  label: Text('${conv.unread > 99 ? '99+' : conv.unread}'),
                                )
                              : null,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ChatPage(convId: conv.id),
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

/// WebSocket 状态小圆点：绿=在线，橙=连接中，灰=断开。
class _WsStateDot extends StatelessWidget {
  final WsState state;
  const _WsStateDot({required this.state});

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      WsState.connected => Colors.green,
      WsState.connecting => Colors.orange,
      WsState.disconnected => Colors.grey,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: switch (state) {
          WsState.connected => '实时连接正常',
          WsState.connecting => '正在连接…',
          WsState.disconnected => '连接断开（会自动重连）',
        },
        child: Icon(Icons.circle, size: 12, color: color),
      ),
    );
  }
}
