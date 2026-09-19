/// 会话状态中枢：登录态、名册、会话列表、消息、WebSocket 与断线对账的统一编排。
///
/// 数据流：
///  - 登录/恢复 → bootstrap（名册 + 会话列表）→ ensureWs（实时通道）
///  - WS 收到 message.new → 去重落内存、推进游标、更新未读；聊天页开着则自动已读
///  - 断线重连成功 → catchUp：按每会话游标增量补齐 + 刷新会话列表，保证不丢不重
///  - 发送 → 乐观插入（sending）→ 成功替换为服务器消息（幂等 client_msg_id）→ 失败标记可重试
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'media_store.dart';
import 'models.dart';
import 'prefs.dart';
import 'ws_client.dart';

class Session extends ChangeNotifier {
  final Prefs prefs;

  ApiClient? api;
  WsClient? _ws;
  WsState wsState = WsState.disconnected;

  User? me;
  List<User> users = [];
  DeviceInfo? device;
  final Map<int, Conversation> convs = {};
  final Map<int, List<Message>> msgs = {}; // convId → 按 seq 升序（pending 排末尾）
  final Set<int> loaded = {}; // 已完整加载过历史的会话
  final Map<int, int> lastSeq = {};
  bool booting = false;
  int? currentConvId; // ChatPage 进入/退出时维护

  /// 新消息通知钩子（main.dart 注入本地通知）；重连对账的旧消息不触发。
  void Function(Message m)? incomingNotifier;
  bool _catchingUp = false;

  MediaStore? _mediaStore;
  ApiClient? _mediaStoreFor;
  final Map<String, Map<String, dynamic>> _outboxPayload = {}; // cmid → 原始 payload（重试用）

  MediaStore get mediaStore {
    if (_mediaStore == null || _mediaStoreFor != api) {
      _mediaStoreFor = api;
      _mediaStore = MediaStore(api!);
    }
    return _mediaStore!;
  }

  Session(this.prefs);

  bool get loggedIn => api?.token != null && me != null;

  String get serverBase => prefs.getString('server_url') ?? '';

  /// 全部会话未读总数（图标角标用）。
  int get totalUnread => convs.values.fold(0, (s, c) => s + c.unread);

  /// 拉取当前设备信息（推送铃主题；恢复登录后必须调一次）。
  Future<void> fetchDevice() async {
    if (api == null) return;
    try {
      device = await api!.device();
    } catch (_) {}
  }

  // ---------- 登录 / 恢复 ----------

  Future<void> tryResume() async {
    final server = prefs.getString('server_url');
    final token = prefs.getString('token');
    if (server == null || token == null) return;
    api = ApiClient(base: server, token: token);
    try {
      me = await api!.me();
      await fetchDevice();
      await bootstrap();
      ensureWs();
    } on ApiException catch (e) {
      if (e.statusCode == 401) await _clearLogin();
      api = null;
      me = null;
    } catch (_) {
      // 网络不通：保留凭据，进入首页后可手动重试
    }
    notifyListeners();
  }

  Future<void> login({
    required String server,
    required String username,
    required String password,
    required String deviceName,
    String platform = 'unknown',
  }) async {
    final client = ApiClient(base: ApiClient.normalize(server));
    final (user, topic) =
        await client.login(username, password, deviceName, platform);
    me = user;
    api = client;
    device = DeviceInfo(
      id: 0, name: deviceName, platform: platform, pushTopic: topic,
    );
    await prefs.setString('server_url', client.base);
    await prefs.setString('token', client.token!);
    await prefs.setString('last_username', username);
    await bootstrap();
    ensureWs();
    notifyListeners();
  }

  Future<void> logout() async {
    _ws?.stop();
    _ws = null;
    try {
      await api?.logout();
    } catch (_) {}
    await _clearLogin();
    notifyListeners();
  }

  Future<void> _clearLogin() async {
    await prefs.remove('token');
    convs.clear();
    msgs.clear();
    loaded.clear();
    lastSeq.clear();
    users = [];
    me = null;
  }

  // ---------- 拉取 ----------

