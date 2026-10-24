import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickconect_app/widgets/mention_suggestions.dart';

void main() {
  test('complete mentions exclude emails and partial usernames', () {
    expect(mentionsName('@helper please', 'helper'), isTrue);
    expect(mentionsName('请问 @Helper?', 'helper'), isTrue);
    expect(mentionsName('(@helper)', 'helper'), isTrue);
    expect(mentionsName('@Helper Smith，please', 'Helper Smith'), isTrue);
    expect(mentionsName('@helper2', 'helper'), isFalse);
    expect(mentionsName('mail@helper.com', 'helper'), isFalse);
    expect(mentionsName('x@helper', 'helper'), isFalse);
    expect(mentionsName('@helper_name', 'helper'), isFalse);
  });

  TextEditingValue input(String text, [int? caret]) => TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: caret ?? text.length),
  );

  test('recognizes @ at beginning and after whitespace', () {
    expect(MentionQuery.fromValue(input('@'))?.query, '');
    expect(MentionQuery.fromValue(input('请问 @assistant'))?.query, 'assistant');
    expect(MentionQuery.fromValue(input('换行\n@助手'))?.query, '助手');
    expect(MentionQuery.fromValue(input('a@example.com')), isNull);
    expect(MentionQuery.fromValue(input('s@assistant')), isNull);
  });

  test('replaces only active mention and keeps remaining draft', () {
    final value = input('请问 @ass 后面的内容', 7);
    final mention = MentionQuery.fromValue(value)!;
    final changed = mention.insert(value, 'assistant');
    expect(changed.text, '请问 @assistant  后面的内容');
    expect(changed.selection.extentOffset, '请问 @assistant '.length);
  });

  test('ignores non-collapsed and invalid selection', () {
    expect(MentionQuery.fromValue(const TextEditingValue(text: '@助手')), isNull);
    expect(
      MentionQuery.fromValue(
        const TextEditingValue(
          text: '@助手',
          selection: TextSelection(baseOffset: 0, extentOffset: 2),
        ),
      ),
      isNull,
    );
  });
}
