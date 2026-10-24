/// iOS 保活（「保持在线」开关）：
/// 静音音频循环播放 + AVAudioSession 设为 playback，配合 Info.plist 的
/// UIBackgroundModes=audio，可阻止系统在退后台后挂起 App，
/// 从而让 WebSocket 长连接与本地通知保持实时。代价是耗电增加，默认关闭。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart';

class IosKeepAlive {
  IosKeepAlive._();
  static bool _on = false;
  static AudioPlayer? _player;
  static Uint8List? _silence;

  static bool get isOn => _on;

  static Future<void> setEnabled(bool on) async {
    if (!Platform.isIOS || on == _on) return;
    _on = on;
    if (on) {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _player ??= AudioPlayer();
      _silence ??= _silenceWav();
      try {
        await _player!.setReleaseMode(ReleaseMode.loop);
        await _player!.play(BytesSource(_silence!));
      } catch (_) {
        _on = false;
      }
    } else {
      try {
        await _player?.stop();
      } catch (_) {}
    }
  }

  /// 生成 2 秒 8kHz 单声道 16bit 的静音 WAV（约 32KB）。
  static Uint8List _silenceWav({int seconds = 2}) {
    const sampleRate = 8000, channels = 1, bitsPerSample = 16;
    final dataLen = sampleRate * channels * bitsPerSample ~/ 8 * seconds;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;

    final b = BytesBuilder();
    void str(String s) => b.add(s.codeUnits);
    void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    void u32(int v) =>
        b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

    str('RIFF');
    u32(36 + dataLen);
    str('WAVE');
    str('fmt ');
    u32(16);
    u16(1); // PCM
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bitsPerSample);
    str('data');
    u32(dataLen);
    b.add(Uint8List(dataLen)); // 全零 = 静音
    return b.toBytes();
  }
}
