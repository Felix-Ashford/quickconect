import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/session.dart';
import 'message_bubble.dart';

/// Keep mention boundaries consistent with the server, avoiding email addresses
/// and partial names such as @helper2 matching @helper.
bool mentionsName(String text, String name) {
  name = name.trim();
  if (name.isEmpty) return false;
  return RegExp(
    r'(^|[\s(\[\{（【，。！？,:;!?])@' +
        RegExp.escape(name) +
        r'(?=$|[\s)\]\},.，。！？:;!?：；、])',
    caseSensitive: false,
  ).hasMatch(text);
}

/// A mention is replaced at the caret, preserving the rest of the draft.
class MentionQuery {
  final int start, end;
  final String query;
  const MentionQuery(this.start, this.end, this.query);

  static MentionQuery? fromValue(TextEditingValue value) {
    if (!value.selection.isCollapsed || value.selection.extentOffset < 0) {
      return null;
    }
    final end = value.selection.extentOffset;
    if (end > value.text.length) return null;
    final prefix = value.text.substring(0, end);
    final match = RegExp(r'(^|\s)@([^\s@]*)$').firstMatch(prefix);
    if (match == null) return null;
    return MentionQuery(end - match.group(2)!.length - 1, end, match.group(2)!);
  }

  TextEditingValue insert(TextEditingValue value, String name) {
    final replacement = '@$name ';
    return TextEditingValue(
      text: value.text.replaceRange(start, end, replacement),
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
  }
}

class MentionSuggestions extends StatelessWidget {
  final Session session;
  final TextEditingController controller;
  final List<AutomationIdentity> identities;
  final VoidCallback onSelected;
  const MentionSuggestions({
    super.key,
    required this.session,
    required this.controller,
    required this.identities,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final mention = MentionQuery.fromValue(controller.value);
    if (mention == null) return const SizedBox.shrink();
    final query = mention.query.toLowerCase();
    final options = identities
        .where(
          (item) =>
              item.mentionEnabled &&
              (item.mode == 'api' || item.mode == 'agent') &&
              (item.name.toLowerCase().contains(query) ||
                  item.displayName.toLowerCase().contains(query)),
        )
        .toList();
    if (options.isEmpty) return const SizedBox.shrink();
    return Material(
      elevation: 3,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: options.length,
          itemBuilder: (context, index) {
            final item = options[index];
            return ListTile(
              key: ValueKey('mention-${item.id}'),
              dense: true,
              leading: MessageAvatar(
                session: session,
                mediaId: item.avatarMediaId,
                name: item.displayName,
              ),
              title: Text(
                item.displayName.isEmpty ? item.name : item.displayName,
              ),
              subtitle: Text('@${item.name}'),
              onTap: () {
                controller.value = mention.insert(controller.value, item.name);
                onSelected();
              },
            );
          },
        ),
      ),
    );
  }
}
