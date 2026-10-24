/// 外观定制页：内置/用户预设、九项颜色明细（取色器）、实时预览。
library;

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';

import '../core/theme_scheme.dart';

class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final tc = context.watch<ThemeController>();
    final s = tc.scheme;

    return Scaffold(
      appBar: AppBar(title: const Text('外观定制')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _Section('预设方案'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in [...QcScheme.builtIns, ...tc.userPresets])
                  _PresetChip(
                    scheme: p,
                    selected: _sameColors(s, p),
                    onSelected: (_) => tc.apply(p),
                  ),
              ],
            ),
          ),
          if (tc.userPresets.any((p) => _sameColors(s, p)))
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextButton.icon(
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text('删除预设「${s.name}」'),
                onPressed: () => tc.deletePreset(s.name),
              ),
            ),
          _Section('实时预览'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _PreviewPane(s: s),
          ),
          _Section('颜色明细（改动即时生效并保存）'),
          _ColorRow(
            label: '主色调',
            desc: '按钮、链接、强调色',
            color: s.primary,
            onPicked: (c) => tc.apply(s.copyWith(primary: c, name: '自定义')),
          ),
          _ColorRow(
            label: '顶栏',
            desc: '应用顶栏与桌面标题栏',
            color: s.appBar,
            onPicked: (c) => tc.apply(s.copyWith(appBar: c, name: '自定义')),
          ),
          _ColorRow(
            label: '界面背景',
            desc: '会话列表、设置等页面',
            color: s.scaffoldBg,
            onPicked: (c) => tc.apply(s.copyWith(scaffoldBg: c, name: '自定义')),
          ),
          _ColorRow(
            label: '聊天背景',
            desc: '聊天页空白区域',
            color: s.chatBg,
            onPicked: (c) => tc.apply(s.copyWith(chatBg: c, name: '自定义')),
          ),
          _ColorRow(
            label: '我的气泡',
            desc: '自己发的消息底色',
            color: s.myBubble,
            onPicked: (c) => tc.apply(s.copyWith(myBubble: c, name: '自定义')),
          ),
          _ColorRow(
            label: '我的气泡文字',
            desc: '',
            color: s.myBubbleText,
            onPicked: (c) => tc.apply(s.copyWith(myBubbleText: c, name: '自定义')),
          ),
          _ColorRow(
            label: '对方气泡',
            desc: '对方消息底色',
            color: s.otherBubble,
            onPicked: (c) => tc.apply(s.copyWith(otherBubble: c, name: '自定义')),
          ),
          _ColorRow(
            label: '对方气泡文字',
            desc: '',
            color: s.otherBubbleText,
            onPicked: (c) =>
                tc.apply(s.copyWith(otherBubbleText: c, name: '自定义')),
          ),
          _ColorRow(
            label: 'AI 气泡',
            desc: '自动化身份消息底色',
            color: s.aiBubble,
            onPicked: (c) => tc.apply(s.copyWith(aiBubble: c, name: '自定义')),
          ),
          _ColorRow(
            label: 'AI 气泡文字',
            desc: '',
            color: s.aiBubbleText,
            onPicked: (c) => tc.apply(s.copyWith(aiBubbleText: c, name: '自定义')),
          ),
          _ColorRow(
            label: '未读角标',
            desc: '会话列表红点与桌面图标角标',
            color: s.unreadBadge,
            onPicked: (c) => tc.apply(s.copyWith(unreadBadge: c, name: '自定义')),
          ),
          const SizedBox(height: 16),
          Center(
            child: OutlinedButton.icon(
              onPressed: () =>
                  tc.apply(QcScheme.builtIns.first.copyWith(name: '青绿')),
              icon: const Icon(Icons.restart_alt),
              label: const Text('还原默认配色'),
            ),
          ),
        ],
      ),
    );
  }

  bool _sameColors(QcScheme a, QcScheme b) =>
      a.primary.toARGB32() == b.primary.toARGB32() &&
      a.appBar.toARGB32() == b.appBar.toARGB32() &&
      a.scaffoldBg.toARGB32() == b.scaffoldBg.toARGB32() &&
      a.chatBg.toARGB32() == b.chatBg.toARGB32() &&
      a.myBubble.toARGB32() == b.myBubble.toARGB32() &&
      a.myBubbleText.toARGB32() == b.myBubbleText.toARGB32() &&
      a.otherBubble.toARGB32() == b.otherBubble.toARGB32() &&
      a.otherBubbleText.toARGB32() == b.otherBubbleText.toARGB32() &&
      a.aiBubble.toARGB32() == b.aiBubble.toARGB32() &&
      a.aiBubbleText.toARGB32() == b.aiBubbleText.toARGB32() &&
      a.unreadBadge.toARGB32() == b.unreadBadge.toARGB32();
}

