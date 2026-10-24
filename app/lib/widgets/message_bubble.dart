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
import 'rich_text_renderer.dart';

/// 消息气泡：按类型渲染文字/图片/语音/文件/表情。
/// 发送失败标红，点击重试（重试复用已上传的 media_id，不重复上传）。
class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final bool isAutomation;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final VoidCallback? onRetract;
  final VoidCallback? onRegenerate;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.isAutomation = false,
    this.onRetry,
    this.onEdit,
    this.onRetract,
    this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final session = context.read<Session>();
    final qc = qcColorsOf(context);
    final cs = Theme.of(context).colorScheme;
    final m = message;

    // 表情贴纸：不带气泡背景
    if (m.type == 'sticker' && !m.isRetracted && onRetract == null) {
      return _StickerContent(key: ValueKey(m.id), session: session, m: m);
    }

    final failed = m.status == MsgStatus.failed;
    final bg = failed
        ? cs.errorContainer
        : isAutomation
        ? qc.aiBubble
        : isMine
        ? qc.myBubble
        : qc.otherBubble;
    final fg = failed
        ? cs.onErrorContainer
        : isAutomation
        ? qc.aiBubbleText
        : isMine
        ? qc.myBubbleText
        : qc.otherBubbleText;

    final Widget content = m.isRetracted
        ? Text(
            '消息已撤回',
            style: TextStyle(
              color: fg.withValues(alpha: .6),
              fontStyle: FontStyle.italic,
            ),
          )
        : switch (m.type) {
            'image' => _ImageContent(session: session, m: m),
            'sticker' => _StickerContent(
              key: ValueKey(m.id),
              session: session,
              m: m,
            ),
            'voice' => _VoiceContent(session: session, m: m),
            'file' => _FileContent(session: session, m: m),
            _ => RichTextRenderer(
              text: m.text,
              format: m.format,
              formatVersion: m.formatVersion,
              color: fg,
            ),
          };

    final bubble = Container(
      key: ValueKey('message-surface-${m.id}'),
      margin: const EdgeInsets.only(right: 12, top: 4, bottom: 4),
      padding: m.type == 'image'
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        // 四角统一圆弧（无气泡尾巴造型）
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.senderName.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                m.senderName,
                style: TextStyle(
                  fontSize: 11,
                  color: cs.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          content,
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                formatMessageTime(m.createdAt),
                style: TextStyle(
                  fontSize: 10,
                  color: fg.withValues(alpha: 0.55),
                ),
              ),
              if (m.isEdited && !m.isRetracted) ...[
                const SizedBox(width: 4),
                Text(
                  '已编辑',
                  style: TextStyle(
                    fontSize: 10,
                    color: fg.withValues(alpha: .55),
                  ),
                ),
              ],
              if (onEdit != null || onRetract != null || onRegenerate != null)
                SizedBox(
                  width: 28,
                  height: 24,
                  child: PopupMenuButton<String>(
                    tooltip: '消息操作',
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.more_horiz, size: 18, color: fg),
                    onSelected: (action) {
                      switch (action) {
                        case 'edit':
                          onEdit?.call();
                        case 'retract':
                          onRetract?.call();
                        case 'regenerate':
                          onRegenerate?.call();
                      }
                    },
                    itemBuilder: (_) => [
                      if (onEdit != null)
                        const PopupMenuItem(value: 'edit', child: Text('修改消息')),
                      if (onRetract != null)
                        const PopupMenuItem(
                          value: 'retract',
                          child: Text('撤回消息'),
                        ),
                      if (onRegenerate != null)
                        const PopupMenuItem(
                          value: 'regenerate',
                          child: Text('重新生成回复'),
                        ),
                    ],
                  ),
                ),
              if (m.status == MsgStatus.sending) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.schedule,
                  size: 11,
                  color: fg.withValues(alpha: 0.55),
                ),
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
      alignment: Alignment.centerLeft,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 6, top: 6),
            child: MessageAvatar(
              session: session,
              mediaId: m.senderAvatarMediaId,
              name: m.senderName,
            ),
          ),
          Flexible(child: bubble),
        ],
      ),
    );
    if (failed) {
      return GestureDetector(onTap: onRetry, child: align);
    }
    return align;
  }
}

