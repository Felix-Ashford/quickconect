import 'package:flutter/material.dart';

import '../core/models.dart';

/// Owns selection and creation until the sheet has returned a result.
class AutomationThreadDirectory extends StatefulWidget {
  const AutomationThreadDirectory({
    super.key,
    required this.name,
    required this.threads,
    required this.createThread,
  });

  final String name;
  final List<AutomationThread> threads;
  final Future<AutomationThread> Function() createThread;

  @override
  State<AutomationThreadDirectory> createState() =>
      _AutomationThreadDirectoryState();
}

class _AutomationThreadDirectoryState extends State<AutomationThreadDirectory> {
  bool _creating = false;
  bool _selected = false;

  void _select(AutomationThread thread) {
    if (_selected || !mounted) return;
    _selected = true;
    Navigator.pop(context, thread);
  }

  Future<void> _create() async {
    if (_creating || _selected) return;
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
                onPressed: _creating || _selected ? null : _create,
                icon: _creating
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
              ),
            ),
            for (final thread in widget.threads)
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(
                  thread.title.isEmpty ? '对话 ${thread.id}' : thread.title,
                ),
                subtitle: thread.selectedModel.isEmpty
                    ? null
                    : Text(thread.selectedModel),
                onTap: _creating || _selected ? null : () => _select(thread),
              ),
          ],
        ),
      ),
    ),
  );
}
