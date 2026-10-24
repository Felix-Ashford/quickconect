import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../core/action_gate.dart';
import 'message_bubble.dart';

/// Refresh the authoritative directory before offering a conversation target.
final _pickers = Expando<ActionGate>();

Future<int?> pickConversation(BuildContext context, Session session) {
  final gate = _pickers[session] ??= ActionGate();
  return gate.run<int?>(() async => await _pickConversation(context, session));
}

Future<int?> _pickConversation(BuildContext context, Session session) async {
  try {
    await session.refreshDirectory();
    if (!context.mounted) return null;
    final selected = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ContactPicker(session: session),
    );
    if (selected == null) return null;
    final identities = session.automationIdentities;
    final identity = identities
        .where((item) => item.mode == 'api' && item.userId == selected)
        .firstOrNull;
    if (identity != null) {
      return await session.openAutomation(identity);
    }
    return await session.openDM(selected);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法切换对话：$e')));
    }
    return null;
  }
}

class ContactPicker extends StatefulWidget {
  final Session session;
  const ContactPicker({super.key, required this.session});

  @override
  State<ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<ContactPicker> {
  bool _selected = false;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final peers = session.users.where((u) => u.id != session.me?.id).toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    Widget tile(User user, int value) => ListTile(
      key: ValueKey('contact-$value'),
      leading: MessageAvatar(
        session: session,
        mediaId: user.avatarMediaId,
        name: user.displayName,
      ),
      title: Text(user.displayName),
      subtitle: Text('@${user.name}'),
      onTap: () {
        if (_selected) return;
        _selected = true;
        Navigator.pop(context, value);
      },
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '选择联系人',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final user in peers) tile(user, user.id),
            for (final identity in session.automationIdentities.where(
              (item) =>
                  item.mode == 'api' &&
                  item.privateDirectory &&
                  item.userId != session.me?.id,
            ))
              tile(
                User(
                  id: identity.userId,
                  name: identity.name,
                  displayName: identity.displayName.isEmpty
                      ? identity.name
                      : identity.displayName,
                  avatarMediaId: identity.avatarMediaId,
                ),
                identity.userId,
              ),
            if (peers.isEmpty &&
                !session.automationIdentities.any(
                  (item) => item.mode == 'api' && item.privateDirectory,
                ))
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('还没有其他用户')),
              ),
          ],
        ),
      ),
    );
  }
}
