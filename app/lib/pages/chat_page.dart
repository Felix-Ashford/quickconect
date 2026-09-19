import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../core/theme_scheme.dart';
import '../core/ws_client.dart';
import '../widgets/message_bubble.dart';
import '../widgets/sticker_panel.dart';

class ChatPage extends StatefulWidget {
  final int convId;
  const ChatPage({super.key, required this.convId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _recorder = AudioRecorder();
  late final Session _session = context.read<Session>();

  bool _showPanel = false;
  bool _recording = false;
  String _recExt = 'm4a';
  String? _recPath;
  DateTime? _recStart;

  @override
  void initState() {
    super.initState();
    _session.currentConvId = widget.convId;
    // 进入聊天：加载历史并标记已读
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _session.openConversation(widget.convId);
    });
  }

  @override
  void dispose() {
    // 不能在 dispose 里读 context（祖先查找已失效），用 initState 捕获的引用
    _session.currentConvId = null;
    _input.dispose();
    _focus.dispose();
    _recorder.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    setState(() {});
    context.read<Session>().sendText(widget.convId, text);
    _focus.requestFocus();
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
        const group = XTypeGroup(label: '图片', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp']);
        final file = await openFile(acceptedTypeGroups: [group]);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        var w = 0, h = 0;
        try {
          final im = img.decodeImage(bytes);
          if (im != null) {
            w = im.width;
            h = im.height;
          }
        } catch (_) {}
        await session.sendImage(widget.convId, bytes,
            width: w, height: h, name: file.name);
      } else {
        final file = await openFile();
        if (file == null) return;
        final bytes = await file.readAsBytes();
        await session.sendFile(widget.convId, bytes, file.name);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    }
  }

  // ---------- 语音 ----------

  Future<void> _startRecording() async {
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('需要麦克风权限')));
        }
        return;
      }
      final dir = await getTemporaryDirectory();
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
      _recStart = DateTime.now();
      setState(() => _recording = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('录音启动失败：$e')));
      }
    }
  }

  Future<void> _stopRecording({required bool send}) async {
    if (!_recording) return;
    final path = await _recorder.stop();
    if (!mounted) return;
    setState(() => _recording = false);
    if (path == null) return;
    final durationMs = _recStart == null
        ? 0
        : DateTime.now().difference(_recStart!).inMilliseconds;
    _recStart = null;

    if (!send || durationMs < 600) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
      if (!mounted) return;
      if (!send) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已取消')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('说话时间太短')));
      }
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      await File(path).delete();
      if (!mounted) return;
      await context.read<Session>().sendVoice(widget.convId, bytes, durationMs,
          ext: _recExt);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final conv = session.convs[widget.convId];
    final meId = session.me?.id;
    final peer = (conv != null && meId != null) ? conv.peer(meId) : null;
    final msgs = session.msgs[widget.convId] ?? const [];

    return Scaffold(
      backgroundColor: qcColorsOf(context).chatBg,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(peer?.displayName ?? '会话 ${widget.convId}'),
            Text(
              switch (session.wsState) {
                WsState.connected => '在线',
                WsState.connecting => '连接中…',
                WsState.disconnected => '离线（自动重连中）',
              },
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: msgs.isEmpty
                ? const Center(child: Text('打个招呼吧 👋'))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: msgs.length,
                    itemBuilder: (context, i) {
                      final m = msgs[msgs.length - 1 - i];
                      return MessageBubble(
                        // 消息级 key：避免 ListView 按下标复用控件导致的状态错位
                        key: ValueKey(m.id),
                        message: m,
                        isMine: meId != null && m.senderId == meId,
                        onRetry: m.status == MsgStatus.failed
                            ? () => session.retry(m)
                            : null,
                      );
                    },
                  ),
          ),
          if (_recording) _recordingBar(),
          const Divider(height: 1),
          _inputRow(),
          if (_showPanel) StickerPanel(convId: widget.convId),
        ],
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
              onPressed: () => _pickAttachment(context),
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
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            IconButton(
              tooltip: '表情',
              icon: Icon(_showPanel ? Icons.keyboard_alt_outlined : Icons.emoji_emotions_outlined),
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
                onLongPressStart: (_) => _startRecording(),
                onLongPressEnd: (_) => _stopRecording(send: true),
                child: IconButton(
                  onPressed: null, // 只支持长按
                  icon: Icon(
                    Icons.mic,
                    color: _recording ? Theme.of(context).colorScheme.error : null,
                  ),
                  tooltip: '按住说话',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