  Future<void> bootstrap() async {
    if (api == null) return;
    booting = true;
    notifyListeners();
    try {
      final results = await Future.wait([
        api!.users(),
        api!.conversations(),
      ]);
      users = results[0] as List<User>;
      final list = results[1] as List<Conversation>;
      convs
        ..clear()
        ..addEntries(list.map((c) => MapEntry(c.id, c)));
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  /// 与对方开私聊（幂等），返回会话 ID；新会话需刷新列表后才在首页可见。
  Future<int> openDM(int peerId) async {
    final convId = await api!.openDM(peerId);
    await refreshConversations();
    return convId;
  }

  Future<void> refreshConversations() async {
    if (api == null) return;
    try {
      final list = await api!.conversations();
      convs
        ..clear()
        ..addEntries(list.map((c) => MapEntry(c.id, c)));
      notifyListeners();
    } catch (_) {}
  }

  /// 打开聊天页：确保历史已完整加载（与本地已有的部分消息合并去重），并标记已读。
  Future<void> openConversation(int convId) async {
    if (api == null) return;
    if (!loaded.contains(convId)) {
      final list = await api!.messagesAfter(convId, 0);
      final local = msgs.putIfAbsent(convId, () => []);
      final known = local.map((m) => m.id).toSet();
      local.addAll(list.where((m) => !known.contains(m.id) && !m.isPending));
      _sort(local);
      loaded.add(convId);
      for (final m in list) {
        if (m.seq > (lastSeq[convId] ?? 0)) lastSeq[convId] = m.seq;
      }
      notifyListeners();
    }
    await markRead(convId);
  }

  Future<void> markRead(int convId) async {
    final seq = lastSeq[convId] ?? 0;
    final c = convs[convId];
    if (c != null && c.unread == 0 && (c.lastSeq <= seq)) return;
    try {
      if (seq > 0) await api!.markRead(convId, seq);
      if (convs[convId] != null) {
        convs[convId] = convs[convId]!.copyWith(unread: 0);
      }
      notifyListeners();
    } catch (_) {}
  }

  // ---------- WebSocket ----------

  void ensureWs() {
    final token = api?.token;
    if (token == null || _ws != null) return;
    final base = api!.base;
    final wsUrl =
        '${base.replaceFirst('http', 'ws')}/api/ws?token=$token';
    _ws = WsClient(
      wsUrl: wsUrl,
      onEvent: handleEvent,
      onState: (s) {
        final wasDisconnected = wsState == WsState.disconnected;
        wsState = s;
        if (s == WsState.connected && wasDisconnected) {
          unawaited(catchUp());
        }
        notifyListeners();
      },
    );
    _ws!.start();
  }

  void handleEvent(Map<String, dynamic> j) {
    if (j['type'] == 'message.new' && j['message'] is Map<String, dynamic>) {
      _applyIncoming(Message.fromJson(j['message'] as Map<String, dynamic>));
    }
  }

  void _applyIncoming(Message m) {
    // 只向已完整加载历史的会话追加详情；未加载的会话仅更新列表摘要，
    // 历史会在用户点开时经 openConversation 全量补齐。
    final list = loaded.contains(m.convId) ? msgs[m.convId] : null;
    if (list != null) {
      if (list.any((x) => x.id == m.id)) return; // WS 与对账可能重复推送
      list.add(m);
      _sort(list);
    }
    if (m.seq > (lastSeq[m.convId] ?? 0)) lastSeq[m.convId] = m.seq;

    final c = convs[m.convId];
    if (c == null) {
      unawaited(refreshConversations()); // 新会话（我还没拉到过）
    } else if (m.senderId == me?.id) {
      convs[m.convId] = c.copyWith(unread: c.unread); // 自己其他端发的，未读不变
    } else if (currentConvId == m.convId) {
      unawaited(markRead(m.convId)); // 正看着这个聊天 → 直接已读
      convs[m.convId] = Conversation(
        id: c.id, type: c.type, members: c.members,
        lastMessage: m, unread: 0, lastSeq: m.seq,
      );
    } else {
      convs[m.convId] = Conversation(
        id: c.id, type: c.type, members: c.members,
        lastMessage: m, unread: c.unread + 1, lastSeq: m.seq,
      );
    }
    if (!_catchingUp && m.senderId != me?.id && currentConvId != m.convId) {
      incomingNotifier?.call(m); // App 活着但不在该会话 → 本地通知
    }
    notifyListeners();
  }

  /// 断线重连后的对账：按游标补齐每个已加载会话，并刷新会话列表。
  Future<void> catchUp() async {
    if (api == null) return;
    _catchingUp = true;
    try {
      for (final convId in loaded.toList()) {
        try {
          final after = lastSeq[convId] ?? 0;
          final fresh = await api!.messagesAfter(convId, after);
          for (final m in fresh) {
            _applyIncoming(m);
          }
        } catch (_) {
          // 单个会话失败不影响其他；下次重连再补
        }
      }
      await refreshConversations();
    } finally {
      _catchingUp = false;
    }
  }

  // ---------- 发送 ----------

  Future<void> sendText(int convId, String text) =>
      _send(convId, 'text', {'text': text});

  /// 图片消息：原图 + 客户端生成的缩略图分别上传。
  Future<void> sendImage(
    int convId,
    Uint8List bytes, {
    int width = 0,
    int height = 0,
    String name = 'image.png',
  }) async {
    final thumb = await MediaStore.makeThumbnail(bytes);
    final origId = await mediaStore.upload(bytes,
        kind: 'image', mime: mimeFromName(name), name: name);
    final thumbId = identical(thumb, bytes)
        ? origId
        : await mediaStore.upload(thumb,
            kind: 'image', mime: 'image/png', name: 'thumb_$origId.png');
    await _send(convId, 'image',
        {'media_id': origId, 'thumb_media_id': thumbId, 'w': width, 'h': height});
  }

  /// 文件消息。
  Future<void> sendFile(int convId, Uint8List bytes, String name) async {
    final id = await mediaStore.upload(bytes,
        kind: 'file', mime: mimeFromName(name), name: name);
    await _send(convId, 'file', {'media_id': id, 'name': name, 'size': bytes.length});
  }

  /// 语音消息（录制完成后调用；测试可直接传字节）。
  Future<void> sendVoice(
    int convId,
    Uint8List bytes,
    int durationMs, {
    String ext = 'm4a',
  }) async {
    final id = await mediaStore.upload(bytes,
        kind: 'voice',
        mime: ext == 'wav' ? 'audio/wav' : 'audio/mp4',
        name: 'voice.$ext');
    await _send(convId, 'voice', {'media_id': id, 'duration_ms': durationMs, 'ext': ext});
  }

  /// 表情贴纸（图片上传后引用；渲染时不带气泡背景）。
  Future<void> sendSticker(
    int convId,
    Uint8List bytes, {
    required String packId,
    required String stickerId,
  }) async {
    final id = await mediaStore.upload(bytes,
        kind: 'sticker', mime: 'image/png', name: '$stickerId.png');
    await _send(convId, 'sticker',
        {'media_id': id, 'pack_id': packId, 'sticker_id': stickerId});
  }

  Future<void> retry(Message m) async {
    if (!m.isPending) return;
    m.status = MsgStatus.sending;
    notifyListeners();
    await _deliver(
      m.convId,
      m.type,
      _outboxPayload[m.clientMsgId] ?? m.payload,
      m.clientMsgId,
    );
  }

  Future<void> _send(
    int convId,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final cmid = _genId();
    _outboxPayload[cmid] = payload;
    final pending = Message.pending(
      convId: convId,
      senderId: me!.id,
      senderName: me!.displayName,
      type: type,
      payload: payload,
      clientMsgId: cmid,
    );
    final list = msgs.putIfAbsent(convId, () => []);
    list.add(pending);
    _sort(list);
    notifyListeners();
    await _deliver(convId, type, payload, cmid);
  }

  Future<void> _deliver(
    int convId,
    String type,
    Map<String, dynamic> payload,
    String cmid,
  ) async {
    try {
      final m = await api!.send(convId, cmid, type, payload);
      _replacePending(cmid, m);
      if (m.seq > (lastSeq[convId] ?? 0)) lastSeq[convId] = m.seq;
      _outboxPayload.remove(cmid);
      notifyListeners();
      if (currentConvId == convId) unawaited(markRead(convId));
    } on ApiException {
      _failPending(cmid);
      notifyListeners();
    } catch (_) {
      _failPending(cmid);
      notifyListeners();
    }
  }

  void _replacePending(String cmid, Message serverMsg) {
    final list = msgs[serverMsg.convId];
    if (list == null) return;
    // 服务端先走 WS 推送、后回 HTTP 响应：WS 事件可能已把同一条消息插入列表，
    // 替换占位消息前必须按 id 去重，否则发送方看到两条一模一样的消息。
    list.removeWhere((x) => x.id == serverMsg.id && !x.isPending);
    final i = list.indexWhere((x) => x.clientMsgId == cmid && x.isPending);
    if (i >= 0) {
      list[i] = serverMsg;
    } else if (!list.any((x) => x.id == serverMsg.id)) {
      list.add(serverMsg);
    }
    _sort(list);
  }

  void _failPending(String cmid) {
    for (final list in msgs.values) {
      for (final m in list) {
        if (m.clientMsgId == cmid && m.isPending) {
          m.status = MsgStatus.failed;
        }
      }
    }
  }

  // ---------- 工具 ----------

  void _sort(List<Message> list) {
    list.sort((a, b) {
      final sa = a.isPending ? 1 << 40 : a.seq; // pending 永远排最后
      final sb = b.isPending ? 1 << 40 : b.seq;
      return sa.compareTo(sb);
    });
  }

  String _genId() {
    final rnd = Random.secure();
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
    final r = List.generate(8, (_) => rnd.nextInt(1 << 32).toRadixString(16)).join();
    return (ts + r).replaceAll('-', '').substring(0, 32);
  }

  /// 仅测试用：直接驱动占位替换逻辑（回归「WS 先于 HTTP 到达」的去重）。
  @visibleForTesting
  void debugReplacePending(String cmid, Message serverMsg) =>
      _replacePending(cmid, serverMsg);

  /// 会话列表按最新消息时间倒序。
  List<Conversation> sortedConvs() {
    final l = convs.values.toList();
    l.sort((a, b) {
      final ta = a.lastMessage?.createdAt ?? 0;
      final tb = b.lastMessage?.createdAt ?? 0;
      return tb.compareTo(ta);
    });
    return l;
  }
}
