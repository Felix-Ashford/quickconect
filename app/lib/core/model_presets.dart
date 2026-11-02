import 'dart:convert';

import 'prefs.dart';

/// 模型预设按服务器、账号和身份隔离；保留显式调用顺序。
class ModelPresetStore {
  ModelPresetStore(this.prefs, this.scope);
  final Prefs prefs;
  final String scope;
  String get _key => 'model_presets:${Uri.encodeComponent(scope)}';

  Map<String, List<String>> read() {
    try {
      final raw = jsonDecode(prefs.getString(_key) ?? '{}') as Map;
      return {
        for (final entry in raw.entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: (entry.value as List)
                .whereType<String>()
                .toList(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(String name, List<String> models) async {
    name = name.trim();
    if (name.isEmpty || name.length > 60) {
      throw ArgumentError('预设名称需为 1–60 个字符');
    }
    final presets = read();
    presets[name] = models
        .map((m) => m.trim())
        .where((m) => m.isNotEmpty)
        .toSet()
        .toList();
    await prefs.setString(_key, jsonEncode(presets));
  }

  Future<void> delete(String name) async {
    final presets = read()..remove(name);
    await prefs.setString(_key, jsonEncode(presets));
  }
}
