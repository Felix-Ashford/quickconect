import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/media_store.dart';
import '../core/theme_scheme.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../core/voice_player.dart';
import 'image_viewer.dart';

/// 消息气泡：按类型渲染文字/图片/语音/文件/表情。
/// 发送失败标红，点击重试（重试复用已上传的 media_id，不重复上传）。
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.onRetry,
  });

  String get _time {
    final t = DateTime.fromMillisecondsSinceEpoch(message.createdAt * 1000);
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final qc = qcColorsOf(context);
    final cs = Theme.of(context).colorScheme;
    final m = message;

    // 表情贴纸：不带气泡背景
    if (m.type == 'sticker') {
      return _StickerContent(
        key: ValueKey(m.id),
        session: session,
        m: m,
      );
    }

    final failed = m.status == MsgStatus.failed;
    final bg = failed
        ? cs.errorContainer
        : isMine
            ? qc.myBubble
            : qc.otherBubble;
    final fg = failed
        ? cs.onErrorContainer
        : isMine
            ? qc.myBubbleText
            : qc.otherBubbleText;

    final Widget content = switch (m.type) {
      'image' => _ImageContent(session: session, m: m),
      'voice' => _VoiceContent(session: session, m: m),
      'file' => _FileContent(session: session, m: m),
      _ => SelectableText(m.text, style: TextStyle(fontSize: 15, color: fg)),
    };

    final bubble = Container(
      margin: EdgeInsets.only(
        left: isMine ? 64 : 12,
        right: isMine ? 12 : 64,
        top: 4,
        bottom: 4,
      ),
      padding: m.type == 'image'
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: bg,
        // 四角统一圆弧（无气泡尾巴造型）
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isMine && m.senderName.isNotEmpty && m.type != 'image')
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                m.senderName,
                style: TextStyle(fontSize: 11, color: cs.primary, fontWeight: FontWeight.w600),
              ),
            ),
          content,
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_time,
                  style: TextStyle(
                      fontSize: 10, color: fg.withValues(alpha: 0.55))),
              if (m.status == MsgStatus.sending) ...[
                const SizedBox(width: 4),
                Icon(Icons.schedule, size: 11, color: fg.withValues(alpha: 0.55)),
              ],
              if (failed) ...[
                const SizedBox(width: 4),
                Icon(Icons.error_outline, size: 12, color: cs.error),
              ],
            ],
          ),
        ],
      ),
    );

    final align = Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: bubble,
    );
    if (failed) {
      return GestureDetector(onTap: onRetry, child: align);
    }
    return align;
  }
}

// ---------- 图片 ----------

class _ImageContent extends StatefulWidget {
  final Session session;
  final Message m;
  const _ImageContent({required this.session, required this.m});

  @override
  State<_ImageContent> createState() => _ImageContentState();
}

class _ImageContentState extends State<_ImageContent> {
  static const _maxAutoRetry = 2;
  int _attempt = 0;
  int _loggedAttempt = -1;
  Timer? _retryTimer;

  Message get m => widget.m;
  Session get session => widget.session;

  double get _aspect {
    final w = (m.payload['w'] as num?)?.toDouble() ?? 1;
    final h = (m.payload['h'] as num?)?.toDouble() ?? 1;
    final a = h > 0 ? w / h : 1.0;
    return a.clamp(0.6, 1.9);
  }

