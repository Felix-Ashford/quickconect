// Native rendering shared by every sender and platform. Stored text stays raw.
// ignore_for_file: curly_braces_in_flow_control_structures, prefer_interpolation_to_compose_strings, unnecessary_underscores, prefer_adjacent_string_concatenation
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

class RichTextSafety {
  static const maxMessageBytes = 256 * 1024;
  static bool isSafeRemoteImage(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  static String sanitizeHtml(String source) {
    var value = source;
    for (final tag in ['script', 'iframe', 'object', 'embed', 'style']) {
      final lower = value.toLowerCase();
      final start = lower.indexOf('<' + tag);
      if (start >= 0) {
        final end = lower.indexOf('</' + tag + '>', start);
        value = value.replaceRange(
          start,
          end >= 0 ? end + tag.length + 3 : value.length,
          '',
        );
      }
    }
    return value.replaceAll(RegExp('<[^>]*>'), '');
  }
}

enum RichBlockKind {
  paragraph,
  heading,
  quote,
  list,
  code,
  formula,
  mermaid,
  table,
  html,
  image,
}

class RichBlock {
  final RichBlockKind kind;
  final String text;
  final int level;
  const RichBlock(this.kind, this.text, {this.level = 0});
}

class _MathSyntax extends md.InlineSyntax {
  _MathSyntax() : super(r'\$([^\s$](?:[^$\n]*?[^\s$])?)\$|\\\(([^\n]*?)\\\)');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    if (match.group(1) != null &&
        ((match.start > 0 && parser.source[match.start - 1] == r'$') ||
            (match.end < parser.source.length &&
                RegExp(r'[\d$]').hasMatch(parser.source[match.end]))))
      return false;
    parser.addNode(md.Element.text('math', match.group(1) ?? match.group(2)!));
    return true;
  }
}

md.Document _document() => md.Document(
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
  inlineSyntaxes: [_MathSyntax()],
);

List<RichBlock> parseRichTextBlocks(String source) {
  if (utf8.encode(source).length > RichTextSafety.maxMessageBytes) {
    return [
      RichBlock(
        RichBlockKind.code,
        source.substring(0, source.length.clamp(0, 65536)),
      ),
    ];
  }
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final out = <RichBlock>[];
  var i = 0;
  final fence = String.fromCharCode(96) * 3;
  final heading = RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$');
  final list = RegExp(r'^\s*(?:[-*+] |\d+[.)] )');
  final separator = RegExp(r'^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$');
  bool tableAt(int at) =>
      at + 1 < lines.length &&
      lines[at].contains('|') &&
      lines[at + 1].contains('|') &&
      separator.hasMatch(lines[at + 1]);
  bool blockStart(int at) {
    final value = lines[at].trimLeft();
    return value.startsWith(fence) ||
        value.startsWith(r'$$') ||
        value.startsWith(r'\[') ||
        heading.hasMatch(value) ||
        value.startsWith('>') ||
        list.hasMatch(value) ||
        tableAt(at) ||
        value.startsWith('![') ||
        value.startsWith('<');
  }

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.isEmpty) {
      i++;
      continue;
    }
    if (trimmed.startsWith(fence)) {
      final lang = line.trim().substring(3).trim().toLowerCase();
      final body = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith(fence))
        body.add(lines[i++]);
      if (i < lines.length) i++;
      out.add(
        RichBlock(
          lang == 'mermaid' ? RichBlockKind.mermaid : RichBlockKind.code,
          body.join('\n'),
        ),
      );
      continue;
    }
    if (trimmed.startsWith(r'$$') || trimmed.startsWith(r'\[')) {
      final close = trimmed.startsWith(r'$$') ? r'$$' : r'\]';
      final body = <String>[];
      var endLine = i;
      var end = trimmed.indexOf(close, 2);
      if (end >= 0) {
        body.add(trimmed.substring(2, end));
      } else {
        body.add(trimmed.substring(2));
        while (++endLine < lines.length) {
          end = lines[endLine].indexOf(close);
          if (end >= 0) {
            body.add(lines[endLine].substring(0, end));
            break;
          }
          if (lines[endLine].trim().isEmpty || blockStart(endLine)) break;
          body.add(lines[endLine]);
        }
      }
      if (end >= 0) {
        out.add(RichBlock(RichBlockKind.formula, body.join('\n').trim()));
        final ending = endLine == i ? trimmed : lines[endLine];
        final tail = ending.substring(end + close.length);
        i = endLine + 1;
        if (tail.trim().isNotEmpty) out.addAll(parseRichTextBlocks(tail));
      } else {
        out.add(RichBlock(RichBlockKind.paragraph, line));
        i++;
      }
      continue;
    }
    final title = heading.firstMatch(line);
    if (title != null) {
      out.add(
        RichBlock(
          RichBlockKind.heading,
          title.group(2)!,
          level: title.group(1)!.length,
        ),
      );
      i++;
      continue;
    }
    if (trimmed.startsWith('>')) {
      out.add(RichBlock(RichBlockKind.quote, trimmed.substring(1).trim()));
      i++;
      continue;
    }
    if (list.hasMatch(line)) {
      final body = <String>[];
      while (i < lines.length && list.hasMatch(lines[i])) body.add(lines[i++]);
      out.add(RichBlock(RichBlockKind.list, body.join('\n')));
      continue;
    }
    if (tableAt(i)) {
      final body = <String>[lines[i++], lines[i++]];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          lines[i].contains('|') &&
          !blockStart(i))
        body.add(lines[i++]);
      out.add(RichBlock(RichBlockKind.table, body.join('\n')));
      continue;
    }
    final image = RegExp(r'^\s*!\[([^]]*)\]\(([^)]+)\)\s*$').firstMatch(line);
    if (image != null) {
      out.add(
        RichBlock(
          RichBlockKind.image,
          image.group(1)! + '\n' + image.group(2)!,
        ),
      );
      i++;
      continue;
    }
    if (trimmed.startsWith('<')) {
      out.add(RichBlock(RichBlockKind.html, RichTextSafety.sanitizeHtml(line)));
      i++;
      continue;
    }
    final body = <String>[line];
    i++;
    while (i < lines.length && lines[i].trim().isNotEmpty && !blockStart(i))
      body.add(lines[i++]);
    out.add(RichBlock(RichBlockKind.paragraph, body.join('\n')));
  }
  return out;
}

