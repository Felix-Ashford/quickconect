import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_manager/main.dart';

void main() {
  testWidgets('manager starts without a profile', (tester) async {
    await tester.pumpWidget(const ManagerApp());
    expect(find.text('QuickConect Manager'), findsOneWidget);
  });
}
