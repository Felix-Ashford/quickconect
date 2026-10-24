/// 自定义表情包：zip 导入（manifest.json + 图片文件），存到应用文档目录。
///
/// zip 结构：
///   manifest.json  {"name": "包名", "stickers": [{"id": "s1", "file": "s1.png"}, ...]}
///   s1.png ...
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import 'prefs.dart';

class Sticker {
  final String id;
  final String file; // 文件名（包目录内）
  const Sticker({required this.id, required this.file});
}

class StickerPack {
  final String id;
  final String name;
  final String dir; // 包目录绝对路径
  final List<Sticker> stickers;
  const StickerPack({
    required this.id,
    required this.name,
    required this.dir,
    required this.stickers,
  });

  File fileOf(Sticker s) => File('$dir/${s.file}');
}

class StickerStore {
  static const _prefsKey = 'sticker_packs';
  final Prefs prefs;
  StickerStore(this.prefs);

  Future<String> _rootDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}${Platform.pathSeparator}stickers');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  List<Map<String, dynamic>> _metaList() {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveMeta(List<Map<String, dynamic>> list) async {
    await prefs.setString(_prefsKey, jsonEncode(list));
  }

  Future<List<StickerPack>> loadAll() async {
    final root = await _rootDir();
    final out = <StickerPack>[];
    for (final meta in _metaList()) {
      final dir = Directory(meta['dir'] as String? ?? '');
      if (!dir.existsSync()) continue;
      final stickers = ((meta['stickers'] as List?) ?? [])
          .map((e) => Sticker(id: e['id'] as String, file: e['file'] as String))
          .toList();
      if (stickers.isEmpty) continue;
      out.add(
        StickerPack(
          id: meta['id'] as String,
          name: meta['name'] as String? ?? '未命名',
          dir: meta['dir'] as String? ?? root,
          stickers: stickers,
        ),
      );
    }
    return out;
  }

  /// 导入 zip；成功返回包名。
  Future<String> importZip(Uint8List bytes) async {
    final archive = ZipDecoder().decodeBytes(bytes);
    Map<String, dynamic>? manifest;
    final files = <String, List<int>>{};
    for (final f in archive) {
      if (f.isFile) {
        final name = f.name.split(Platform.isWindows ? r'\' : '/').last;
        if (name == 'manifest.json') {
          manifest = jsonDecode(
            utf8.decode(f.content as List<int>),
          ) as Map<String, dynamic>;
        } else {
          files[name] = f.content as List<int>;
        }
      }
    }
    if (manifest == null) {
      throw const FormatException('缺少 manifest.json');
    }
    final name = manifest['name'] as String? ?? '我的表情包';
    final stickers = ((manifest['stickers'] as List?) ?? [])
        .map((e) => e as Map<String, dynamic>)
        .where((e) => files.containsKey(e['file']))
        .map((e) => {'id': e['id'].toString(), 'file': e['file'].toString()})
        .toList();
    if (stickers.isEmpty) {
      throw const FormatException('包内没有可用贴纸');
    }

    final packId = 'p${DateTime.now().millisecondsSinceEpoch}';
    final dir = Directory(
      '${await _rootDir()}${Platform.pathSeparator}$packId',
    );
    dir.createSync(recursive: true);
    for (final s in stickers) {
      await File('${dir.path}${Platform.pathSeparator}${s['file']}')
          .writeAsBytes(files[s['file']]!);
    }
    final meta = _metaList()
      ..add({
        'id': packId,
        'name': name,
        'dir': dir.path,
        'stickers': stickers,
      });
    await _saveMeta(meta);
    return name;
  }
}
