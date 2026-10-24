/// 表情/贴纸面板：emoji 直接作为文字发送；自定义贴纸包（zip 导入）以贴纸消息发送。
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/session.dart';
import '../core/sticker_store.dart';

const _emojiGroups = <String, List<String>>{
  '常用': [
    '😀',
    '😂',
    '🤣',
    '😊',
    '😍',
    '😘',
    '😜',
    '😎',
    '🤔',
    '😴',
    '😭',
    '😡',
    '🥳',
    '😇',
    '🙃',
    '😅',
    '🤝',
    '👍',
    '👎',
    '👏',
    '🙏',
    '💪',
    '🤙',
    '✌️',
    '❤️',
    '💔',
    '💯',
    '🔥',
    '🎉',
    '🎂',
    '🎁',
    '🍺',
    '☕',
    '🍚',
    '🍜',
    '🍉',
    '🌸',
    '☀️',
    '🌙',
    '⭐',
    '🚗',
    '✈️',
    '🏠',
    '⚽',
    '🏀',
    '🎮',
    '🎵',
    '📱',
    '💰',
    '💊',
    '📚',
    '✅',
    '❌',
    '❓',
    '❗',
    '💤',
    '🚀',
    '🌙',
    '🐱',
    '🐶',
  ],
  '更多': [
    '🥰',
    '😳',
    '😤',
    '😰',
    '🤯',
    '😬',
    '🥺',
    '🤗',
    '😶',
    '🙄',
    '😮',
    '🤐',
    '🤒',
    '🤕',
    '🤧',
    '😷',
    '🤠',
    '🥳',
    '🤖',
    '👻',
    '💩',
    '🎃',
    '🌚',
    '🌝',
    '🌽',
    '🍔',
    '🍟',
    '🍕',
    '🍩',
    '🍪',
    '🧋',
    '🍓',
    '🥑',
    '🌶️',
    '🍄',
    '🌊',
    '🌈',
    '⚡',
    '❄️',
    '🌪️',
    '🌍',
    '🚴',
    '🏖️',
    '🎡',
    '🗼',
    '🗽',
    '🧧',
    '🀄',
    '🎲',
    '🪙',
    '💎',
    '🔔',
    '📌',
    '🔑',
    '⏰',
    '🗓️',
    '🧸',
    '🎈',
    '🛒',
    '💡',
  ],
};

class StickerPanel extends StatefulWidget {
  final int convId;
  const StickerPanel({super.key, required this.convId});

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  int _mode = 0; // 0=emoji 1=贴纸
  List<StickerPack> _packs = [];
  bool _loadingPacks = false;

  @override
  void initState() {
    super.initState();
    _loadPacks();
  }

  Future<void> _loadPacks() async {
    final session = context.read<Session>();
    final store = StickerStore(session.prefs);
    setState(() => _loadingPacks = true);
    try {
      _packs = await store.loadAll();
    } finally {
      if (mounted) setState(() => _loadingPacks = false);
    }
  }

  Future<void> _importZip() async {
    final session = context.read<Session>();
    try {
      const group = XTypeGroup(
        label: '表情包',
        extensions: ['zip'],
        uniformTypeIdentifiers: ['public.zip-archive'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final store = StickerStore(session.prefs);
      final name = await store.importZip(bytes);
      await _loadPacks();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导入表情包「$name」')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> _sendSticker(StickerPack pack, Sticker s) async {
    final session = context.read<Session>();
    try {
      final bytes = await pack.fileOf(s).readAsBytes();
      await session.sendSticker(
        widget.convId,
        bytes,
        packId: pack.id,
        stickerId: s.id,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      height: 260,
      color: cs.surfaceContainerLow,
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 8),
              _modeChip('😀 表情', 0),
              _modeChip('🧩 贴纸', 1),
              const Spacer(),
              if (_mode == 1)
                TextButton.icon(
                  onPressed: _importZip,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('导入 zip'),
                ),
            ],
          ),
          const Divider(height: 1),
          Expanded(child: _mode == 0 ? _emojiGrid() : _stickerList()),
        ],
      ),
    );
  }

  Widget _modeChip(String label, int mode) {
    final selected = _mode == mode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => setState(() => _mode = mode),
      ),
    );
  }

  Widget _emojiGrid() {
    final all = _emojiGroups.values.expand((e) => e).toList();
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
      ),
      itemCount: all.length,
      itemBuilder: (context, i) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => context.read<Session>().sendText(widget.convId, all[i]),
        child: Center(
          child: Text(all[i], style: const TextStyle(fontSize: 26)),
        ),
      ),
    );
  }

  Widget _stickerList() {
    if (_loadingPacks) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_packs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('还没有贴纸包'),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: _importZip,
              child: const Text('导入 zip 表情包'),
            ),
          ],
        ),
      );
    }
    return ListView(
      children: [
        for (final pack in _packs) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              pack.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          GridView.count(
            crossAxisCount: 5,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(8),
            children: [
              for (final s in pack.stickers)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => _sendSticker(pack, s),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Image.file(
                      pack.fileOf(s),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
