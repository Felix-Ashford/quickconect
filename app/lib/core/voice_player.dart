/// 语音播放器（全局单例）：把下载的音频落临时文件后播放，兼容四端。
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class VoicePlayer {
  VoicePlayer._();
  static final VoicePlayer instance = VoicePlayer._();

  final AudioPlayer _player = AudioPlayer();

  /// 正在播放的媒体 ID（null=空闲）。
  final ValueNotifier<String?> playing = ValueNotifier(null);

  /// 已播放毫秒数（仅播放中有效）。
  final ValueNotifier<int> positionMs = ValueNotifier(0);

  String? _currentMediaId;

  Future<void> init() async {
    _player.onPlayerComplete.listen((_) {
      playing.value = null;
      positionMs.value = 0;
    });
    _player.onPositionChanged.listen((p) {
      positionMs.value = p.inMilliseconds;
    });
  }

  /// 播放指定媒体；再次调用同一 ID 即停止，不同 ID 即切换。
  Future<void> toggle(String mediaId, String filePath) async {
    if (_currentMediaId == mediaId && playing.value != null) {
      await stop();
      return;
    }
    await stop();
    _currentMediaId = mediaId;
    try {
      await _player.play(DeviceFileSource(filePath));
      playing.value = mediaId;
    } catch (_) {
      playing.value = null;
    }
  }

  Future<void> stop() async {
    playing.value = null;
    positionMs.value = 0;
    try {
      await _player.stop();
    } catch (_) {}
  }
}
