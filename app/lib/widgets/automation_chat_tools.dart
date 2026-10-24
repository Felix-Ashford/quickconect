import 'dart:async';

import 'package:flutter/material.dart';

import '../core/action_gate.dart';
import '../core/models.dart';
import '../core/session.dart';

/// Controls for the current private API conversation. The thread owns its
/// title, model and optional prompt override; other threads stay isolated.
class AutomationChatTools extends StatefulWidget {
  final Session session;
  final AutomationIdentity identity;
  final AutomationThread? thread;
  final FutureOr<void> Function() onDirectory;
  final ValueChanged<int> onConversationChanged;
  final FutureOr<void> Function() onUpdated;
  final FutureOr<void> Function()? onDeleted;
  final String? activeModel;
  final ActionGate? actionGate;
  const AutomationChatTools({
    super.key,
    required this.session,
    required this.identity,
    required this.thread,
    required this.onDirectory,
    required this.onConversationChanged,
    required this.onUpdated,
    this.onDeleted,
    this.activeModel,
    this.actionGate,
  });

  @override
  State<AutomationChatTools> createState() => _AutomationChatToolsState();
}

class _AutomationChatToolsState extends State<AutomationChatTools> {
  late final _ownActions = ActionGate(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  ActionGate get _actions => widget.actionGate ?? _ownActions;
  Session get session => widget.session;
  AutomationIdentity get identity => widget.identity;
  AutomationThread? get thread => widget.thread;

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    }
  }

  Future<void> _newThread(BuildContext context) => _run(context, () async {
    final client = session.api;
    if (client == null) return;
    final created = await client.createAutomationThread(identity.id);
    if (session.api != client) return;
    await session.refreshConversations();
    if (context.mounted && session.api == client) {
      widget.onConversationChanged(created.conversationId);
    }
  });

  Future<void> _delete(BuildContext context) async {
    final current = thread;
    if (current == null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话？'),
        content: const Text('将删除此独立 AI 对话及其服务器历史，且无法恢复。'),
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
    if (yes != true || !context.mounted) return;
    await _run(context, () async {
      await session.deleteAutomationThread(identity, current.conversationId);
      if (context.mounted) await widget.onDeleted?.call();
    });
  }

  Future<void> _settings(BuildContext context) async {
    final current = thread;
    if (current == null) return;
    final client = session.api;
    if (client == null) return;
    var discoveredModels = <String>[];
    try {
      discoveredModels = await client.automationModels(identity.id);
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('模型列表获取失败，仍可使用已配置模型或自动选择：$error')),
        );
      }
    }
    if (!context.mounted || session.api != client) return;
    var inherit = current.systemPrompt == null;
    var customPrompt = current.systemPrompt ?? '';
    var model = current.selectedModel;
    final prompt = TextEditingController(
      text: current.systemPrompt ?? identity.defaultSystemPrompt,
    );
    final models = {
      '',
      ...identity.models,
      ...discoveredModels,
      if (model.isNotEmpty) model,
    }.toList();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('当前对话设置'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: model,
                    decoration: const InputDecoration(labelText: '模型'),
                    items: models
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(item.isEmpty ? '自动选择（按服务端顺序尝试）' : item),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() => model = value ?? ''),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用 Manager 中的默认提示词'),
                    value: inherit,
                    onChanged: (value) => setState(() {
                      if (!inherit) customPrompt = prompt.text;
                      inherit = value;
                      prompt.text = value
                          ? identity.defaultSystemPrompt
                          : customPrompt;
                    }),
                  ),
                  TextField(
                    controller: prompt,
                    enabled: !inherit,
                    minLines: 4,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      labelText: '系统提示词',
                      helperText: '关闭默认后可单独填写；留空表示此对话没有系统提示词。',
                      helperMaxLines: 3,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    final text = prompt.text;
    prompt.dispose();
    if (saved != true || !context.mounted || session.api != client) return;
    await _run(context, () async {
      await client.updateAutomationThread(
        identity.id,
        current.conversationId,
        model: model,
        updateSystemPrompt: true,
        systemPrompt: inherit ? null : text,
      );
      if (context.mounted && session.api == client) await widget.onUpdated();
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = thread?.selectedModel.trim() ?? '';
    final model = selectedModel.isNotEmpty
        ? selectedModel
        : (widget.activeModel?.trim().isNotEmpty == true
              ? '自动选择 · ${widget.activeModel!.trim()}'
              : '自动选择');
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          children: [
            Row(
              key: const ValueKey('automation-actions-row'),
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: TextButton.icon(
                      key: const ValueKey('automation-new-thread'),
                      onPressed: _actions.busy
                          ? null
                          : () => _actions.run(() => _newThread(context)),
                      icon: const Icon(Icons.add_comment_outlined, size: 18),
                      label: const Text('新建对话'),
                    ),
                  ),
                ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: TextButton.icon(
                      key: const ValueKey('automation-switch-thread'),
                      onPressed: _actions.busy
                          ? null
                          : () => _actions.run(widget.onDirectory),
                      icon: const Icon(Icons.forum_outlined, size: 18),
                      label: const Text('切换对话'),
                    ),
                  ),
                ),
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: TextButton.icon(
                      key: const ValueKey('automation-delete-thread'),
                      onPressed: thread == null || _actions.busy
                          ? null
                          : () => _actions.run(() => _delete(context)),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('删除对话'),
                    ),
                  ),
                ),
              ],
            ),
            Row(
              key: const ValueKey('automation-model-row'),
              children: [
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: TextButton.icon(
                      key: const ValueKey('automation-model-settings'),
                      onPressed: thread == null || _actions.busy
                          ? null
                          : () => _actions.run(() => _settings(context)),
                      icon: const Icon(Icons.tune, size: 18),
                      label: const Text('模型与提示词'),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    model,
                    key: const ValueKey('automation-current-model'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