class MessageAvatar extends StatelessWidget {
  final Session session;
  final String mediaId;
  final String name;
  const MessageAvatar({
    super.key,
    required this.session,
    required this.mediaId,
    required this.name,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    if (mediaId.isEmpty) {
      return CircleAvatar(radius: 18, child: Text(initial));
    }
    return FutureBuilder<Uint8List>(
      future: session.mediaStore.downloadAvatar(mediaId),
      builder: (context, snap) {
        if (snap.data == null) {
          return CircleAvatar(radius: 18, child: Text(initial));
        }
        return CircleAvatar(
          radius: 18,
          backgroundImage: MemoryImage(snap.data!),
        );
      },
    );
  }
}

String formatMessageTime(int createdAtSeconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(createdAtSeconds * 1000);
  final date =
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';
  final time =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return '$date $time';
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
  Future<Uint8List>? _imageFuture;
  String? _futureMediaId;
  Future<Uint8List>? _fullImageFuture;
  String? _fullImageMediaId;

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
    final mediaId =
        (m.payload['thumb_media_id'] ?? m.payload['media_id']) as String?;
    if (mediaId != null) session.mediaStore.retryDownload(mediaId);
    setState(() {
      _attempt++;
      _futureMediaId = mediaId;
      _imageFuture = mediaId == null
          ? null
          : session.mediaStore.download(mediaId);
      final fullId = m.payload['media_id'] as String? ?? mediaId;
      _fullImageMediaId = fullId;
      _fullImageFuture = fullId == null
          ? null
          : session.mediaStore.download(fullId);
    });
  }

