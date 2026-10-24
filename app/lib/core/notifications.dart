/// 本地通知（App 存活期间的新消息提醒）：
///  - iOS/iPadOS：免费签名无 APNs，靠这条在 App 活着时出横幅
///  - Android：前台服务存活时同样适用（M2 再加前台服务）
///  - Windows：桌面托盘通知
/// App 被系统杀掉后的兜底推送由 ntfy 铃负责（M2）。
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notify {
  Notify._();
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// 点击通知后打开对应会话（main.dart 注入导航）。
  static void Function(int convId)? onOpenConversation;

  static Future<void> init() async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
      windows: WindowsInitializationSettings(
        appName: 'QuickConect',
        appUserModelId: 'com.quickconect.app',
        guid: 'B1A7E2C0-8E1F-4C3A-9D2B-6F5E4A3B2C1D',
      ),
    );
    await _plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _onResponse,
    );
    // Android 13+ 运行时通知权限（拒绝也不影响聊天）
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {}
    _ready = true;
  }

  static void _onResponse(NotificationResponse resp) {
    final convId = int.tryParse(resp.payload ?? '');
    if (convId != null) onOpenConversation?.call(convId);
  }

  static Future<void> showMessage({
    required String title,
    required String body,
    required int convId,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        convId, // 同会话的新消息覆盖旧通知，避免通知栏刷屏
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'messages',
            '新消息',
            channelDescription: '收到新消息时提醒',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
          windows: WindowsNotificationDetails(),
        ),
        payload: convId.toString(),
      );
    } catch (_) {}
  }
}
