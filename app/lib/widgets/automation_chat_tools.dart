import 'dart:async';

import 'package:flutter/material.dart';

import '../core/action_gate.dart';
import '../core/models.dart';
import '../core/model_presets.dart';
import '../core/session.dart';
import 'automation_thread_settings.dart';

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
      await session.rememberAutomationThread(
        identity.id,
        created.conversationId,
      );
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
    final saved = await showDialog<AutomationThreadSettings>(
      context: context,
      builder: (_) => AutomationThreadSettingsDialog(
        thread: current,
        defaultPrompt: identity.defaultSystemPrompt,
        availableModels: [...identity.models, ...discoveredModels],
        presetStore: ModelPresetStore(
          session.prefs,
          '${client.base}|${session.me?.id}|${identity.id}',
        ),
      ),
    );
    if (saved == null || !context.mounted || session.api != client) return;
    await _run(context, () async {
      await client.updateAutomationThread(
        identity.id,
        current.conversationId,
        models: saved.models,
        updateSystemPrompt: true,
        systemPrompt: saved.systemPrompt,
      );
      if (context.mounted && session.api == client) await widget.onUpdated();
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeModel = widget.activeModel?.trim() ?? '';
    final model = activeModel.isNotEmpty
        ? '上次使用 · $activeModel'
        : (thread?.modelOrder.isNotEmpty == true
              ? '优先 · ${thread!.modelOrder.first}'
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