  @override
  void didUpdateWidget(covariant _ImageContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final thumbId =
        (m.payload['thumb_media_id'] ?? m.payload['media_id']) as String?;
    final fullId = m.payload['media_id'] as String? ?? thumbId;
    if (thumbId != _futureMediaId) {
      _futureMediaId = thumbId;
      _imageFuture = thumbId == null
          ? null
          : session.mediaStore.download(thumbId);
    }
    if (fullId != _fullImageMediaId) {
      _fullImageMediaId = fullId;
      _fullImageFuture = fullId == null
          ? null
          : session.mediaStore.download(fullId);
    }
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
            Text(
              m.status == MsgStatus.failed ? '发送失败' : '发送中…',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (_futureMediaId != mediaId || _imageFuture == null) {
      _futureMediaId = mediaId;
      _imageFuture = session.mediaStore.download(mediaId);
    }
    final fullId = m.payload['media_id'] as String? ?? mediaId;
    if (_fullImageMediaId != fullId || _fullImageFuture == null) {
      _fullImageMediaId = fullId;
      _fullImageFuture = session.mediaStore.download(fullId);
    }
    final fullImage = _fullImageFuture!;
    final fileName = m.payload['name'] as String? ?? 'image.jpg';
    return GestureDetector(
      onTap: () => showImageViewer(context, fullImage, fileName: fileName),
      onSecondaryTap: () => saveImage(context, fullImage, fileName),
      onLongPress: Platform.isIOS
          ? () => saveImage(context, fullImage, fileName)
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 200,
          child: AspectRatio(
            aspectRatio: _aspect,
            child: FutureBuilder<Uint8List>(
              key: ValueKey(_attempt),
              future: _imageFuture,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Container(
                    color: Colors.black12,
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (snap.hasError || snap.data == null) {
                  // 记录真实失败原因到 %TEMP%\quickconect_client.log 供诊断
                  if (_loggedAttempt != _attempt) {
                    _loggedAttempt = _attempt;
                    MediaStore.log(
                      '图片渲染失败 mediaId=$mediaId attempt=$_attempt err=${snap.error}',
                    );
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
                return Image.memory(
                  snap.data!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                );
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
                  final f = await session.mediaStore.saveToTemp(
                    mediaId,
                    bytes,
                    ext: ext,
                  );
                  await player.toggle(mediaId, f.path);
                } catch (_) {}
              },
              icon: Icon(
                playingId == mediaId ? Icons.pause_circle : Icons.play_circle,
                size: 34,
              ),
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
    final object = context.findRenderObject();
    final shareOrigin = object is RenderBox && object.hasSize
        ? object.localToGlobal(Offset.zero) & object.size
        : null;
    try {
      final name = m.payload['name'] as String? ?? '文件';
      final mediaId = m.payload['media_id'] as String;
      final bytes = await session.mediaStore.download(mediaId);

      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final loc = await getSaveLocation(suggestedName: name);
        if (loc == null) return;
        await File(loc.path).writeAsBytes(bytes);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已保存到 ${loc.path}')));
        }
      } else if (Platform.isIOS) {
        final ext = name.contains('.') ? name.split('.').last : 'bin';
        final f = await session.mediaStore.saveToTemp(mediaId, bytes, ext: ext);
        await shareFilesFromOrigin(shareOrigin, [XFile(f.path)], text: name);
      } else {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory(
          '${docs.path}${Platform.pathSeparator}QuickConect',
        );
        if (!dir.existsSync()) dir.createSync(recursive: true);
        final f = File('${dir.path}${Platform.pathSeparator}$name');
        await f.writeAsBytes(bytes);
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已保存到 ${f.path}')));
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = m.payload['name'] as String? ?? '文件';
    final size = (m.payload['size'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: m.isPending ? null : () => _save(context),
      onLongPress: m.isPending ? null : () => _save(context),
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
                Text(
                  humanSize(size),
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- 表情贴纸 ----------

class _StickerContent extends StatefulWidget {
  final Session session;
  final Message m;
  const _StickerContent({super.key, required this.session, required this.m});

  @override
  State<_StickerContent> createState() => _StickerContentState();
}

class _StickerContentState extends State<_StickerContent> {
  String? _mediaId;
  Future<Uint8List>? _imageFuture;

  void _load(String? mediaId) {
    _mediaId = mediaId;
    _imageFuture = mediaId == null
        ? null
        : widget.session.mediaStore.download(mediaId);
  }

  @override
  void didUpdateWidget(covariant _StickerContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextId = widget.m.payload['media_id'] as String?;
    if (nextId != _mediaId) _load(nextId);
  }

  @override
  Widget build(BuildContext context) {
    final mediaId = widget.m.payload['media_id'] as String?;
    if (mediaId == null) return const SizedBox.shrink();
    if (_mediaId != mediaId || _imageFuture == null) _load(mediaId);
    return GestureDetector(
      onTap: () => showImageViewer(
        context,
        widget.session.mediaStore.download(mediaId),
        fileName: widget.m.payload['name'] as String? ?? 'sticker.png',
      ),
      onSecondaryTap: () => saveImage(
        context,
        widget.session.mediaStore.download(mediaId),
        widget.m.payload['name'] as String? ?? 'sticker.png',
      ),
      onLongPress: Platform.isIOS
          ? () => saveImage(
              context,
              widget.session.mediaStore.download(mediaId),
              widget.m.payload['name'] as String? ?? 'sticker.png',
            )
          : null,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<Uint8List>(
              future: _imageFuture,
              builder: (context, snap) {
                if (snap.data == null) {
                  return const SizedBox(
                    width: 110,
                    height: 110,
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                return Image.memory(
                  snap.data!,
                  width: 110,
                  height: 110,
                  fit: BoxFit.contain,
                );
              },
            ),
            const SizedBox(height: 2),
            Text(
              formatMessageTime(widget.m.createdAt),
              style: const TextStyle(fontSize: 10, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
