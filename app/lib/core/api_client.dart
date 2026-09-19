/// REST API 客户端。所有请求走 dart:io HttpClient（证书锁定由全局
/// HttpOverrides 统一生效）。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

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
  }) async {
    http.Response resp;
    try {
      final uri = Uri.parse('$base$path');
      final req = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) req.body = jsonEncode(body);
      resp = await http.Response.fromStream(
        await _http.send(req),
      ).timeout(const Duration(seconds: 15));
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

  // ---------- 名册与会话 ----------

  Future<List<User>> users() async {
    final j = await _req('GET', '/api/users');
    return (j as List).map((e) => User.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Conversation>> conversations() async {
    final j = await _req('GET', '/api/conversations');
    return (j as List)
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<int> openDM(int peerId) async {
    final j = await _req('POST', '/api/conversations', body: {'peer_id': peerId});
    return (j as Map<String, dynamic>)['id'] as int;
  }

  // ---------- 消息 ----------

  Future<List<Message>> messagesAfter(int convId, int afterSeq, {int limit = 200}) async {
    final j = await _req('GET', '/api/conversations/$convId/messages?after_seq=$afterSeq&limit=$limit');
    return ((j as Map<String, dynamic>)['messages'] as List)
        .map((e) => Message.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Message> send(int convId, String clientMsgId, String type, Map<String, dynamic> payload) async {
    final j = await _req(
      'POST',
      '/api/conversations/$convId/messages',
      body: {'client_msg_id': clientMsgId, 'type': type, 'payload': payload},
    );
    return Message.fromJson(j as Map<String, dynamic>);
  }

  Future<void> markRead(int convId, int seq) async {
    await _req('POST', '/api/conversations/$convId/read', body: {'seq': seq});
  }
}
