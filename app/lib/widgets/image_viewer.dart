/// 全屏图片/贴纸查看器：双指缩放、点背景关闭。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

Future<void> showImageViewer(BuildContext context, Future<Uint8List> bytes) {
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
                      return const Icon(Icons.broken_image_outlined,
                          color: Colors.white54, size: 48);
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
