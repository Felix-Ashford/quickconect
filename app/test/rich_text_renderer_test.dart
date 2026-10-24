// ignore_for_file: prefer_interpolation_to_compose_strings, prefer_adjacent_string_concatenation, curly_braces_in_flow_control_structures
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:quickconect_app/widgets/rich_text_renderer.dart';

void main() {
  test(
    'display delimiters close on same line and preserve following blocks',
    () {
      for (final source in [
        r'$$x^2$$' + '\nAfter\n| A | B |\n| --- | --- |\n| 1 | 2 |',
        r'\[x^2\]' + '\nAfter\n| A | B |\n| --- | --- |\n| 1 | 2 |',
        '\$\$\nx^2\n\$\$\nAfter\n| A | B |\n| --- | --- |\n| 1 | 2 |',
      ]) {
        final blocks = parseRichTextBlocks(source);
        expect(blocks.first.kind, RichBlockKind.formula);
        expect(blocks.first.text, 'x^2');
        expect(blocks[1].text, 'After');
        expect(blocks.last.kind, RichBlockKind.table);
      }
      final unmatched = parseRichTextBlocks('\$\$x^2\n\n# Following');
      expect(unmatched.first.kind, RichBlockKind.paragraph);
      expect(unmatched.last.kind, RichBlockKind.heading);
      expect(parseRichTextBlocks('a | b').single.kind, RichBlockKind.paragraph);
    },
  );

  Future<void> render(
    WidgetTester tester,
    String source, {
    String format = 'markdown',
    int version = 1,
    double width = 320,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: RichTextRenderer(
                text: source,
                format: format,
                formatVersion: version,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: source);
  }

  testWidgets('inline math and display math use native typesetting', (
    tester,
  ) async {
    await render(
      tester,
      r'行内 $x^2 + \frac{1}{2}$ 与 \(\alpha\)' +
          '\n' +
          r'$$\sum_{i=1}^{n}i=\frac{n(n+1)}{2}$$',
    );
    expect(find.byType(Math), findsNWidgets(3));
    for (final math in tester.widgetList<Math>(find.byType(Math))) {
      expect(math.parseError, isNull);
    }
    await render(tester, r'$$\begin{pmatrix}1 & 2 \\ 3 & 4\end{pmatrix}$$');
    expect(tester.widget<Math>(find.byType(Math)).parseError, isNull);
  });

  testWidgets('code, escaped dollars and currency are not formulas', (
    tester,
  ) async {
    final code = String.fromCharCode(96);
    await render(tester, code + r'$x^2$' + code + r' and \$10 and $20 and $30');
    expect(find.byType(Math), findsNothing);
  });

  testWidgets('GFM tables render cells with styling, escaping and math', (
    tester,
  ) async {
    await render(
      tester,
      r'Intro' +
          '\n' +
          r'Name | Value | Code' +
          '\n' +
          r':--- | :---: | ---:' +
          '\n' +
          r'**bold** | $x^2$ | a\|b' +
          '\nAfter',
    );
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children.length, 2);
    expect(table.children.first.children.length, 3);
    expect(find.byType(Math), findsOneWidget);
    final selected = tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    );
    expect(selected.any((w) => w.textSpan?.toPlainText() == 'a|b'), isTrue);
    final bold = selected.singleWhere(
      (w) => w.textSpan?.toPlainText() == 'bold',
    );
    expect(bold.textSpan!.children!.first.style!.fontWeight, FontWeight.bold);
    expect(find.text('After', findRichText: true), findsOneWidget);
  });

  testWidgets('wide tables and formulas scroll across phone and desktop sizes', (
    tester,
  ) async {
    for (final width in [280.0, 700.0]) {
      await render(
        tester,
        '| A | B | C | D | E |\n| --- | --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 | 5 |\n\n' +
            r'$$' +
            List.filled(60, r'x^2').join('+') +
            r'$$',
        width: width,
      );
      final formulaGesture = find
          .byWidgetPredicate(
            (w) => w is GestureDetector && w.onLongPress != null,
          )
          .first;
      final formulaScroll = tester.state<ScrollableState>(
        find.descendant(of: formulaGesture, matching: find.byType(Scrollable)),
      );
      expect(formulaScroll.position.maxScrollExtent, greaterThan(0));
      final tableScroll = tester.state<ScrollableState>(
        find
            .ancestor(of: find.byType(Table), matching: find.byType(Scrollable))
            .first,
      );
      expect(
        tableScroll.position.maxScrollExtent,
        width < 700 ? greaterThan(0) : 0,
      );
    }
  });

  testWidgets(
    'historical plain math and tables render; future formats fall back',
    (tester) async {
      final source = r'$x^2$' + '\nA | B\n--- | ---\n1 | 2';
      await render(tester, source, format: 'plain');
      expect(find.byType(Math), findsOneWidget);
      expect(find.byType(Table), findsOneWidget);
      await render(tester, source, format: 'markdown', version: 2);
      expect(find.byType(Math), findsNothing);
      expect(find.byType(Table), findsNothing);
      expect(find.text(source), findsOneWidget);
    },
  );

  testWidgets('invalid LaTeX stays readable and formula source can be copied', (
    tester,
  ) async {
    await render(tester, r'$$\notARealCommand{x}$$');
    expect(tester.widget<Math>(find.byType(Math)).parseError, isNotNull);
    expect(find.byType(SelectableText), findsOneWidget);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = (call.arguments as Map)['text'] as String;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await render(tester, r'$$x^2$$');
    await tester.longPress(
      find
          .byWidgetPredicate(
            (w) => w is GestureDetector && w.onLongPress != null,
          )
          .first,
    );
    expect(copied, 'x^2');
  });
  test('parses markdown blocks and safe fallbacks', () {
    final fence = String.fromCharCode(96) * 3;
    final blocks = parseRichTextBlocks(
      '# Title\n> quote\n- task\n' + fence + 'dart\nprint(1);\n' + fence,
    );
    expect(blocks.map((b) => b.kind), contains(RichBlockKind.heading));
    expect(blocks.map((b) => b.kind), contains(RichBlockKind.code));
  });

  test('blocks unsafe external images and removes active HTML', () {
    expect(RichTextSafety.isSafeRemoteImage('javascript:alert(1)'), isFalse);
    expect(
      RichTextSafety.isSafeRemoteImage('https://example.com/a.png'),
      isTrue,
    );
    expect(
      RichTextSafety.sanitizeHtml('<script>alert(1)</script><b>ok</b>'),
      'ok',
    );
  });

  test('large messages use bounded input', () {
    final blocks = parseRichTextBlocks(
      'x' * (RichTextSafety.maxMessageBytes + 1),
    );
    expect(blocks.single.kind, RichBlockKind.code);
    expect(blocks.single.text.length, lessThanOrEqualTo(65536));
  });

  test('unmatched inline markers never throw', () {
    for (final text in [
      'hello`',
      'hello**',
      'hello~~',
      'test',
      '12345',
      '[link](https://example.com)',
      '![unfinished',
    ]) {
      expect(() => parseRichTextBlocks(text), returnsNormally);
    }
  });

  testWidgets('ordinary messages and single-character code delimiters render', (
    tester,
  ) async {
    for (final text in [
      'test1',
      'hello`',
      '`',
      '`x`',
      '**bold**',
      '~~deleted~~',
      '![unfinished',
      '\u4f60\u597d',
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichTextRenderer(
              text: text,
              format: 'markdown',
              color: Colors.black,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: text);
      final selectable = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      if (text == '`x`') {
        expect(selectable.textSpan!.toPlainText(), 'x');
        expect(
          selectable.textSpan!.children!.single.style!.fontFamily,
          'monospace',
        );
      } else if (text == 'hello`' || text == '`') {
        expect(selectable.textSpan!.toPlainText(), text);
      }
    }
  });
}
