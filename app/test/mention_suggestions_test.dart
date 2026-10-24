import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quickconect_app/widgets/mention_suggestions.dart';

void main() {
  test('typing @ starts a mention at the caret', () {
    const value = TextEditingValue(
      text: '请问 @',
      selection: TextSelection.collapsed(offset: 4),
    );
    final query = MentionQuery.fromValue(value);
    expect(query?.query, '');
    expect(query?.start, 3);
  });

  test('inserting mention preserves the suffix and moves caret', () {
    const value = TextEditingValue(
      text: 'hello @bo trailing',
      selection: TextSelection.collapsed(offset: 9),
    );
    final query = MentionQuery.fromValue(value)!;
    final result = query.insert(value, 'robot');
    expect(result.text, 'hello @robot  trailing');
    expect(result.selection.extentOffset, 13);
  });

  test('email and noncollapsed selections do not show suggestions', () {
    expect(
      MentionQuery.fromValue(
        const TextEditingValue(
          text: 'a@b',
          selection: TextSelection.collapsed(offset: 3),
        ),
      ),
      isNull,
    );
    expect(
      MentionQuery.fromValue(
        const TextEditingValue(
          text: '@bot',
          selection: TextSelection(baseOffset: 0, extentOffset: 4),
        ),
      ),
      isNull,
    );
  });
}
