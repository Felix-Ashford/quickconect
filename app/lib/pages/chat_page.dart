import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../core/action_gate.dart';
import '../core/theme_scheme.dart';
import '../core/ws_client.dart';
import '../widgets/message_bubble.dart';
import '../widgets/contact_picker.dart';
import '../widgets/sticker_panel.dart';
import '../widgets/automation_chat_tools.dart';
import '../widgets/automation_thread_directory.dart';
import '../widgets/mention_suggestions.dart';
import 'settings_page.dart';

class ChatPage extends StatefulWidget {
  final int convId;
  final bool showConversationPicker;
  final ValueChanged<int>? onConversationChanged;
  const ChatPage({
    super.key,
    required this.convId,
    this.showConversationPicker = false,
    this.onConversationChanged,
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  late final _uiActions = ActionGate(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  Future<void> _uiAction(Future<dynamic> Function() action) async {
    await _uiActions.run(() => _messageAction(action));
  }

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  String? _lastMessageId;
  bool _hasRenderedMessages = false;
  final _recorder = AudioRecorder();
  final _imagePicker = ImagePicker();
  late final Session _session = context.read<Session>();

  bool _showPanel = false;
  double _panelHeight = 280;
  bool _recording = false;
  String _recExt = 'm4a';
  String? _recPath;
  DateTime? _recStart;
  Future<void>? _recordingStart;
  bool _stoppingRecording = false;
  List<AutomationIdentity> _automations = const [];
  AutomationThread? _automationThread;
  String? _threadTitleSignature;
  int _lastThreadUpdateVersion = -1;
  final Map<int, String> _drafts = {};
  bool _leavingDeletedThread = false;
  String? _contextSignature;
  Map<String, dynamic> _contextStates = {};
  String? _contextError;

  Future<void> _loadContextVisibility(
    AutomationIdentity identity,
    String signature,
  ) async {
    final client = _session.api;
    final conversationId = widget.convId;
    if (client == null) return;
    try {
      final result = await client.automationContext(
        identity.id,
        conversationId,
      );
      if (!mounted ||
          _session.api != client ||
          widget.convId != conversationId ||
          _contextSignature != signature) {
        return;
      }
      setState(() {
        _contextStates = Map<String, dynamic>.from(
          result['messages'] as Map? ?? {},
        );
        _contextError = null;
      });
    } catch (_) {
      if (mounted &&
          _session.api == client &&
          widget.convId == conversationId &&
          _contextSignature == signature) {
        setState(() => _contextError = '上下文状态暂不可用，请确认服务端已更新');
      }
    }
  }

  Future<void> _deleteExcludedMessage(Message message) async {
    final identity = _currentIdentity;
    if (identity == null || identity.mode != 'api') return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除上下文外消息？'),
        content: const Text('此消息将从这个独立对话中移除，并同步到你的其他设备。删除后无法恢复。'),
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
    if (confirmed == true && mounted) {
      await _session.deleteExcludedMessage(identity.id, message);
    }
  }

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _session.currentConvId = widget.convId;
    // 进入聊天：加载历史并标记已读
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session.openConversation(widget.convId);
      _loadAutomations();
    });
  }

  Future<void> _loadAutomations() async {
    final client = _session.api;
    if (client == null) return;
    try {
      final items = await client.automationIdentities();
      if (mounted && _session.api == client) {
        setState(() => _automations = items);
        await _loadCurrentThread();
      }
    } catch (_) {
      // Older servers may not expose automation routes.
    }
  }

  AutomationIdentity? get _currentIdentity {
    final conv = _session.convs[widget.convId];
    final peer = conv?.peer(_session.me?.id ?? -1);
    return _automations.where((item) => item.userId == peer?.id).firstOrNull;
  }

  Future<void> _loadCurrentThread() async {
    final identity = _currentIdentity;
    if (identity == null || identity.mode != 'api') return;
    final client = _session.api;
    if (client == null) return;
    final conversationId = widget.convId;
    try {
      final threads = await client.automationThreads(identity.id);
      if (mounted &&
          _session.api == client &&
          widget.convId == conversationId) {
        setState(() {
          _automationThread = threads
              .where((thread) => thread.conversationId == conversationId)
              .firstOrNull;
        });
        if (_automationThread != null) {
          await _session.rememberAutomationThread(identity.id, conversationId);
        }
      }
    } catch (_) {
      // Keep the last known thread settings when temporarily offline.
    }
  }

