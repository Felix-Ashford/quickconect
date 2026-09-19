// ignore_for_file: avoid_print
/// 针对生产服务器的客户端诊断：复现「接收方下载图片」的完整代码路径，
/// 直接看是哪一层抛错（TLS / API / 媒体下载）。
///
/// 运行: flutter test test/prod_diag_test.dart
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/core/cert_pinning.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';

void main() {
  test('prod: 接收方加载会话并下载图片', () async {
    // 与 App 相同的证书锁定机制（main() 里做的事）
    PinningStore.accepted
        .add('e5b0e4e0bef2dafbcc71956e9df0780dc47d210638694b3615c15b52cda6d300');
    HttpOverrides.global = PinningOverrides();

    final s = Session(MemoryPrefs());
    await s.login(
      server: 'https://124.223.44.151:8443',
      username: 'test',
      password: '332599c3',
      deviceName: '诊断脚本',
      platform: 'test',
    );
    print('登录成功 user=${s.me!.name} ws=${s.wsState}');
    await s.openConversation(1);
    final msgs = s.msgs[1]!;
    print('消息数=${msgs.length} loaded=${s.loaded}');
    for (final m in msgs) {
      if (m.type == 'image') {
        final thumbId = m.payload['thumb_media_id'] as String?;
        final origId = m.payload['media_id'] as String?;
        print('-- seq${m.seq} thumb=$thumbId orig=$origId');
        try {
          final t = await s.mediaStore.download(thumbId!);
          print('   缩略图 OK ${t.length} bytes, PNG头=${t.take(4).toList()}');
        } catch (e) {
          print('   缩略图失败: $e');
        }
        try {
          final o = await s.mediaStore.download(origId!);
          print('   原图 OK ${o.length} bytes');
        } catch (e) {
          print('   原图失败: $e');
        }
      }
      if (m.type == 'file') {
        try {
          final f = await s.mediaStore.download(m.payload['media_id'] as String);
          print('   文件 ${m.payload['name']} OK ${f.length} bytes');
        } catch (e) {
          print('   文件失败: $e');
        }
      }
    }
    expect(s.me, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
