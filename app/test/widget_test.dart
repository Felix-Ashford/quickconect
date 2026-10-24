/// 登录页冒烟测试：应用启动后应停在登录页。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:quickconect_app/main.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';
import 'package:quickconect_app/core/theme_scheme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('未登录时显示登录页', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session(SharedPrefs(await SharedPreferences.getInstance()));
    final theme = ThemeController(
      SharedPrefs(await SharedPreferences.getInstance()),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: session),
          ChangeNotifierProvider.value(value: theme),
        ],
        child: const QuickConectApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('QuickConect'), findsWidgets);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
  });
}
