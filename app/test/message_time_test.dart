import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/widgets/message_bubble.dart';

void main() {
  test('消息时间显示完整日期年份和分钟', () {
    final time = DateTime(2024, 2, 3, 4, 5);
    expect(
      formatMessageTime(time.millisecondsSinceEpoch ~/ 1000),
      '2024-02-03 04:05',
    );
  });
}