  String? get _activeAutomationModel {
    final messages = _session.msgs[widget.convId] ?? const <Message>[];
    for (final message in messages.reversed) {
      if (message.isDeleted) continue;
      if (_automations.any((a) => a.userId == message.senderId)) {
        final model = message.payload['model'];
        if (model is String && model.trim().isNotEmpty) return model.trim();
      }
    }
    return null;
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openAutomationDirectory(AutomationIdentity identity) =>
      _showAutomationDirectory(identity);

  Future<void> _renameAutomationThread() async {
    final current = _automationThread;
    final identity = _currentIdentity;
    final client = _session.api;
    if (current == null || identity == null || client == null) return;
    final controller = TextEditingController(text: current.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改对话名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty || !mounted || _session.api != client) {
      return;
    }
    await _messageAction(() async {
      await client.updateAutomationThread(
        identity.id,
        current.conversationId,
        title: title,
      );
      if (mounted && _session.api == client) await _loadCurrentThread();
    });
  }

  Future<void> _showAutomationDirectory(AutomationIdentity identity) async {
    if (!mounted) return;
    final client = _session.api;
    if (client == null) return;
    final conversationId = widget.convId;
    final threads = await client.automationThreads(identity.id);
    if (!mounted || _session.api != client || widget.convId != conversationId) {
      return;
    }
    final selected = await showModalBottomSheet<AutomationDirectorySelection>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AutomationThreadDirectory(
        name: identity.displayName.isEmpty
            ? identity.name
            : identity.displayName,
        threads: threads,
        currentConversationId: conversationId,
        deleteThread: (thread) async {
          if (_session.api != client) throw StateError('账号已经切换');
          await _session.deleteAutomationThread(
            identity,
            thread.conversationId,
          );
          if (_session.api != client) return null;
          return threads
              .where(
                (item) =>
                    item.conversationId != thread.conversationId &&
                    _session.convs.containsKey(item.conversationId),
              )
              .firstOrNull;
        },
        createThread: () async {
          if (_session.api != client) throw StateError('账号已经切换');
          return client.createAutomationThread(identity.id);
        },
      ),
    );
    if (selected == null ||
        !mounted ||
        _session.api != client ||
        widget.convId != conversationId) {
      return;
    }
    if (selected.conversationId > 0) {
      await _session.rememberAutomationThread(
        identity.id,
        selected.conversationId,
      );
    }
    await _session.refreshConversations();
    if (!mounted || _session.api != client || widget.convId != conversationId) {
      return;
    }
    if (selected.conversationId < 0) {
      final next = _session.sortedConvs().firstOrNull;
      if (next != null) {
        widget.onConversationChanged?.call(next.id);
      } else {
        widget.onConversationChanged?.call(-1);
      }
    } else if (_session.convs.containsKey(selected.conversationId)) {
      widget.onConversationChanged?.call(selected.conversationId);
    } else {
      await _session.openConversation(selected.conversationId);
      if (mounted) setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.convId != widget.convId) {
      _drafts[oldWidget.convId] = _input.text;
      _input.text = _drafts[widget.convId] ?? '';
      _threadTitleSignature = null;
      _automationThread = null;
      _leavingDeletedThread = false;
      _contextSignature = null;
      _contextStates = {};
      _contextError = null;
      _lastMessageId = null;
      _hasRenderedMessages = false;
      _session.currentConvId = widget.convId;
      _session.openConversation(widget.convId);
      _loadCurrentThread();
    }
  }

  @override
  void dispose() {
    // 不能在 dispose 里读 context（祖先查找已失效），用 initState 捕获的引用
    _session.currentConvId = null;
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    _disposeRecorder();
    super.dispose();
  }

  Future<void> _disposeRecorder() async {
    // 权限弹窗返回前页面可能已关闭，等待启动结束再释放原生资源。
    await _recordingStart;
    try {
      await _recorder.cancel();
    } catch (_) {
      // 取消失败仍需释放录音器。
    } finally {
      await _recorder.dispose();
    }
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    setState(() {});
    context.read<Session>().sendText(widget.convId, text);
    _focus.requestFocus();
  }