  void _retry() {
    if (!mounted) return;
    final mediaId = (m.payload['thumb_media_id'] ?? m.payload['media_id']) as String?;
    if (mediaId != null) session.mediaStore.retryDownload(mediaId);
    setState(() => _attempt++);
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaId =
        (m.payload['thumb_media_id'] ?? m.payload['media_id']) as String?;
    if (m.isPending || mediaId == null) {
      return Container(
        width: 200,
        height: 140,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined),
            Text(m.status == MsgStatus.failed ? '发送失败' : '发送中…',
                style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    return GestureDetector(
      onTap: () => showImageViewer(
        context,
        session.mediaStore.download(m.payload['media_id'] as String? ?? mediaId),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 200,
          child: AspectRatio(
            aspectRatio: _aspect,
            child: FutureBuilder<Uint8List>(
              key: ValueKey(_attempt),
              future: session.mediaStore.download(mediaId),
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Container(
                      color: Colors.black12,
                      alignment: Alignment.center,
                      child: const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2)));
                }
                if (snap.hasError || snap.data == null) {
                  // 记录真实失败原因到 %TEMP%\quickconect_client.log 供诊断
                  if (_loggedAttempt != _attempt) {
                    _loggedAttempt = _attempt;
                    MediaStore.log(
                        '图片渲染失败 mediaId=$mediaId attempt=$_attempt err=${snap.error}');
                  }
                  if (_attempt <= _maxAutoRetry && _retryTimer == null) {
                    _retryTimer = Timer(const Duration(seconds: 3), () {
                      _retryTimer = null;
                      if (mounted) _retry();
                    });
                  }
                  return GestureDetector(
                    onTap: _retry,
                    child: Container(
                      color: Colors.black12,
                      alignment: Alignment.center,
                      child: const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.broken_image_outlined),
                          SizedBox(height: 4),
                          Text('加载失败，点按重试', style: TextStyle(fontSize: 11)),
                        ],
                      ),
                    ),
                  );
                }
                return Image.memory(snap.data!,
                    fit: BoxFit.cover, gaplessPlayback: true);
              },
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- 语音 ----------

class _VoiceContent extends StatelessWidget {
  final Session session;
  final Message m;
  const _VoiceContent({required this.session, required this.m});

  @override
  Widget build(BuildContext context) {
    final mediaId = m.payload['media_id'] as String? ?? m.id;
    final durationMs = (m.payload['duration_ms'] as num?)?.toInt() ?? 0;
    final player = VoicePlayer.instance;

    return Container(
      constraints: const BoxConstraints(minWidth: 160),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ValueListenableBuilder<String?>(
            valueListenable: player.playing,
            builder: (context, playingId, _) => IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                if (playingId == mediaId) {
                  await player.stop();
                  return;
                }
                try {
                  final bytes = await session.mediaStore.download(mediaId);
                  final ext = (m.payload['ext'] as String?) ?? 'm4a';
                  final f = await session.mediaStore.saveToTemp(mediaId, bytes, ext: ext);
                  await player.toggle(mediaId, f.path);
                } catch (_) {}
              },
              icon: Icon(playingId == mediaId ? Icons.pause_circle : Icons.play_circle,
                  size: 34),
            ),
          ),
          const SizedBox(width: 4),
          Text('${(durationMs / 1000).round()}″'),
          const SizedBox(width: 6),
          ValueListenableBuilder<String?>(
            valueListenable: player.playing,
            builder: (context, playingId, _) => playingId == mediaId
                ? ValueListenableBuilder<int>(
                    valueListenable: player.positionMs,
                    builder: (context, pos, _) => SizedBox(
                      width: 40,
                      child: LinearProgressIndicator(
                        value: durationMs > 0
                            ? (pos / durationMs).clamp(0.0, 1.0)
                            : 0,
                        minHeight: 3,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// ---------- 文件 ----------

class _FileContent extends StatelessWidget {
  final Session session;
  final Message m;
  const _FileContent({required this.session, required this.m});

  Future<void> _save(BuildContext context) async {
    try {
      final name = m.payload['name'] as String? ?? '文件';
      final mediaId = m.payload['media_id'] as String;
      final bytes = await session.mediaStore.download(mediaId);

      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await File(loc.path).writeAsBytes(bytes);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已保存到 ${loc.path}')));
        }
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}${Platform.pathSeparator}QuickConect');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final f = File('${dir.path}${Platform.pathSeparator}$name');
        await f.writeAsBytes(bytes);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已保存到 ${f.path}')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = m.payload['name'] as String? ?? '文件';
    final size = (m.payload['size'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: m.isPending ? null : () => _save(context),
      borderRadius: BorderRadius.circular(8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined, size: 32),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(humanSize(size),
                    style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 表情贴纸 ----------

class _StickerContent extends StatelessWidget {
  final Session session;
  final Message m;
  const _StickerContent({super.key, required this.session, required this.m});

  @override
  Widget build(BuildContext context) {
    final mediaId = m.payload['media_id'] as String?;
    if (mediaId == null) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => showImageViewer(context, session.mediaStore.download(mediaId)),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: FutureBuilder<Uint8List>(
          future: session.mediaStore.download(mediaId),
          builder: (context, snap) {
            if (snap.data == null) {
              return const SizedBox(
                  width: 110, height: 110,
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
            }
            return Image.memory(snap.data!, width: 110, height: 110, fit: BoxFit.contain);
          },
        ),
      ),
    );
  }
}
