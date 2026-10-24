/// REST API 客户端。所有请求走 dart:io HttpClient（证书锁定由全局
/// HttpOverrides 统一生效）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dart:typed_data';

import 'models.dart';

class ApiException implements Exception {
  final int? statusCode;
  final String message;
  ApiException(this.message, [this.statusCode]);

  @override
  String toString() => message;
}

class ApiClient {
  final String base; // 如 https://1.2.3.4:8443 或 http://127.0.0.1:9443
  String? token;
  final http.Client _http = http.Client();

  ApiClient({required this.base, this.token});

  /// 归一化：去尾部斜杠； scheme 默认 https。
  static String normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) throw ApiException('服务器地址不能为空');
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  bool get isSecure => base.startsWith('https://');

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<dynamic> _req(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    http.Response resp;
    try {
      final uri = Uri.parse('$base$path');
      final req = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      resp = await http.Response.fromStream(await _http.send(req))
          .timeout(timeout);
    } catch (e) {
      throw ApiException('无法连接服务器：$e');
    }
    if (resp.statusCode >= 300) {
      String msg = '请求失败 (${resp.statusCode})';
      try {
        final j = jsonDecode(utf8.decode(resp.bodyBytes));
        if (j is Map && j['error'] is String) msg = j['error'] as String;
      } catch (_) {}
      throw ApiException(msg, resp.statusCode);
    }
    if (resp.body.isEmpty) return null;
    return jsonDecode(utf8.decode(resp.bodyBytes));
  }

  // ---------- 鉴权 ----------

  /// 登录；返回 (用户, 本设备推送铃主题)。
  Future<(User, String)> login(
    String username,
    String password,
    String deviceName,
    String platform,
  ) async {
    final j = await _req(
      'POST',
      '/api/auth/login',
      body: {
        'username': username,
        'password': password,
        'device_name': deviceName,
        'platform': platform,
      },
    ) as Map<String, dynamic>;
    token = j['token'] as String;
    return (
      User.fromJson(j['user'] as Map<String, dynamic>),
      j['push_topic'] as String? ?? '',
    );
  }

  Future<void> logout() async {
    try {
      await _req('POST', '/api/auth/logout');
    } finally {
      token = null;
    }
  }

  Future<User> me() async =>
      User.fromJson((await _req('GET', '/api/me')) as Map<String, dynamic>);

  Future<String> uploadAvatar(
    Uint8List bytes, {
    String name = 'avatar.jpg',
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$base/api/media'))
      ..headers.addAll({'Authorization': 'Bearer $token'})
      ..fields['kind'] = 'avatar'
      ..fields['mime'] = name.toLowerCase().endsWith('.png')
          ? 'image/png'
          : 'image/jpeg'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: name));
    final resp = await http.Response.fromStream(await req.send());
    if (resp.statusCode >= 300) throw ApiException('头像上传失败', resp.statusCode);
    return (jsonDecode(utf8.decode(resp.bodyBytes))
            as Map<String, dynamic>)['media_id']
        as String;
  }

  Future<User> setAvatar(String mediaId) async => User.fromJson(
    (await _req('PUT', '/api/me/avatar', body: {'media_id': mediaId}))
        as Map<String, dynamic>,
  );

  /// 当前设备信息（含推送铃主题）。
  Future<DeviceInfo> device() async {
    final j = await _req('GET', '/api/device') as Map<String, dynamic>;
    return DeviceInfo(
      id: (j['id'] as num).toInt(),
      name: j['name'] as String? ?? '',
      platform: j['platform'] as String? ?? '',
      pushTopic: j['push_topic'] as String? ?? '',
    );
  }

  /// 让服务器向本机的推送铃发一条测试通知。
  /// 服务端复用真实推送路径，因此成功即代表离线推送可用。
  Future<void> pushTest() async {
    await _req('POST', '/api/push/test', body: const <String, dynamic>{});
  }

  // ---------- 名册与会话 ----------

  Future<List<User>> users() async {
    final j = await _req('GET', '/api/users');
    return (j as List)
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<Conversation>> conversations() async {
    final j = await _req('GET', '/api/conversations');
    return (j as List)
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<int> openDM(int peerId) async {
    final j = await _req(
      'POST',
      '/api/conversations',
      body: {'peer_id': peerId},
    );
    return (j as Map<String, dynamic>)['id'] as int;
  }

  // ---------- 消息 ----------

  Future<List<Message>> messagesAfter(
    int convId,
    int afterSeq, {
    int limit = 200,
  }) async {
    final j = await _req(
      'GET',
      '/api/conversations/$convId/messages?after_seq=$afterSeq&limit=$limit',
    );
    return ((j as Map<String, dynamic>)['messages'] as List)
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Message> send(
    int convId,
    String clientMsgId,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final j = await _req(
      'POST',
      '/api/conversations/$convId/messages',
      body: {'client_msg_id': clientMsgId, 'type': type, 'payload': payload},
    );
    return Message.fromJson(j as Map<String, dynamic>);
  }

  Future<Message> invokeAutomation(
    String identity,
    int convId,
    String clientMsgId,
    String prompt, {
    String model = '',
  }) async {
    final j = await _req(
      'POST',
      '/api/automation/$identity/invoke',
      timeout: const Duration(minutes: 3),
      body: {
        'conversation_id': convId,
        'client_msg_id': clientMsgId,
        'prompt': prompt,
        if (model.trim().isNotEmpty) 'model': model.trim(),
      },
    );
    return Message.fromJson(j as Map<String, dynamic>);
  }

  Future<List<AutomationIdentity>> automationIdentities() async {
    final j = await _req('GET', '/api/automation');
    return (j as List)
        .map((e) => AutomationIdentity.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<AutomationThread>> automationThreads(String identity) async {
    final j = await _req('GET', '/api/automation/$identity/threads');
    return (j as List)
        .map((e) => AutomationThread.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<String>> automationModels(String identity) async {
    final j = await _req('GET', '/api/automation/$identity/models');
    return ((j as Map<String, dynamic>)['models'] as List? ?? const [])
        .map((item) => item.toString())
        .toList();
  }

  Future<AutomationThread> createAutomationThread(
    String identity, {
    String title = '',
    String model = '',
  }) async {
    final j = await _req(
      'POST',
      '/api/automation/$identity/threads',
      body: {'title': title, 'model': model},
    );
    return AutomationThread.fromJson(j as Map<String, dynamic>);
  }

  Future<AutomationThread> updateAutomationThread(
    String identity,
    int conversationId, {
    String? title,
    String? model,
    bool updateSystemPrompt = false,
    String? systemPrompt,
  }) async {
    final j = await _req(
      'PUT',
      '/api/automation/$identity/threads/$conversationId',
      body: {
        'title': ?title,
        'model': ?model,
        if (updateSystemPrompt) 'system_prompt': systemPrompt,
      },
    );
    return AutomationThread.fromJson(j as Map<String, dynamic>);
  }

  Future<void> deleteAutomationThread(
    String identity,
    int conversationId,
  ) async {
    await _req('DELETE', '/api/automation/$identity/threads/$conversationId');
  }

  Future<void> markRead(int convId, int seq) async {
    await _req('POST', '/api/conversations/$convId/read', body: {'seq': seq});
  }

  Future<Message> editMessage(Message message, String text) async =>
      Message.fromJson(
        await _req(
          'PUT',
          '/api/conversations/${message.convId}/messages/${message.id}',
          body: {'text': text},
        ) as Map<String, dynamic>,
      );

  Future<Message> retractMessage(Message message) async => Message.fromJson(
    await _req(
      'DELETE',
      '/api/conversations/${message.convId}/messages/${message.id}',
    ) as Map<String, dynamic>,
  );

  Future<Map<String, dynamic>> messageChanges(
    int convId,
    int afterRevision,
  ) async => await _req(
    'GET',
    '/api/conversations/$convId/changes?after_revision=$afterRevision',
  ) as Map<String, dynamic>;

  Future<Message> regenerateMessage(
    String identity,
    Message message,
    String clientMsgId,
  ) async => Message.fromJson(
    await _req(
      'POST',
      '/api/automation/$identity/regenerate',
      body: {
        'conversation_id': message.convId,
        'message_id': message.id,
        'client_msg_id': clientMsgId,
      },
      timeout: const Duration(minutes: 3),
    ) as Map<String, dynamic>,
  );
}
