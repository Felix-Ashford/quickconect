import 'dart:async';
import 'dart:io';

import 'package:app_badge_plus/app_badge_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'core/android_keepalive.dart';
import 'core/cert_pinning.dart';
import 'core/ios_keepalive.dart';
import 'core/models.dart';
import 'core/notifications.dart';
import 'core/prefs.dart';
import 'core/session.dart';
import 'core/theme_scheme.dart';
import 'core/voice_player.dart';
import 'pages/chat_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'widgets/custom_title_bar.dart';

final _navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 提前订阅语音播放完成与进度事件。
  await VoicePlayer.instance.init();
  final prefs = SharedPrefs(await SharedPreferences.getInstance());
  PinningStore.loadFromPrefs(prefs);
  HttpOverrides.global = PinningOverrides();

  // 桌面端：无边框窗口 + 自定义标题栏（去掉系统黑边）
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      size: Size(430, 740),
      minimumSize: Size(360, 600),
      title: 'QuickConect',
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  await Notify.init();
  Notify.onOpenConversation = (convId) {
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    Navigator.push(
      ctx,
      MaterialPageRoute(builder: (_) => ChatPage(convId: convId)),
    );
  };

  final session = Session(prefs);
  session.incomingNotifier = (m) {
    Notify.showMessage(
      title: m.senderName,
      body: messagePreview(m),
      convId: m.convId,
    );
  };
  unawaited(session.tryResume());

  // 角标：未读总数实时同步到桌面图标
  session.addListener(() {
    try {
      AppBadgePlus.updateBadge(session.totalUnread);
    } catch (_) {}
  });

  // 保活开关：登录态变化时应用（设置页里改开关即时生效）
  var lastLoggedIn = false;
  session.addListener(() {
    if (session.loggedIn == lastLoggedIn) return;
    lastLoggedIn = session.loggedIn;
    if (!session.loggedIn) {
      unawaited(AndroidKeepAlive.setEnabled(false));
      unawaited(IosKeepAlive.setEnabled(false));
      return;
    }
    if (Platform.isAndroid && prefs.getBool('android_keepalive') == true) {
      unawaited(AndroidKeepAlive.setEnabled(true));
    }
    if (Platform.isIOS && prefs.getBool('ios_keepalive') == true) {
      unawaited(IosKeepAlive.setEnabled(true));
    }
  });

  final themeController = ThemeController(prefs);
  await themeController.load();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: themeController),
      ],
      child: const QuickConectApp(),
    ),
  );
}

class QuickConectApp extends StatelessWidget {
  const QuickConectApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeController>(
      builder: (context, theme, _) => MaterialApp(
        title: 'QuickConect',
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        navigatorKey: _navKey,
        theme: buildQcTheme(theme.scheme),
        builder: (context, child) => Column(
          children: [
            const QcTitleBar(),
            Expanded(child: child ?? const SizedBox.shrink()),
          ],
        ),
        home: Consumer<Session>(
          builder: (context, session, _) =>
              session.loggedIn ? const HomePage() : const LoginPage(),
        ),
      ),
    );
  }
}
