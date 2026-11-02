import 'package:flutter/material.dart';

import '../core/models.dart';

class AutomationDirectorySelection {
  const AutomationDirectorySelection(this.conversationId, {this.thread});
  final int conversationId;
  final AutomationThread? thread;
}

/// Owns selection and creation until the sheet has returned a result.
class AutomationThreadDirectory extends StatefulWidget {
  const AutomationThreadDirectory({
    super.key,
    required this.name,
    required this.threads,
    required this.createThread,
    required this.currentConversationId,
    required this.deleteThread,
  });

  final String name;
  final List<AutomationThread> threads;
  final Future<AutomationThread> Function() createThread;
  final int currentConversationId;
  final Future<AutomationThread?> Function(AutomationThread) deleteThread;

  @override
  State<AutomationThreadDirectory> createState() =>
      _AutomationThreadDirectoryState();
}

class _AutomationThreadDirectoryState extends State<AutomationThreadDirectory> {
  bool _creating = false;
  bool _deleting = false;
  bool _confirmingDelete = false;
  bool _selected = false;
  late final List<AutomationThread> _threads = List.of(widget.threads);

  void _select(AutomationThread thread) {
    _selectConversation(thread.conversationId, thread: thread);
  }

  void _selectConversation(int conversationId, {AutomationThread? thread}) {
    if (_selected || !mounted) return;
    _selected = true;
    Navigator.pop(
      context,
      AutomationDirectorySelection(conversationId, thread: thread),
    );
  }

  Future<void> _delete(AutomationThread thread) async {
    if (_creating || _deleting || _confirmingDelete || _selected) return;
    _confirmingDelete = true;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除此对话？'),
        content: Text(
          '“${thread.title.isEmpty ? '对话 ${thread.id}' : thread.title}”及其消息将被永久删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) {
      _confirmingDelete = false;
      return;
    }
    _confirmingDelete = false;
    setState(() => _deleting = true);
    try {
      final replacement = await widget.deleteThread(thread);
      if (!mounted) return;
      setState(
        () => _threads.removeWhere(
          (item) => item.conversationId == thread.conversationId,
        ),
      );
      if (thread.conversationId == widget.currentConversationId) {
        _selectConversation(
          replacement?.conversationId ?? -1,
          thread: replacement,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _create() async {
    if (_creating || _deleting || _confirmingDelete || _selected) return;
    setState(() => _creating = true);
    try {
      final thread = await widget.createThread();
      _select(thread);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('新建失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_creating,
    child: SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .75,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(widget.name),
              trailing: IconButton(
                tooltip: '新建对话',
                onPressed: _creating || _deleting || _selected ? null : _create,
                icon: _creating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
              ),
            ),
            for (final thread in _threads)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(
                  thread.title.isEmpty ? '对话 ${thread.id}' : thread.title,
                ),
                selected: thread.conversationId == widget.currentConversationId,
                subtitle: thread.modelOrder.isEmpty
                    ? null
                    : Text(
                        thread.modelOrder.join(' → '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: IconButton(
                  tooltip: '删除对话',
                  onPressed:
                      _creating || _deleting || _confirmingDelete || _selected
                      ? null
                      : () => _delete(thread),
                  icon: _deleting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                ),
                onTap: _creating || _deleting || _confirmingDelete || _selected
                    ? null
                    : () => _select(thread),
              ),
          ],
        ),
      ),
    ),
  );
}
