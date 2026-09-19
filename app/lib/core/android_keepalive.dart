/// Android 前台服务（「后台保持连接」开关）：
/// 提升进程优先级防止系统杀后台，主 Isolate 的 WebSocket 得以在退后台后继续存活。
/// 任务处理器为空操作 —— 我们只需要前台服务带来的进程保活效果。
library;

import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void _foregroundEntry() {
  FlutterForegroundTask.setTaskHandler(_NoopHandler());
}

class _NoopHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

class AndroidKeepAlive {
  AndroidKeepAlive._();
  static bool _inited = false;

  static bool get supported => Platform.isAndroid;

  static void init() {
    if (!supported || _inited) return;
    _inited = true;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'keepalive',
        channelName: '保持在线',
        channelDescription: '保持与服务器的实时连接',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<void> setEnabled(bool on) async {
    if (!supported) return;
    init();
    try {
      if (on) {
        if (!await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.startService(
            serviceId: 256,
            notificationTitle: 'QuickConect',
            notificationText: '保持连接中 · 点按返回',
            callback: _foregroundEntry,
          );
        }
      } else {
        if (await FlutterForegroundTask.isRunningService) {
          await FlutterForegroundTask.stopService();
        }
      }
    } catch (_) {}
  }
}
