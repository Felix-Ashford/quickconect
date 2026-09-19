/// WebSocket 实时通道：自动重连（指数退避）、应用层心跳、事件回调。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

enum WsState { disconnected, connecting, connected }

class WsClient {
  final String wsUrl; // wss://host:port/api/ws?token=xxx
  final void Function(Map<String, dynamic> event) onEvent;
  final void Function(WsState state)? onState;

  WebSocketChannel? _ch;
  Timer? _ping;
  Timer? _retry;
  bool _stopped = true;
  int _attempt = 0;

  WsClient({required this.wsUrl, required this.onEvent, this.onState});

  void start() {
    _stopped = false;
    _connect();
  }

  void stop() {
    _stopped = true;
    _ping?.cancel();
    _retry?.cancel();
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
    _setState(WsState.disconnected);
  }

  void _setState(WsState s) => onState?.call(s);

  Future<void> _connect() async {
    if (_stopped) return;
    _setState(WsState.connecting);
    final WebSocketChannel ch;
    try {
      ch = WebSocketChannel.connect(Uri.parse(wsUrl));
      _ch = ch;
      await ch.ready; // 握手失败会抛错
    } catch (_) {
      _scheduleReconnect();
      return;
    }

    _attempt = 0;
    _setState(WsState.connected);
    _ping?.cancel();
    _ping = Timer.periodic(const Duration(seconds: 25), (_) {
      try {
        _ch?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });

    try {
      await for (final data in ch.stream) {
        if (data is String) {
          try {
            final j = jsonDecode(data);
            if (j is Map<String, dynamic>) onEvent(j);
          } catch (_) {
            // 非法帧忽略
          }
        }
      }
    } catch (_) {
      // 网络断开等
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _setState(WsState.disconnected);
    _ping?.cancel();
    final delay = Duration(seconds: min(30, 1 << _attempt.clamp(0, 5)));
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }
}