class _PresetChip extends StatelessWidget {
  final QcScheme scheme;
  final bool selected;
  final ValueChanged<bool> onSelected;

  const _PresetChip({
    required this.scheme,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      selected: selected,
      onSelected: onSelected,
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.black26),
            ),
          ),
          const SizedBox(width: 6),
          Text(scheme.name),
        ],
      ),
    );
  }
}

Future<void> _pickColor(
  BuildContext context, {
  required String label,
  required Color initial,
  required ValueChanged<Color> onPicked,
}) async {
  Color picked = initial;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('选择「$label」'),
      content: SingleChildScrollView(
        child: ColorPicker(
          pickerColor: initial,
          onColorChanged: (c) => picked = c,
          enableAlpha: false,
          hexInputBar: true,
          labelTypes: const [ColorLabelType.hex, ColorLabelType.rgb],
          pickerAreaHeightPercent: 0.8,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  if (ok == true) onPicked(picked);
}

class _ColorRow extends StatelessWidget {
  final String label;
  final String desc;
  final Color color;
  final ValueChanged<Color> onPicked;

  const _ColorRow({
    required this.label,
    required this.desc,
    required this.color,
    required this.onPicked,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black26),
        ),
      ),
      title: Text(label),
      subtitle: desc.isEmpty
          ? Text(
              '#${color.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
              style: const TextStyle(fontSize: 11),
            )
          : Text(desc, style: const TextStyle(fontSize: 11)),
      trailing: const Icon(Icons.colorize),
      onTap: () =>
          _pickColor(context, label: label, initial: color, onPicked: onPicked),
    );
  }
}

/// 迷你聊天预览：随配色实时变化。
class _PreviewPane extends StatelessWidget {
  final QcScheme s;
  const _PreviewPane({required this.s});

  @override
  Widget build(BuildContext context) {
    const radius = 14.0;
    Widget bubble({required bool mine, required String text}) {
      final bg = mine ? s.myBubble : s.otherBubble;
      final fg = mine ? s.myBubbleText : s.otherBubbleText;
      return Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          constraints: const BoxConstraints(maxWidth: 220),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Text(text, style: TextStyle(fontSize: 13, color: fg)),
        ),
      );
    }

    return Container(
      height: 230,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: s.chatBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black26),
      ),
      child: Column(
        children: [
          Container(
            height: 34,
            color: s.appBar,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.centerLeft,
            child: Text(
              '预览 · 顶栏',
              style: TextStyle(
                fontSize: 12,
                color: QcScheme.contrastOn(s.appBar),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  bubble(mine: false, text: '你好！这是对方的气泡样式'),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      constraints: const BoxConstraints(maxWidth: 220),
                      decoration: BoxDecoration(
                        color: s.aiBubble,
                        borderRadius: BorderRadius.circular(radius),
                      ),
                      child: Text(
                        '这是 AI 身份的独立气泡样式',
                        style: TextStyle(fontSize: 13, color: s.aiBubbleText),
                      ),
                    ),
                  ),
                  bubble(mine: true, text: '这是我的气泡样式 👋'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      width: 110,
                      height: 74,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      decoration: BoxDecoration(
                        color: s.myBubble,
                        borderRadius: BorderRadius.circular(radius),
                      ),
                      child: Icon(Icons.image_outlined, color: s.myBubbleText),
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '02:35',
                      style: TextStyle(
                        fontSize: 10,
                        color: s.otherBubbleText.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String text;
  const _Section(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
