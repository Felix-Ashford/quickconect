/// 客户端端到端测试：真实启动本仓库的 Go 服务端进程，
/// 两个 Session（两个"设备"）登录、开私聊、实时互发消息、对账与已读。
///
/// 前置条件：已构建 ../dist/quickconect-server.exe（见 README 构建命令）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';
import 'package:quickconect_app/core/ws_client.dart';

Future<int> _freePort() async {
  final s = await ServerSocket.bind('127.0.0.1', 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<void> _waitFor(Future<bool> Function() check,
    {String what = 'condition', int seconds = 10}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('等待超时: $what');
}

void main() {
  // 注意：不初始化 TestWidgetsFlutterBinding —— 它会拦截全部真实网络请求；
  // 本测试是纯 Dart 集成测试（真实进程 + 真实 socket）。
  test('客户端端到端：双账号实时互发、已读、对账、幂等', () async {
    final exe = File('../dist/quickconect-server.exe');
    expect(exe.existsSync(), isTrue,
        reason: '先构建服务端: go build -o ../dist/quickconect-server.exe .');

    // 1. 启动服务端（随机空闲端口、无 TLS、无 ntfy）
    final port = await _freePort();
    final dir = await Directory.systemTemp.createTemp('qc_e2e_');
    final cfg = File('${dir.path}/config.yaml');
    await cfg.writeAsString('''
listen: "127.0.0.1:$port"
tls_enabled: false
db_path: ${dir.path.replaceAll('\\', '/')}/test.db
media_path: ${dir.path.replaceAll('\\', '/')}/media
media_max_mb: 10
ntfy:
  enabled: false
''');
    final server = await Process.start(exe.path, ['serve', '-config', cfg.path]);
    addTearDown(() async {
      server.kill();
      await server.exitCode; // 等进程真正退出，避免 Windows 文件占用导致删目录失败
      for (var i = 0; i < 5; i++) {
        try {
          await dir.delete(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    });

    // 等健康检查就绪
    final base = 'http://127.0.0.1:$port';
    await _waitFor(() async {
      try {
        final r = await http.get(Uri.parse('$base/healthz')).timeout(const Duration(seconds: 1));
        return r.statusCode == 200;
      } catch (_) {
        return false;
      }
    }, what: '服务端启动');

    // 2. 建号
    for (final u in [
      ['alice', 'Alice'],
      ['bob', 'Bob'],
    ]) {
      final r = await Process.run(exe.path, [
        'adduser', '-config', cfg.path,
        '-name', u[0], '-display', u[1], '-password', 'pw-${u[0]}',
      ]);
      expect(r.exitCode, 0, reason: 'adduser ${u[0]}: ${r.stderr}');
    }

    // 3. 两个客户端登录（登录内部完成 bootstrap + WS 连接）
    final alice = Session(MemoryPrefs());
    final bob = Session(MemoryPrefs());
    await alice.login(
      server: base, username: 'alice', password: 'pw-alice',
      deviceName: '测试机A', platform: 'test',
    );
    await bob.login(
      server: base, username: 'bob', password: 'pw-bob',
      deviceName: '测试机B', platform: 'test',
    );
    expect(alice.me!.name, 'alice');
    expect(bob.users.length, 2);
    // 推送铃主题随登录下发（设置页的订阅二维码数据源）
    expect(alice.device, isNotNull);
    expect(alice.device!.pushTopic, startsWith('qc_'));
    expect(alice.device!.subscribeUrl, contains('https://ntfy.sh/qc_'));

    // 4. alice 与 bob 开私聊
    final bobUser = alice.users.firstWhere((u) => u.name == 'bob');
    final convId = await alice.openDM(bobUser.id);
    expect(convId, greaterThan(0));

    // 5. bob 的 WS 连接就绪
    await _waitFor(() async => bob.wsState == WsState.connected, what: 'bob WS 连接');

    // 6. alice 发消息 → bob 实时收到（bob 未打开过该会话：只更新列表摘要与未读）
    await alice.sendText(convId, '你好，bob！');
    await _waitFor(() async =>
        bob.convs[convId]?.lastMessage?.text == '你好，bob！', what: 'bob 收到消息');
    expect(bob.convs[convId], isNotNull, reason: '未知会话应触发列表刷新');
    expect(bob.convs[convId]!.unread, 1);

    // 7. bob 回复 → alice 收到（alice 未打开聊天，未读 +1）
    await bob.sendText(convId, '你好，alice！');
    await _waitFor(() async =>
        alice.convs[convId]?.lastMessage?.text == '你好，alice！', what: 'alice 列表预览');
    expect(alice.convs[convId]!.unread, 1);

    // 8. alice 打开聊天 → 加载全部历史并自动已读
    alice.currentConvId = convId;
    await alice.openConversation(convId);
    expect(alice.msgs[convId]!.length, 2);
    await _waitFor(() async => alice.convs[convId]!.unread == 0, what: 'alice 已读');
    alice.currentConvId = null;

    // 9. bob 打开聊天 → 已读归零
    bob.currentConvId = convId;
    await bob.openConversation(convId);
    expect(bob.msgs[convId]!.length, 2);
    await _waitFor(() async => bob.convs[convId]!.unread == 0, what: 'bob 已读');
    bob.currentConvId = null;

    // 10. 断线对账：WS 实时收到后再手动 catchUp，验证不丢不重
    final before = bob.msgs[convId]!.length;
    await alice.sendText(convId, '对账测试消息');
    await _waitFor(() async => bob.msgs[convId]?.length == before + 1,
        what: 'WS 实时收到第三条');
    await bob.catchUp();
    expect(bob.msgs[convId]!.length, 3);
    expect(bob.msgs[convId]!.map((m) => m.id).toSet().length, 3);

    // 11. 发送幂等：同一 client_msg_id 重发 → 服务器返回同一条；客户端对账去重
    final m1 = await alice.api!.send(convId, 'fixed-id-123', 'text', {'text': '幂等重发'});
    final m2 = await alice.api!.send(convId, 'fixed-id-123', 'text', {'text': '幂等重发'});
    expect(m2.id, m1.id, reason: '重发应返回同一条消息');
    await bob.catchUp();
    expect(bob.msgs[convId]!.where((m) => m.id == m1.id).length, 1,
        reason: '客户端应只保留一条');

    // 12. 图片消息：原图+缩略图上传，bob 收到并下载原图字节一致
    final imageBytes =
        Uint8List.fromList(List.generate(2048, (i) => i % 256));
    await alice.sendImage(convId, imageBytes, width: 64, height: 64, name: 'pic.png');
    await _waitFor(() async =>
        bob.convs[convId]?.lastMessage?.type == 'image', what: 'bob 收到图片消息');
    final imgMsg = bob.convs[convId]!.lastMessage!;
    final origId = imgMsg.payload['media_id'] as String;
    expect(imgMsg.payload['thumb_media_id'], isNotNull);
    expect(await bob.mediaStore.download(origId), imageBytes,
        reason: '原图字节应一致');

    // 13. 文件消息
    final docBytes = Uint8List.fromList('这是文件内容'.codeUnits);
    await alice.sendFile(convId, docBytes, '说明.txt');
    await _waitFor(() async =>
        bob.convs[convId]?.lastMessage?.type == 'file', what: 'bob 收到文件消息');
    final fileMsg = bob.convs[convId]!.lastMessage!;
    expect(fileMsg.payload['name'], '说明.txt');
    expect(await bob.mediaStore.download(fileMsg.payload['media_id'] as String),
        docBytes);

    // 14. 语音消息（直接传字节，不走录音）
    final voiceBytes = Uint8List.fromList(List.generate(512, (i) => i));
    await alice.sendVoice(convId, voiceBytes, 3200, ext: 'm4a');
    await _waitFor(() async =>
        bob.convs[convId]?.lastMessage?.type == 'voice', what: 'bob 收到语音消息');
    final voiceMsg = bob.convs[convId]!.lastMessage!;
    expect(voiceMsg.payload['duration_ms'], 3200);
    expect(await bob.mediaStore.download(voiceMsg.payload['media_id'] as String),
        voiceBytes);

    // 15. 回归：WS 事件先于 HTTP 响应到达时，发送方不得出现重复消息
    final raceMsg =
        await alice.api!.send(convId, 'race-id-1', 'text', {'text': '竞态去重'});
    final list = alice.msgs[convId]!;
    final beforeRace = list.length;
    list.add(Message.pending(
      convId: convId, senderId: alice.me!.id, senderName: 'Alice',
      type: 'text', payload: {'text': '竞态去重'}, clientMsgId: 'race-id-1',
    )); // 发送方乐观插入
    list.add(raceMsg); // WS 事件先到，直接插入
    alice.debugReplacePending('race-id-1', raceMsg); // HTTP 响应后到
    expect(list.length, beforeRace + 1, reason: '占位被替换、WS 副本被去重后总数应不变');
    expect(list.where((m) => m.id == raceMsg.id).length, 1, reason: '只保留一份');
    expect(list.any((m) => m.isPending), isFalse, reason: '不应残留占位消息');
  });
}
