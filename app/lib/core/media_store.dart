/// 媒体传输层：上传（multipart 流式）、下载（内存缓存，媒体不可变可永久缓存）、
/// 缩略图生成。所有字节都经鉴权请求获取。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import 'api_client.dart';

class MediaStore {
  final ApiClient api;
  final _cache = <String, Uint8List>{};
  final _futures = <String, Future<Uint8List>>{};
  final http.Client _http = http.Client();
  bool persistentCacheEnabled = true;

  MediaStore(this.api);

  Future<Uint8List> downloadAvatar(String mediaId) => download(mediaId);

  Map<String, String> get _headers => {'Authorization': 'Bearer ${api.token}'};

  Future<Directory> _persistentCacheDir() async {
    final support = await getApplicationSupportDirectory();
    final namespace = sha256
        .convert(utf8.encode('${api.base}|${api.token ?? ''}'))
        .toString();
    final dir = Directory(
      '${support.path}${Platform.pathSeparator}QuickConect${Platform.pathSeparator}media_$namespace',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _writePersistent(String mediaId, Uint8List bytes) async {
    if (!persistentCacheEnabled) return;
    try {
      final dir = await _persistentCacheDir();
      final file = File('${dir.path}${Platform.pathSeparator}$mediaId');
      if (await file.exists()) return;
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } catch (e) {
      log('本地媒体缓存写入失败 $mediaId: $e');
    }
  }

  Future<int> persistentCacheSize() async {
    if (!persistentCacheEnabled) return 0;
    try {
      final dir = await _persistentCacheDir();
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && !entity.path.endsWith('.tmp')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<void> clearPersistentCache() async {
    try {
      final dir = await _persistentCacheDir();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      log('本地媒体缓存清理失败: $e');
    }
    _cache.clear();
    _futures.clear();
  }

  /// 轻量文件日志（失败自诊断用），写在系统临时目录。
  static void log(String msg) {
    try {
      File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}quickconect_client.log',
      ).writeAsStringSync(
        '${DateTime.now().toIso8601String()} $msg\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  /// 上传媒体，返回 media_id。
  Future<String> upload(
    Uint8List bytes, {
    required String kind,
    String mime = 'application/octet-stream',
    String name = 'file.bin',
  }) async {
    final req =
        http.MultipartRequest('POST', Uri.parse('${api.base}/api/media'))
          ..headers.addAll(_headers)
          ..fields['kind'] = kind
          ..fields['mime'] = mime
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: name),
          );
    final resp = await _http.send(req).timeout(const Duration(seconds: 120));
    final body = await resp.stream.bytesToString();
    if (resp.statusCode >= 300) {
      log(
        '上传失败 kind=$kind size=${bytes.length}: HTTP ${resp.statusCode} $body',
      );
      throw ApiException('上传失败：$body', resp.statusCode);
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    final mediaId = j['media_id'] as String;
    _cache[mediaId] = bytes;
    await _writePersistent(mediaId, bytes);
    return mediaId;
  }

  /// 下载媒体：成功的字节永久缓存（媒体不可变）；同一媒体的并发/重复请求
  /// 共享同一个未来；失败的未来不驻留，下次调用自动重试（内置 2 次退避重试）。
  Future<Uint8List> download(String mediaId) {
    final hit = _cache[mediaId];
    if (hit != null) return Future.value(hit);
    return _futures.putIfAbsent(mediaId, () {
      final f = _downloadWithRetry(mediaId);
      unawaited(
        f.then(
          (_) {},
          onError: (Object _) {
            _futures.remove(mediaId); // 失败的未来不驻留，下次调用自动重试
          },
        ),
      );
      return f;
    });
  }

  /// 强制重新下载（失败重试入口）。
  Future<Uint8List> retryDownload(String mediaId) {
    _futures.remove(mediaId);
    return download(mediaId);
  }

  Future<Uint8List> _downloadWithRetry(String mediaId) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _downloadOnce(mediaId);
      } catch (e) {
        log('下载失败(第${attempt + 1}次) $mediaId: $e');
        if (attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
      }
    }
  }

  Future<Uint8List> _downloadOnce(String mediaId) async {
    if (persistentCacheEnabled) {
      try {
        final dir = await _persistentCacheDir();
        final file = File('${dir.path}${Platform.pathSeparator}$mediaId');
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          _cache[mediaId] = bytes;
          return bytes;
        }
      } catch (_) {}
    }
    final resp = await _http
        .get(Uri.parse('${api.base}/api/media/$mediaId'), headers: _headers)
        .timeout(const Duration(seconds: 120));
    if (resp.statusCode >= 300) {
      throw ApiException('下载失败 (${resp.statusCode})', resp.statusCode);
    }
    final bytes = resp.bodyBytes;
    _cache[mediaId] = bytes;
    await _writePersistent(mediaId, bytes);
    return bytes;
  }

  /// 生成缩略图（最长边 320px）。解码失败或图已足够小则原样返回。
  static Future<Uint8List> makeThumbnail(
    Uint8List bytes, {
    int maxSide = 320,
  }) async {
    try {
      final im = img.decodeImage(bytes);
      if (im == null) return bytes;
      if (im.width <= maxSide && im.height <= maxSide) return bytes;
      final w = im.width >= im.height
          ? maxSide
          : im.width * maxSide ~/ im.height;
      final h = im.height > im.width
          ? maxSide
          : im.height * maxSide ~/ im.width;
      final thumb = img.copyResize(im, width: w, height: h);
      return Uint8List.fromList(img.encodePng(thumb));
    } catch (_) {
      return bytes;
    }
  }

  /// 把下载的字节写到临时文件（语音播放等需要文件路径的场景）。
  Future<File> saveToTemp(
    String mediaId,
    Uint8List bytes, {
    String ext = 'bin',
  }) async {
    final dir = await Directory.systemTemp.createTemp('qc_media');
    final f = File('${dir.path}/$mediaId.$ext');
    await f.writeAsBytes(bytes);
    return f;
  }
}

/// 依据扩展名猜 MIME（够用即可，服务器不解析内容）。
String mimeFromName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const map = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'm4a': 'audio/mp4',
    'aac': 'audio/aac',
    'wav': 'audio/wav',
    'mp3': 'audio/mpeg',
    'mp4': 'video/mp4',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'zip': 'application/zip',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  };
  return map[ext] ?? 'application/octet-stream';
}

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