class RichTextRenderer extends StatelessWidget {
  final String text;
  final String format;
  final int formatVersion;
  final Color color;
  const RichTextRenderer({
    super.key,
    required this.text,
    this.format = 'plain',
    this.formatVersion = 1,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    final tooLarge = utf8.encode(text).length > RichTextSafety.maxMessageBytes;
    final source = tooLarge
        ? text.substring(0, text.length.clamp(0, 65536))
        : text;
    if (tooLarge || formatVersion > 1) {
      return SelectableText(source, style: TextStyle(color: color));
    }
    final hasRich =
        RegExp(r'\$[^\s$][^$\n]*\$|\\\(.+?\\\)|\\\[').hasMatch(source) ||
        source.contains('**') ||
        source.contains('~~') ||
        parseRichTextBlocks(source).any(
          (b) =>
              b.kind == RichBlockKind.table || b.kind == RichBlockKind.formula,
        );
    if (formatVersion > 1 || (format == 'plain' && !hasRich))
      return SelectableText(source, style: TextStyle(color: color));
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 600.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final block in parseRichTextBlocks(source))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _render(block, width),
              ),
          ],
        );
      },
    );
  }

  Widget _render(RichBlock block, double width) {
    switch (block.kind) {
      case RichBlockKind.heading:
        return _inline(
          block.text,
          width,
          bold: true,
          size: (22 - block.level).clamp(16, 21).toDouble(),
        );
      case RichBlockKind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 8),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 3)),
          ),
          child: _inline(block.text, width - 8, italic: true),
        );
      case RichBlockKind.list:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in block.text.split('\n'))
              _inline(item.trim(), width),
          ],
        );
      case RichBlockKind.code:
        return _code(block.text);
      case RichBlockKind.formula:
        return _formula(block.text, width, display: true);
      case RichBlockKind.mermaid:
        return _code(block.text, label: 'Mermaid diagram');
      case RichBlockKind.table:
        return _table(block.text, width);
      case RichBlockKind.html:
        return SelectableText(
          RichTextSafety.sanitizeHtml(block.text),
          style: TextStyle(color: color),
        );
      case RichBlockKind.image:
        final parts = block.text.split('\n');
        return _RemoteImage(
          url: parts.length > 1 ? parts[1] : '',
          label: parts.first,
        );
      case RichBlockKind.paragraph:
        return _inline(block.text, width);
    }
  }

  Widget _code(String value, {String? label}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(8),
    color: Colors.black12,
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectableText(
        label == null ? value : '$label\n$value',
        style: TextStyle(fontFamily: 'monospace', color: color),
      ),
    ),
  );
  Widget _formula(String tex, double width, {bool display = false}) {
    final raw = display ? '\$\$\n$tex\n\$\$' : '\$$tex\$';
    if (tex.length > 8192 ||
        RegExp(r'\\(?:href|url|includegraphics|html\w*)\b').hasMatch(tex))
      return _code(raw);
    final math = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: TextStyle(color: color, fontSize: display ? 18 : 15),
      onErrorFallback: (_) => SelectableText(
        raw,
        style: TextStyle(color: color, fontFamily: 'monospace'),
      ),
    );
    return GestureDetector(
      onLongPress: () => Clipboard.setData(ClipboardData(text: tex)),
      onSecondaryTap: () => Clipboard.setData(ClipboardData(text: tex)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: display ? 8 : 2),
            child: math,
          ),
        ),
      ),
    );
  }

  Widget _inline(
    String value,
    double width, {
    bool bold = false,
    bool italic = false,
    double size = 15,
  }) {
    return _inlineNodes(
      _document().parseInline(value),
      width,
      bold: bold,
      italic: italic,
      size: size,
    );
  }

  Widget _inlineNodes(
    List<md.Node> nodes,
    double width, {
    bool bold = false,
    bool italic = false,
    double size = 15,
    TextAlign textAlign = TextAlign.left,
  }) {
    var hasWidgets = false;
    InlineSpan span(md.Node node) {
      if (node is md.Text) return TextSpan(text: node.text);
      if (node is! md.Element) return TextSpan(text: node.textContent);
      if (node.tag == 'math') {
        hasWidgets = true;
        return WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _formula(node.textContent, width),
        );
      }
      if (node.tag == 'img') {
        hasWidgets = true;
        return WidgetSpan(
          child: _RemoteImage(
            url: node.attributes['src'] ?? '',
            label: node.attributes['alt'] ?? '',
          ),
        );
      }
      if (node.tag == 'br') return const TextSpan(text: '\n');
      final nodeStyle = switch (node.tag) {
        'strong' => const TextStyle(fontWeight: FontWeight.bold),
        'em' => const TextStyle(fontStyle: FontStyle.italic),
        'del' => const TextStyle(decoration: TextDecoration.lineThrough),
        'code' => const TextStyle(
          fontFamily: 'monospace',
          backgroundColor: Colors.black12,
        ),
        'a' => const TextStyle(
          color: Colors.blue,
          decoration: TextDecoration.underline,
        ),
        _ => null,
      };
      return TextSpan(
        style: nodeStyle,
        children: [
          for (final child in node.children ?? <md.Node>[]) span(child),
        ],
      );
    }

    final root = TextSpan(
      style: TextStyle(
        color: color,
        fontSize: size,
        fontWeight: bold ? FontWeight.bold : null,
        fontStyle: italic ? FontStyle.italic : null,
      ),
      children: [for (final node in nodes) span(node)],
    );
    // SelectableText does not support WidgetSpan; SelectionArea handles text
    // around native math widgets. Formulas copy their TeX on long/right press.
    return hasWidgets
        ? SelectionArea(child: Text.rich(root, textAlign: textAlign))
        : SelectableText.rich(root, textAlign: textAlign);
  }

  Widget _table(String source, double width) {
    final nodes = _document().parseLines(source.split('\n'));
    final table = nodes
        .whereType<md.Element>()
        .where((e) => e.tag == 'table')
        .firstOrNull;
    if (table == null) return _code(source);
    final rows = <md.Element>[];
    void collect(md.Element e) {
      if (e.tag == 'tr') {
        rows.add(e);
        return;
      }
      for (final child in e.children ?? <md.Node>[])
        if (child is md.Element) collect(child);
    }

    collect(table);
    if (rows.isEmpty || rows.length > 200) return _code(source);
    final columns = (rows.first.children ?? <md.Node>[]).length;
    if (columns == 0 || columns > 32) return _code(source);
    // Bounded column widths also bound inline math and let wide tables scroll.
    final cellWidth = (width / columns).clamp(140.0, 320.0);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: FixedColumnWidth(cellWidth),
        border: TableBorder.all(color: color.withValues(alpha: 0.25)),
        children: [
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: BoxDecoration(
                color: r == 0 ? color.withValues(alpha: 0.08) : null,
              ),
              children: [
                for (var c = 0; c < columns; c++)
                  _tableCell(
                    (rows[r].children ?? <md.Node>[]).elementAtOrNull(c),
                    cellWidth,
                    r == 0,
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _tableCell(md.Node? node, double width, bool header) {
    final alignment = node is md.Element ? node.attributes['align'] : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: _inlineNodes(
        node is md.Element ? node.children ?? [] : <md.Node>[],
        width - 20,
        bold: header,
        textAlign: alignment == 'right'
            ? TextAlign.right
            : alignment == 'center'
            ? TextAlign.center
            : TextAlign.left,
      ),
    );
  }
}

class _RemoteImage extends StatefulWidget {
  final String url;
  final String label;
  const _RemoteImage({required this.url, required this.label});
  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<_RemoteImage> {
  bool loaded = false;
  @override
  Widget build(BuildContext context) {
    if (!RichTextSafety.isSafeRemoteImage(widget.url))
      return SelectableText('[不安全的外部图片：' + widget.label + ']');
    if (!loaded)
      return OutlinedButton.icon(
        onPressed: () => setState(() => loaded = true),
        icon: const Icon(Icons.image_outlined),
        label: Text(widget.label.isEmpty ? '加载外部图片' : widget.label),
      );
    return Image.network(
      widget.url,
      errorBuilder: (_, __, ___) =>
          SelectableText('[图片加载失败：' + widget.label + ']'),
    );
  }
}
