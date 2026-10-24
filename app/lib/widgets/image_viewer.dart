/// 全屏图片/贴纸查看器：双指缩放、点背景关闭。
library;

import 'dart:typed_data';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

Future<ShareResult> shareFilesFromContext(
  BuildContext context,
  List<XFile> files, {
  String? text,
}) {
  final object = context.findRenderObject();
  final origin = object is RenderBox && object.hasSize
      ? object.localToGlobal(Offset.zero) & object.size
      : null;
  return shareFilesFromOrigin(origin, files, text: text);
}

Future<ShareResult> shareFilesFromOrigin(
  Rect? origin,
  List<XFile> files, {
  String? text,
}) => Share.shareXFiles(files, text: text, sharePositionOrigin: origin);

Future<void> saveImage(
  BuildContext context,
  Future<Uint8List> bytes,
  String fileName,
) async {
  final object = context.findRenderObject();
  final shareOrigin = object is RenderBox && object.hasSize
      ? object.localToGlobal(Offset.zero) & object.size
      : null;
  try {
    final data = await bytes;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final loc = await getSaveLocation(suggestedName: fileName);
      if (loc == null) return;
      await File(loc.path).writeAsBytes(data);
    } else if (Platform.isIOS) {
      final dir = await getTemporaryDirectory();
      final safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
      final path = '${dir.path}/$safeName';
      await File(path).writeAsBytes(data);
      await shareFilesFromOrigin(shareOrigin, [XFile(path)], text: fileName);
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final folder = Directory(
        '${dir.path}${Platform.pathSeparator}QuickConect',
      );
      await folder.create(recursive: true);
      await File('${folder.path}${Platform.pathSeparator}$fileName')
          .writeAsBytes(data);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('图片已保存或已打开导出菜单')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }
}

Future<void> showImageViewer(
  BuildContext context,
  Future<Uint8List> bytes, {
  String fileName = 'image.jpg',
}) {
  return showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.pop(ctx),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              Center(
                child: FutureBuilder<Uint8List>(
                  future: bytes,
                  builder: (context, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const CircularProgressIndicator();
                    }
                    if (snap.hasError || snap.data == null) {
                      return const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48,
                      );
                    }
                    return InteractiveViewer(
                      maxScale: 5,
                      child: Image.memory(snap.data!, fit: BoxFit.contain),
                    );
                  },
                ),
              ),
              Positioned(
                top: 8,
                left: 8,
                child: IconButton(
                  tooltip: '保存图片',
                  icon: const Icon(
                    Icons.download_rounded,
                    color: Colors.white70,
                  ),
                  onPressed: () => saveImage(ctx, bytes, fileName),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
