/// 桌面端自定义标题栏：隐藏系统黑边后由应用自绘，颜色跟随主题。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/theme_scheme.dart';

class QcTitleBar extends StatelessWidget {
  const QcTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final barColor =
        theme.appBarTheme.backgroundColor ?? theme.colorScheme.primary;
    final fg = QcScheme.contrastOn(barColor);

    return Material(
      type: MaterialType.transparency,
      child: Container(
        height: 34,
        color: barColor,
        child: Row(
          children: [
            const SizedBox(width: 12),
            Expanded(
              child: DragToMoveArea(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'QuickConect',
                    style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.85)),
                  ),
                ),
              ),
            ),
            _WinButton(
              icon: Icons.horizontal_rule,
              fg: fg,
              onTap: () => windowManager.minimize(),
            ),
            _WinButton(
              icon: Icons.crop_square,
              fg: fg,
              onTap: () async {
                if (await windowManager.isMaximized()) {
                  await windowManager.unmaximize();
                } else {
                  await windowManager.maximize();
                }
              },
            ),
            _WinButton(
              icon: Icons.close,
              fg: fg,
              hoverRed: true,
              onTap: () => windowManager.destroy(),
            ),
          ],
        ),
      ),
    );
  }
}

class _WinButton extends StatelessWidget {
  final IconData icon;
  final Color fg;
  final VoidCallback onTap;
  final bool hoverRed;

  const _WinButton({
    required this.icon,
    required this.fg,
    required this.onTap,
    this.hoverRed = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: hoverRed ? Colors.red.withValues(alpha: 0.9) : fg.withValues(alpha: 0.12),
      child: SizedBox(
        width: 44,
        height: 34,
        child: Icon(icon, size: 16, color: fg),
      ),
    );
  }
}