  Future<void> _editMessage(Message message) async {
    final controller = TextEditingController(text: message.text);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改消息'),
        content: SizedBox(
          width: 560,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 12,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    await _messageAction(() => _session.editMessage(message, text));
  }

  Future<void> _retractMessage(Message message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回消息'),
        content: const Text('撤回后，同一会话的所有参与者和设备会同步更新。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('撤回'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _messageAction(() => _session.retractMessage(message));
    }
  }

  Future<void> _messageAction(Future<dynamic> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作失败：$error')));
      }
    }
  }

  List<AutomationIdentity> _messageAutomations(Message message) {
    final current = _currentIdentity;
    if (current != null && current.mode == 'api') return [current];
    return _automations
        .where(
          (item) =>
              item.mode == 'api' &&
              item.mentionEnabled &&
              (mentionsName(message.text, item.name) ||
                  mentionsName(message.text, item.displayName)),
        )
        .toList();
  }

  Future<void> _regenerateMessage(Message message) async {
    final candidates = _messageAutomations(message);
    if (candidates.isEmpty) return;
    var selected = candidates.first;
    if (candidates.length > 1) {
      final chosen = await showModalBottomSheet<AutomationIdentity>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('选择回复用户')),
              for (final item in candidates)
                ListTile(
                  title: Text(
                    item.displayName.isEmpty ? item.name : item.displayName,
                  ),
                  onTap: () => Navigator.pop(ctx, item),
                ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      selected = chosen;
    }
    await _messageAction(
      () => _session.regenerateMessage(selected.id, message),
    );
  }

  // ---------- 附件 ----------

  Future<void> _pickAttachment(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('图片'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final session = context.read<Session>();
    try {
      if (choice == 'image') {
        final picked = Platform.isIOS || Platform.isAndroid
            ? await _imagePicker.pickImage(source: ImageSource.gallery)
            : null;
        final file = picked == null && !Platform.isIOS && !Platform.isAndroid
            ? await openFile(
                acceptedTypeGroups: [
                  const XTypeGroup(
                    label: '图片',
                    extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
                  ),
                ],
              )
            : null;
        if (picked == null && file == null) return;
        final bytes = picked != null
            ? await picked.readAsBytes()
            : await file!.readAsBytes();
        final fileName = picked?.name ?? file!.name;
        var w = 0, h = 0;
        try {
          final im = img.decodeImage(bytes);
          if (im != null) {
            w = im.width;
            h = im.height;
          }
        } catch (_) {}
        await session.sendImage(
          widget.convId,
          bytes,
          width: w,
          height: h,
          name: fileName,
        );
      } else {
        final file = await openFile();
        if (file == null) return;
        final bytes = await file.readAsBytes();
        await session.sendFile(widget.convId, bytes, file.name);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    }
  }

  // ---------- 语音 ----------

  Future<void> _startRecording() async {
    if (!mounted || _recording || _stoppingRecording) return;
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('需要麦克风权限，请在系统设置中允许 QuickConect 使用麦克风'),
            ),
          );
        }
        return;
      }
      if (!mounted) return;
      final dir = await getTemporaryDirectory();
      if (!mounted) return;
      // Windows 端 AAC 编码兼容性不稳，直接用 wav；移动端用 AAC
      _recExt = Platform.isWindows ? 'wav' : 'm4a';
      _recPath =
          '${dir.path}${Platform.pathSeparator}voice_${DateTime.now().millisecondsSinceEpoch}.$_recExt';
      await _recorder.start(
        RecordConfig(
          encoder: _recExt == 'wav' ? AudioEncoder.wav : AudioEncoder.aacLc,
          bitRate: _recExt == 'wav' ? 128000 : 24000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: _recPath!,
      );
      if (!mounted) return;
      _recStart = DateTime.now();
      setState(() => _recording = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('录音启动失败：$e')));
      }
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    // 首次授权和原生启动可能尚未结束，松手后也要完成对应的停止操作。
    await _recordingStart;
    if (!mounted || !_recording || _stoppingRecording) return;
    _stoppingRecording = true;
    setState(() => _recording = false);
    final durationMs = _recStart == null
        ? 0
        : DateTime.now().difference(_recStart!).inMilliseconds;
    _recStart = null;

    try {
      final path = await _recorder.stop();
      if (path == null) return;
      if (!mounted || !send || durationMs < 600) {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
        if (!mounted) return;
        if (!send) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('已取消')));
        } else {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('说话时间太短')));
        }
        return;
      }
      final bytes = await File(path).readAsBytes();
      await File(path).delete();
      if (!mounted) return;
      await context.read<Session>().sendVoice(
        widget.convId,
        bytes,
        durationMs,
        ext: _recExt,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('录音或发送失败：$e')));
      }
    } finally {
      _stoppingRecording = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    if (session.automationConversationDeleted(widget.convId) &&
        !_uiActions.busy &&
        !_leavingDeletedThread) {
      _leavingDeletedThread = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onConversationChanged?.call(
          session.sortedConvs().firstOrNull?.id ?? -1,
        );
      });
    }
    final conv = session.convs[widget.convId];
    final meId = session.me?.id;
    final peer = (conv != null && meId != null) ? conv.peer(meId) : null;
    final isPrivateApiChat = _currentIdentity?.mode == 'api';
    final chatTitle = isPrivateApiChat
        ? (_automationThread?.title.isNotEmpty == true
              ? _automationThread!.title
              : '新对话')
        : (peer?.displayName ?? '会话 ${widget.convId}');
    final allMessages = session.msgs[widget.convId] ?? const <Message>[];
    final msgs = allMessages.where((message) => !message.isDeleted).toList();
    if (isPrivateApiChat) {
      final signature =
          '${widget.convId}:${session.threadUpdateVersion}:${session.api.hashCode}:${allMessages.map((m) => '${m.id}:${m.revision}:${m.status.name}').join(',')}';
      if (_contextSignature != signature) {
        _contextSignature = signature;
        _contextStates = {};
        _contextError = null;
        final identity = _currentIdentity!;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadContextVisibility(identity, signature);
        });
      }
    }
    if (_currentIdentity?.mode == 'api' &&
        (_automationThread?.title.isEmpty == true ||
            _lastThreadUpdateVersion != session.threadUpdateVersion)) {
      _lastThreadUpdateVersion = session.threadUpdateVersion;
      final signature = '${msgs.lastOrNull?.id}:${session.threadUpdateVersion}';
      if (_threadTitleSignature != signature) {
        _threadTitleSignature = signature;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadCurrentThread();
        });
      }
    }
    if (msgs.isNotEmpty && msgs.last.id != _lastMessageId) {
      final wasNearBottom =
          !_scroll.hasClients || _scroll.position.extentAfter < 100;
      final follow =
          _hasRenderedMessages && (wasNearBottom || msgs.last.senderId == meId);
      _lastMessageId = msgs.last.id;
      if (_currentIdentity?.mode == 'api') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadCurrentThread();
        });
      }
      _hasRenderedMessages = true;
      if (follow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(_scroll.position.maxScrollExtent);
          }
        });
      }
    }

    return Scaffold(
      backgroundColor: qcColorsOf(context).chatBg,
      appBar: AppBar(
        centerTitle: isPrivateApiChat,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: isPrivateApiChat && !_uiActions.busy
              ? () => _uiAction(_renameAutomationThread)
              : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: isPrivateApiChat
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              Text(
                chatTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: isPrivateApiChat
                    ? TextAlign.center
                    : TextAlign.start,
              ),
              Text(switch (session.wsState) {
                WsState.connected => '在线',
                WsState.connecting => '连接中…',
                WsState.disconnected => '离线（自动重连中）',
              }, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        actions: [
          if (widget.showConversationPicker)
            IconButton(
              tooltip: '切换对话',
              icon: const Icon(Icons.people_alt_outlined),
              onPressed: _uiActions.busy
                  ? null
                  : () => _uiAction(() async {
                      final id = await pickConversation(context, session);
                      if (mounted && id != null) {
                        widget.onConversationChanged?.call(id);
                      }
                    }),
            ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _uiActions.busy
                ? null
                : () => _uiAction(
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const SettingsPage()),
                    ),
                  ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final maxPanelHeight = (constraints.maxHeight * 0.5).clamp(
            80.0,
            520.0,
          );
          return Column(
            children: [
              if (_currentIdentity case final identity?
                  when identity.mode == 'api')
                AutomationChatTools(
                  actionGate: _uiActions,
                  session: session,
                  identity: identity,
                  thread: _automationThread,
                  activeModel: _activeAutomationModel,
                  onDirectory: () => _openAutomationDirectory(identity),
                  onUpdated: _loadCurrentThread,
                  onDeleted: () async {
                    await session.refreshConversations();
                    if (!mounted) return;
                    final threads =
                        await session.api?.automationThreads(identity.id) ??
                        const <AutomationThread>[];
                    final next = threads.isEmpty ? null : threads.first;
                    if (next != null) {
                      await session.rememberAutomationThread(
                        identity.id,
                        next.conversationId,
                      );
                      await session.refreshConversations();
                    }
                    if (next != null) {
                      widget.onConversationChanged?.call(next.conversationId);
                    } else {
                      widget.onConversationChanged?.call(-1);
                    }
                  },
                  onConversationChanged: (id) =>
                      widget.onConversationChanged?.call(id),
                ),
              if (isPrivateApiChat)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _contextError ?? '上下文外的消息使用单独的气泡颜色，可在外观设置中修改；新提问会占用字符预算。上下文外的 AI 回复可通过消息菜单删除。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      IconButton(
                        tooltip: '刷新上下文状态',
                        icon: const Icon(Icons.refresh, size: 18),
                        onPressed: () =>
                            setState(() => _contextSignature = null),
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: msgs.isEmpty
                    ? const Center(child: Text('打个招呼吧 👋'))
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: msgs.length,
                        itemBuilder: (context, i) {
                          final m = msgs[i];
                          final state = _contextStates[m.id] as Map?;
                          final excluded =
                              state != null && state['included'] == false;
                          return MessageBubble(
                            // 消息级 key：避免 ListView 按下标复用控件导致的状态错位
                            key: ValueKey(m.id),
                            message: m,
                            excludedFromAIContext: excluded,
                            onDelete:
                                isPrivateApiChat &&
                                    state?['can_delete'] == true &&
                                    !m.isPending
                                ? () =>
                                      _uiAction(() => _deleteExcludedMessage(m))
                                : null,
                            isMine: meId != null && m.senderId == meId,
                            isAutomation: _automations.any(
                              (a) => a.userId == m.senderId,
                            ),
                            onRetry: m.status == MsgStatus.failed
                                ? () => _uiAction(() => session.retry(m))
                                : null,
                            onEdit:
                                meId == m.senderId &&
                                    !m.isPending &&
                                    !m.isRetracted &&
                                    m.type == 'text'
                                ? () => _uiAction(() => _editMessage(m))
                                : null,
                            onRetract:
                                meId == m.senderId &&
                                    !m.isPending &&
                                    !m.isRetracted
                                ? () => _uiAction(() => _retractMessage(m))
                                : null,
                            onRegenerate:
                                meId == m.senderId &&
                                    !m.isPending &&
                                    !m.isRetracted &&
                                    m.type == 'text' &&
                                    _messageAutomations(m).isNotEmpty
                                ? () => _uiAction(() => _regenerateMessage(m))
                                : null,
                          );
                        },
                      ),
              ),
              if (_recording) _recordingBar(),
              if (_currentIdentity == null)
                MentionSuggestions(
                  session: session,
                  controller: _input,
                  identities: _automations,
                  onSelected: _focus.requestFocus,
                ),
              const Divider(height: 1),
              _inputRow(),
              if (_showPanel) ...[
                GestureDetector(
                  key: const ValueKey('sticker-panel-resize-handle'),
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    setState(
                      () => _panelHeight = (_panelHeight - details.delta.dy)
                          .clamp(80.0, maxPanelHeight),
                    );
                  },
                  child: SizedBox(
                    height: 24,
                    child: Center(
                      child: Container(
                        width: 52,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: _panelHeight.clamp(80.0, maxPanelHeight),
                  child: StickerPanel(convId: widget.convId),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _recordingBar() {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
          const SizedBox(width: 8),
          const Expanded(child: Text('正在录音… 松开发送')),
          TextButton(
            onPressed: () => _stopRecording(send: false),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Widget _inputRow() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            IconButton(
              tooltip: '图片 / 文件',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: _uiActions.busy
                  ? null
                  : () => _uiAction(() => _pickAttachment(context)),
            ),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '输入消息…',
                  border: OutlineInputBorder(),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '表情',
              icon: Icon(
                _showPanel
                    ? Icons.keyboard_alt_outlined
                    : Icons.emoji_emotions_outlined,
              ),
              onPressed: () => setState(() => _showPanel = !_showPanel),
            ),
            if (_input.text.trim().isNotEmpty)
              IconButton(
                onPressed: _send,
                icon: const Icon(Icons.send_rounded),
                tooltip: '发送',
              )
            else
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (_) {
                  if (_recordingStart != null ||
                      _recording ||
                      _stoppingRecording) {
                    return;
                  }
                  _recordingStart = _startRecording().whenComplete(() {
                    _recordingStart = null;
                  });
                },
                onLongPressEnd: (_) => _stopRecording(send: true),
                onLongPressCancel: () => _stopRecording(send: false),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请按住麦克风说话，松开发送')),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.all(0),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Icon(
                      Icons.mic,
                      color: _recording
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
