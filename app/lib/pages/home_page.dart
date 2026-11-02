import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/session.dart';
import '../core/action_gate.dart';
import '../core/ws_client.dart';
import 'chat_page.dart';
import 'settings_page.dart';
import '../widgets/contact_picker.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final _actions = ActionGate(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  int? _activeConvId;
  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (session.booting) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final convs = session.sortedConvs();
    // Keep the current page alive while its deletion dialog finishes. The
    // chat owns choosing a replacement after the remote deletion completes.
    final selected =
        _activeConvId ??
        session.currentConvId ??
        (convs.isNotEmpty ? convs.first.id : null);
    if (selected != null) {
      return ChatPage(
        key: ValueKey(selected),
        convId: selected,
        showConversationPicker: true,
        onConversationChanged: (id) => setState(() {
          session.currentConvId = null;
          _activeConvId = id > 0 ? id : null;
        }),
      );
    }
    return _empty(context, session);
  }

  Widget _empty(BuildContext context, Session session) => Scaffold(
    appBar: AppBar(
      title: const Text('QuickConect'),
      leading: _WsStateDot(state: session.wsState),
      actions: [
        IconButton(
          tooltip: '设置',
          icon: const Icon(Icons.settings_outlined),
          onPressed: _actions.busy
              ? null
              : () => _actions.run(
                  () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const SettingsPage()),
                  ),
                ),
        ),
      ],
    ),
    body: Center(
      child: FilledButton.icon(
        onPressed: _actions.busy
            ? null
            : () => _actions.run(() => _newChat(context)),
        icon: const Icon(Icons.chat),
        label: const Text('选择联系人开始聊天'),
      ),
    ),
  );
  Future<void> _newChat(BuildContext context) async {
    final session = context.read<Session>();
    final convId = await pickConversation(context, session);
    if (convId == null || !context.mounted) {
      return;
    }
    setState(() => _activeConvId = convId);
  }
}

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
      padding: const EdgeInsets.only(left: 12),
      child: Tooltip(
        message: '连接状态',
        child: Icon(Icons.circle, size: 12, color: color),
      ),
    );
  }
}
