import 'package:flutter/material.dart';

/// 同名明确提示覆盖，取消不会修改原预设。
Future<String?> askPresetName(
  BuildContext context,
  Iterable<String> existing,
) async {
  final controller = TextEditingController();
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: const Text('保存为自定义预设'),
        content: TextField(
          key: const ValueKey('preset-name'),
          controller: controller,
          autofocus: true,
          maxLength: 60,
          onChanged: (_) => update(() {}),
          decoration: InputDecoration(
            labelText: '预设名称',
            helperText: existing.contains(controller.text.trim())
                ? '同名预设将被覆盖'
                : '预设保存在当前设备',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: controller.text.trim().isEmpty
                ? null
                : () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存预设'),
          ),
        ],
      ),
    ),
  );
  // 等待对话框退出动画后再释放输入控制器。
  await Future<void>.delayed(const Duration(milliseconds: 250));
  controller.dispose();
  return result;
}
