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
import 'local_chat_store.dart';
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
  List<AutomationIdentity> automationIdentities = [];
  DeviceInfo? device;
  final Map<int, Conversation> convs = {};
  final Map<int, List<Message>> msgs = {}; // convId → 按 seq 升序（pending 排末尾）
  final Set<int> loaded = {}; // 已完整加载过历史的会话
  final Map<int, int> lastSeq = {};
  // Revision cursors stay in memory: after a restart we replay revisions against
  // the local snapshot, so a cursor can never get ahead of data saved to disk.
  final Map<int, int> _lastRevision = {};
  final Map<int, Future<void>> _revisionSyncs = {};
  int _syncGeneration = 0;
  bool booting = false;
  int? currentConvId; // ChatPage 进入/退出时维护
  int threadUpdateVersion = 0;

  /// 新消息通知钩子（main.dart 注入本地通知）；重连对账的旧消息不触发。
  void Function(Message m)? incomingNotifier;
  bool _catchingUp = false;

  MediaStore? _mediaStore;
  ApiClient? _mediaStoreFor;
  LocalChatStore? _localChatStore;
  String? _localChatKey;
  Future<void> _persistQueue = Future<void>.value();
  Future<void>? _restoreFuture;
  bool _clearingLocalHistory = false;
  final Map<String, Map<String, dynamic>> _outboxPayload =
      {}; // cmid → 原始 payload（重试用）
  final Set<int> _deletedAutomationConversations = {};

  bool automationConversationDeleted(int conversationId) =>
      _deletedAutomationConversations.contains(conversationId);

  MediaStore get mediaStore {
    if (_mediaStore == null || _mediaStoreFor != api) {
      _mediaStoreFor = api;
      _mediaStore = MediaStore(api!);
    }
    _mediaStore!.persistentCacheEnabled =
        prefs.getBool('local_chat_enabled') ?? true;
    return _mediaStore!;
  }

  Session(this.prefs);

  bool get loggedIn => api?.token != null && me != null;

  String get serverBase => prefs.getString('server_url') ?? '';

  LocalChatStore? get _chatStore {
    final username = me?.name ?? prefs.getString('last_username');
    final server = api?.base ?? prefs.getString('server_url');
    if (username == null || server == null) return null;
    final key = '$server|$username';
    if (_localChatKey != key) {
      _localChatKey = key;
      _localChatStore = LocalChatStore(server: server, username: username);
      _restoreFuture = null;
    }
    return _localChatStore;
  }

  Future<void> _restoreLocalChats() {
    final store = _chatStore;
    if (store == null) return Future<void>.value();
    return _restoreFuture ??= store
        .load()
        .then((snapshot) {
          if (_localChatStore != store) return;
          convs.addEntries(
            snapshot.conversations.entries.where(
              (e) =>
                  !convs.containsKey(e.key) &&
                  !_deletedAutomationConversations.contains(e.key),
            ),
          );
          for (final entry in snapshot.messages.entries) {
            if (_deletedAutomationConversations.contains(entry.key)) continue;
            final current = msgs.putIfAbsent(entry.key, () => []);
            final known = current.map((m) => m.id).toSet();
            current.addAll(entry.value.where((m) => !known.contains(m.id)));
            _sort(current);
            final maxSeq = current
                .where((m) => !m.isPending)
                .fold<int>(0, (max, m) => m.seq > max ? m.seq : max);
            if (maxSeq > (lastSeq[entry.key] ?? 0)) lastSeq[entry.key] = maxSeq;
          }
          notifyListeners();
        })
        .catchError((Object _) {
          // 测试环境或平台存储不可用时，聊天同步仍应正常工作。
        });
  }

  void _persistLocalChats() {
    if (!localChatStorageEnabled || _clearingLocalHistory) return;
    final store = _chatStore;
    if (store == null) return;
    final snapshot = <int, List<Message>>{
      for (final entry in msgs.entries)
        entry.key: entry.value
            .where((m) => !m.isPending)
            .toList(growable: false),
    };
    final conversations = Map<int, Conversation>.from(convs);
    _persistQueue = _persistQueue
        .catchError((Object _) {})
        .then((_) => store.save(snapshot, conversations))
        .catchError((Object _) {});
  }

  Future<int> localMessageCount() async {
    try {
      return await _chatStore?.messageCount() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<int> localMediaCacheSize() async {
    if (prefs.getBool('local_chat_enabled') == false || api == null) return 0;
    try {
      return await mediaStore.persistentCacheSize();
    } catch (_) {
      return 0;
    }
  }

  bool get localChatStorageEnabled =>
      prefs.getBool('local_chat_enabled') ?? true;

  Future<void> setLocalChatStorageEnabled(bool enabled) async {
    await prefs.setBool('local_chat_enabled', enabled);
    if (_mediaStore != null) _mediaStore!.persistentCacheEnabled = enabled;
    notifyListeners();
  }

  Future<void> updateMyAvatar(
    Uint8List bytes, {
    String name = 'avatar.jpg',
  }) async {
    if (api == null) return;
    final mediaId = await api!.uploadAvatar(bytes, name: name);
    me = await api!.setAvatar(mediaId);
    users = [for (final user in users) user.id == me!.id ? me! : user];
    convs.updateAll(
      (id, conv) => Conversation(
        id: conv.id,
        type: conv.type,
        members: [
          for (final user in conv.members) user.id == me!.id ? me! : user,
        ],
        lastMessage: conv.lastMessage,
        unread: conv.unread,
        lastSeq: conv.lastSeq,
      ),
    );
    notifyListeners();
  }

  Future<void> clearLocalChatHistory() async {
    final store = _chatStore;
    if (store == null) return;
    _clearingLocalHistory = true;
    try {
      await _persistQueue;
      try {
        await store.clear();
      } catch (_) {}
      try {
        await _mediaStore?.clearPersistentCache();
      } catch (_) {}
      msgs.clear();
      loaded.clear();
      lastSeq.clear();
      _lastRevision.clear();
      _syncGeneration++;
      _revisionSyncs.clear();
      _deletedAutomationConversations.clear();
      notifyListeners();
    } finally {
      _clearingLocalHistory = false;
    }
  }

  Future<void> clearLocalMediaCache() async {
    try {
      await _mediaStore?.clearPersistentCache();
    } catch (_) {}
    notifyListeners();
  }

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
    final cachedId = int.tryParse(prefs.getString('cached_user_id') ?? '');
    final cachedName = prefs.getString('cached_user_name');
    if (cachedId != null && cachedName != null) {
      me = User(
        id: cachedId,
        name: cachedName,
        displayName: prefs.getString('cached_display_name') ?? cachedName,
      );
    }
    await _restoreLocalChats();
    try {
      me = await api!.me();
      await _cacheUser(me!);
      await _restoreLocalChats();
      await fetchDevice();
      await bootstrap();
      ensureWs();
    } on ApiException catch (e) {
      if (e.statusCode == 401) await _clearLogin();
      if (e.statusCode == 401) {
        api = null;
        me = null;
      }
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
    final (user, topic) = await client.login(
      username,
      password,
      deviceName,
      platform,
    );
    final nextLocalKey = '${client.base}|${user.name}';
    if (_localChatKey != null && _localChatKey != nextLocalKey) {
      convs.clear();
      msgs.clear();
      loaded.clear();
      lastSeq.clear();
      _lastRevision.clear();
      _syncGeneration++;
      _revisionSyncs.clear();
      _deletedAutomationConversations.clear();
    }
    me = user;
    await _cacheUser(user);
    api = client;
    device = DeviceInfo(
      id: 0,
      name: deviceName,
      platform: platform,
      pushTopic: topic,
    );
    await prefs.setString('server_url', client.base);
    await prefs.setString('token', client.token!);
    await prefs.setString('last_username', username);
    await _restoreLocalChats();
    await bootstrap();
    ensureWs();
    notifyListeners();
  }

  Future<void> _cacheUser(User user) async {
    await prefs.setString('cached_user_id', '${user.id}');
    await prefs.setString('cached_user_name', user.name);
    await prefs.setString('cached_display_name', user.displayName);
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
    _lastRevision.clear();
    _syncGeneration++;
    _revisionSyncs.clear();
    _deletedAutomationConversations.clear();
    automationIdentities = [];
    users = [];
    me = null;
    api = null;
  }

  // ---------- 拉取 ----------

  Future<void> bootstrap() async {
    if (api == null) return;
    booting = true;
    notifyListeners();
    try {
      await refreshDirectory();
    } finally {
      booting = false;
      notifyListeners();
    }
  }

  /// 与对方开私聊（幂等），返回会话 ID；新会话需刷新列表后才在首页可见。
  Future<int> openDM(int peerId) async {
    final client = api!;
    final generation = _syncGeneration;
    final convId = await client.openDM(peerId);
    if (api != client || generation != _syncGeneration) {
      throw StateError('账号已经切换，请重新选择联系人');
    }
    await refreshConversations();
    if (api != client || generation != _syncGeneration) {
      throw StateError('账号已经切换，请重新选择联系人');
    }
    return convId;
  }

  String? _automationThreadKey(String identity) {
    final client = api;
    final user = me;
    if (client == null || user == null) return null;
    return 'automation_last_thread:${Uri.encodeComponent(client.base)}:${user.id}:${Uri.encodeComponent(identity)}';
  }

  Future<void> rememberAutomationThread(
    String identity,
    int conversationId,
  ) async {
    final key = _automationThreadKey(identity);
    if (key != null) await prefs.setString(key, '$conversationId');
  }

  int? lastAutomationThreadId(String identity) {
    final key = _automationThreadKey(identity);
    return key == null ? null : int.tryParse(prefs.getString(key) ?? '');
  }

  /// An automation contact opens the last selected isolated thread for this user.
  Future<int> openAutomation(AutomationIdentity identity) async {
    final client = api!;
    final generation = _syncGeneration;
    final threads = await client.automationThreads(identity.id);
    if (api != client || generation != _syncGeneration) {
      throw StateError('账号已经切换，请重新选择联系人');
    }
    final remembered = lastAutomationThreadId(identity.id);
    final thread =
        threads
            .where((item) => item.conversationId == remembered)
            .firstOrNull ??
        (threads.isEmpty
            ? await client.createAutomationThread(identity.id)
            : threads.first);
    if (api != client || generation != _syncGeneration) {
      throw StateError('账号已经切换，请重新选择联系人');
    }
    await refreshDirectory();
    if (api != client || generation != _syncGeneration) {
      throw StateError('账号已经切换，请重新选择联系人');
    }
    await rememberAutomationThread(identity.id, thread.conversationId);
    return thread.conversationId;
  }

  Future<void> refreshConversations() async {
    try {
      await refreshDirectory();
    } catch (_) {}
  }

  Future<void> deleteAutomationThread(
    AutomationIdentity identity,
    int conversationId,
  ) async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return;
    await client.deleteAutomationThread(identity.id, conversationId);
    if (api != client || _syncGeneration != generation) return;
    if (lastAutomationThreadId(identity.id) == conversationId) {
      final key = _automationThreadKey(identity.id);
      if (key != null) await prefs.remove(key);
    }
    _removeAutomationConversation(conversationId);
    await _persistQueue;
  }

  void _removeAutomationConversation(int conversationId) {
    _deletedAutomationConversations.add(conversationId);
    convs.remove(conversationId);
    msgs.remove(conversationId);
    loaded.remove(conversationId);
    lastSeq.remove(conversationId);
    _lastRevision.remove(conversationId);
    _persistLocalChats();
    notifyListeners();
  }

  Future<void> refreshDirectory() async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return;
    final results = await Future.wait<Object>([
      client.users(),
      client.conversations(),
      _fetchAutomations(client),
    ]);
    if (api != client || _syncGeneration != generation) return;
    users = results[0] as List<User>;
    automationIdentities = results[2] as List<AutomationIdentity>;
    final list = results[1] as List<Conversation>;
    convs
      ..clear()
      ..addEntries(
        list
            .where((c) => !_deletedAutomationConversations.contains(c.id))
            .map((c) => MapEntry(c.id, c)),
      );
    _persistLocalChats();
    notifyListeners();
  }

  Future<List<AutomationIdentity>> _fetchAutomations(ApiClient client) async {
    try {
      return await client.automationIdentities();
    } on ApiException catch (e) {
      // Old servers can still be used for plain chat. Other failures must be
      // surfaced instead of silently removing contacts from the directory.
      if (e.statusCode == 404) return [];
      rethrow;
    }
  }

  /// 打开聊天页：确保历史已完整加载（与本地已有的部分消息合并去重），并标记已读。
  Future<void> openConversation(int convId) async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return;
    await _restoreLocalChats();
    if (api != client ||
        _syncGeneration != generation ||
        _deletedAutomationConversations.contains(convId)) {
      return;
    }
    if (!loaded.contains(convId)) {
      final list = <Message>[];
      var complete = false;
      try {
        var afterSeq = 0;
        while (true) {
          final batch = await client.messagesAfter(
            convId,
            afterSeq,
            limit: 200,
          );
          if (api != client ||
              _syncGeneration != generation ||
              _deletedAutomationConversations.contains(convId)) {
            return;
          }
          if (batch.isEmpty) {
            complete = true;
            break;
          }
          list.addAll(batch);
          afterSeq = batch.last.seq;
          if (batch.length < 200) {
            complete = true;
            break;
          }
        }
      } catch (_) {
        // 离线时使用已恢复的本地记录，网络恢复后由 catchUp 补齐。
      }
      if (api != client ||
          _syncGeneration != generation ||
          _deletedAutomationConversations.contains(convId)) {
        return;
      }
      final local = msgs.putIfAbsent(convId, () => []);
      for (final message in list.where((m) => !m.isPending)) {
        final index = local.indexWhere((m) => m.id == message.id);
        if (index < 0) {
          local.add(message);
        } else if (_revisionOf(message) >= _revisionOf(local[index])) {
          local[index] = message;
        }
      }
      _sort(local);
      if (complete) loaded.add(convId);
      for (final m in list) {
        if (m.seq > (lastSeq[convId] ?? 0)) lastSeq[convId] = m.seq;
      }
      _persistLocalChats();
      notifyListeners();
    }
    await _syncRevisions(convId);
    if (api != client || _syncGeneration != generation) return;
    await markRead(convId);
  }

  Future<void> markRead(int convId) async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return;
    final seq = lastSeq[convId] ?? 0;
    final c = convs[convId];
    if (c != null && c.unread == 0 && (c.lastSeq <= seq)) return;
    try {
      if (seq > 0) await client.markRead(convId, seq);
      if (api != client || _syncGeneration != generation) return;
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
    final wsUrl = '${base.replaceFirst('http', 'ws')}/api/ws?token=$token';
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
    if (j['type'] == 'automation.thread.deleted') {
      final convId = (j['conversation_id'] as num?)?.toInt();
      if (convId != null) {
        _removeAutomationConversation(convId);
      }
      return;
    }
    if (j['type'] == 'automation.thread.updated') {
      threadUpdateVersion++;
      notifyListeners();
    }
    if (j['type'] == 'message.new' && j['message'] is Map<String, dynamic>) {
      _applyIncoming(Message.fromJson(j['message'] as Map<String, dynamic>));
    }
    if (j['type'] == 'message.updated' &&
        j['message'] is Map<String, dynamic>) {
      _applyRevision(Message.fromJson(j['message'] as Map<String, dynamic>));
    }
  }

  int _revisionOf(Message message) => message.revision;

  void _applyRevision(Message message) {
    if (_deletedAutomationConversations.contains(message.convId)) return;
    final list = msgs.putIfAbsent(message.convId, () => []);
    final index = list.indexWhere((m) => m.id == message.id);
    if (index >= 0 && _revisionOf(list[index]) > _revisionOf(message)) return;
    if (index >= 0) {
      list[index] = message;
    } else {
      list.add(message);
      _sort(list);
    }
    final conv = convs[message.convId];
    if (conv != null && conv.lastMessage?.id == message.id) {
      convs[message.convId] = Conversation(
        id: conv.id,
        type: conv.type,
        members: conv.members,
        lastMessage: message,
        unread: conv.unread,
        lastSeq: conv.lastSeq,
      );
    }
    notifyListeners();
    _persistLocalChats();
  }

  Future<void> _syncRevisions(int convId) {
    final generation = _syncGeneration;
    return _revisionSyncs[convId] ??= _fetchRevisions(convId).whenComplete(() {
      if (_syncGeneration == generation) _revisionSyncs.remove(convId);
    });
  }

  Future<void> _fetchRevisions(int convId) async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return;
    try {
      var cursor = _lastRevision[convId] ?? 0;
      while (true) {
        final batch = await client.messageChanges(convId, cursor);
        if (api != client || _syncGeneration != generation) return;
        for (final raw in (batch['messages'] as List? ?? const [])) {
          _applyRevision(
            Message.fromJson(Map<String, dynamic>.from(raw as Map)),
          );
        }
        final next = (batch['next_revision'] as num?)?.toInt() ?? cursor;
        _lastRevision[convId] = next;
        if (batch['has_more'] != true || next <= cursor) break;
        cursor = next;
      }
    } catch (_) {
      // Keep the last successful cursor and retry on open/reconnect.
    }
  }

  void _applyIncoming(Message m) {
    if (_deletedAutomationConversations.contains(m.convId)) return;
    // 只向已完整加载历史的会话追加详情；未加载的会话仅更新列表摘要，
    // 历史会在用户点开时经 openConversation 全量补齐。
    final list = msgs.putIfAbsent(m.convId, () => []);
    final existing = list.where((x) => x.id == m.id).firstOrNull;
    if (existing != null) {
      if (m.revision > existing.revision) _applyRevision(m);
      return;
    } // WS 与对账可能重复推送
    list.add(m);
    _sort(list);
    if (m.seq > (lastSeq[m.convId] ?? 0)) lastSeq[m.convId] = m.seq;

    final c = convs[m.convId];
    if (c == null) {
      unawaited(refreshConversations()); // 新会话（我还没拉到过）
    } else if (m.senderId == me?.id) {
      convs[m.convId] = Conversation(
        id: c.id,
        type: c.type,
        members: c.members,
        lastMessage: m,
        unread: c.unread,
        lastSeq: m.seq,
      ); // 自己其他端发的，未读不变
    } else if (currentConvId == m.convId) {
      unawaited(markRead(m.convId)); // 正看着这个聊天 → 直接已读
      convs[m.convId] = Conversation(
        id: c.id,
        type: c.type,
        members: c.members,
        lastMessage: m,
        unread: 0,
        lastSeq: m.seq,
      );
    } else {
      convs[m.convId] = Conversation(
        id: c.id,
        type: c.type,
        members: c.members,
        lastMessage: m,
        unread: c.unread + 1,
        lastSeq: m.seq,
      );
    }
    if (!_catchingUp && m.senderId != me?.id && currentConvId != m.convId) {
      incomingNotifier?.call(m); // App 活着但不在该会话 → 本地通知
    }
    notifyListeners();
    _persistLocalChats();
  }

  /// 断线重连后的对账：按游标补齐每个已加载会话，并刷新会话列表。
  Future<void> catchUp() async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return;
    _catchingUp = true;
    try {
      for (final convId in loaded.toList()) {
        try {
          var after = lastSeq[convId] ?? 0;
          while (true) {
            final fresh = await client.messagesAfter(convId, after, limit: 200);
            if (api != client || _syncGeneration != generation) return;
            for (final m in fresh) {
              _applyIncoming(m);
            }
            if (fresh.length < 200 || fresh.last.seq <= after) break;
            after = fresh.last.seq;
          }
          await _syncRevisions(convId);
          if (api != client || _syncGeneration != generation) return;
        } catch (_) {
          // 单个会话失败不影响其他；下次重连再补
        }
      }
      await refreshConversations();
      if (api != client || _syncGeneration != generation) return;
      threadUpdateVersion++;
      notifyListeners();
      _persistLocalChats();
    } finally {
      if (_syncGeneration == generation) _catchingUp = false;
    }
  }

  // ---------- 发送 ----------

  Future<void> editMessage(Message message, String text) async {
    if (message.senderId != me?.id ||
        message.isPending ||
        message.isRetracted) {
      throw StateError('只能修改自己已发送且未撤回的消息');
    }
    final client = api!;
    final generation = _syncGeneration;
    final edited = await client.editMessage(message, text);
    if (api != client || _syncGeneration != generation) return;
    _applyRevision(edited);
  }

  Future<void> retractMessage(Message message) async {
    if (message.senderId != me?.id ||
        message.isPending ||
        message.isRetracted) {
      throw StateError('只能撤回自己已发送的消息');
    }
    final client = api!;
    final generation = _syncGeneration;
    final retracted = await client.retractMessage(message);
    if (api != client || _syncGeneration != generation) return;
    _applyRevision(retracted);
  }

  Future<Message> regenerateMessage(String identity, Message message) async {
    final client = api!;
    final generation = _syncGeneration;
    final reply = await client.regenerateMessage(identity, message, _genId());
    if (api != client || _syncGeneration != generation) {
      throw StateError('账号已经切换，请在当前账号重新操作');
    }
    _applyIncoming(reply);
    return reply;
  }

  Future<void> deleteExcludedMessage(String identity, Message message) async {
    final client = api!;
    final generation = _syncGeneration;
    final deleted = await client.deleteExcludedMessage(identity, message);
    if (api == client && generation == _syncGeneration) _applyRevision(deleted);
  }

  Future<void> sendText(
    int convId,
    String text, {
    String format = 'markdown',
    int formatVersion = 1,
  }) => _send(convId, 'text', {
    'text': text,
    'format': format,
    'format_version': formatVersion,
  });

  Future<Message?> invokeAutomation(
    int convId,
    String identity,
    String prompt, {
    String model = '',
  }) async {
    final client = api;
    final generation = _syncGeneration;
    if (client == null) return null;
    final message = await client.invokeAutomation(
      identity,
      convId,
      _genId(),
      prompt,
      model: model,
    );
    if (api != client || _syncGeneration != generation) return null;
    _applyIncoming(message);
    return message;
  }

  /// 图片消息：原图 + 客户端生成的缩略图分别上传。
  Future<void> sendImage(
    int convId,
    Uint8List bytes, {
    int width = 0,
    int height = 0,
    String name = 'image.png',
  }) async {
    final thumb = await MediaStore.makeThumbnail(bytes);
    final origId = await mediaStore.upload(
      bytes,
      kind: 'image',
      mime: mimeFromName(name),
      name: name,
    );
    final thumbId = identical(thumb, bytes)
        ? origId
        : await mediaStore.upload(
            thumb,
            kind: 'image',
            mime: 'image/png',
            name: 'thumb_$origId.png',
          );
    await _send(convId, 'image', {
      'media_id': origId,
      'thumb_media_id': thumbId,
      'w': width,
      'h': height,
    });
  }

  /// 文件消息。
  Future<void> sendFile(int convId, Uint8List bytes, String name) async {
    final id = await mediaStore.upload(
      bytes,
      kind: 'file',
      mime: mimeFromName(name),
      name: name,
    );
    await _send(convId, 'file', {
      'media_id': id,
      'name': name,
      'size': bytes.length,
    });
  }

  /// 语音消息（录制完成后调用；测试可直接传字节）。
  Future<void> sendVoice(
    int convId,
    Uint8List bytes,
    int durationMs, {
    String ext = 'm4a',
  }) async {
    final id = await mediaStore.upload(
      bytes,
      kind: 'voice',
      mime: ext == 'wav' ? 'audio/wav' : 'audio/mp4',
      name: 'voice.$ext',
    );
    await _send(convId, 'voice', {
      'media_id': id,
      'duration_ms': durationMs,
      'ext': ext,
    });
  }

  /// 表情贴纸（图片上传后引用；渲染时不带气泡背景）。
  Future<void> sendSticker(
    int convId,
    Uint8List bytes, {
    required String packId,
    required String stickerId,
  }) async {
    final id = await mediaStore.upload(
      bytes,
      kind: 'sticker',
      mime: 'image/png',
      name: '$stickerId.png',
    );
    await _send(convId, 'sticker', {
      'media_id': id,
      'pack_id': packId,
      'sticker_id': stickerId,
    });
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
      _persistLocalChats();
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
    final existing = list.where((x) => x.id == serverMsg.id).firstOrNull;
    final effective = existing != null && existing.revision > serverMsg.revision
        ? existing
        : serverMsg;
    // 服务端先走 WS 推送、后回 HTTP 响应：WS 事件可能已把同一条消息插入列表，
    // 替换占位消息前必须按 id 去重，否则发送方看到两条一模一样的消息。
    list.removeWhere((x) => x.id == serverMsg.id && !x.isPending);
    final i = list.indexWhere((x) => x.clientMsgId == cmid && x.isPending);
    if (i >= 0) {
      list[i] = effective;
    } else if (!list.any((x) => x.id == serverMsg.id)) {
      list.add(effective);
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
    final r = List.generate(
      8,
      (_) => rnd.nextInt(1 << 32).toRadixString(16),
    ).join();
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
