import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/model_presets.dart';
import 'preset_name_dialog.dart';

class AutomationThreadSettings {
  const AutomationThreadSettings(this.models, this.systemPrompt);
  final List<String> models;
  final String? systemPrompt;
}

/// The ordered selection is independent of search/filter results.
class AutomationThreadSettingsDialog extends StatefulWidget {
  const AutomationThreadSettingsDialog({
    super.key,
    required this.thread,
    required this.defaultPrompt,
    required this.availableModels,
    this.presetStore,
  });

  final AutomationThread thread;
  final String defaultPrompt;
  final List<String> availableModels;
  final ModelPresetStore? presetStore;

  @override
  State<AutomationThreadSettingsDialog> createState() => _SettingsState();
}

class _SettingsState extends State<AutomationThreadSettingsDialog> {
  late final _selected = widget.thread.modelOrder.toSet().toList();
  late final _models =
      {
          ...widget.availableModels,
          ..._selected,
        }.where((m) => m.trim().isNotEmpty).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  final _search = TextEditingController();
  late final _prompt = TextEditingController(
    text: widget.thread.systemPrompt ?? widget.defaultPrompt,
  );
  late bool _inherit = widget.thread.systemPrompt == null;
  late String _customPrompt = widget.thread.systemPrompt ?? '';
  bool _presetBusy = false;
  bool _reorderOpen = false;

  Future<void> _savePreset() async {
    if (_presetBusy) return;
    setState(() => _presetBusy = true);
    try {
      final store = widget.presetStore!;
      final name = await askPresetName(context, store.read().keys);
      if (name != null) await store.save(name, List.of(_selected));
    } finally {
      if (mounted) setState(() => _presetBusy = false);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _reorderModels() async {
    if (_reorderOpen || _selected.length < 2) return;
    _reorderOpen = true;
    FocusManager.instance.primaryFocus?.unfocus();
    final models = List<String>.of(_selected);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('模型调用优先顺序'),
          content: SizedBox(
            width: 480,
            height: math.min(400.0, math.max(180.0, models.length * 64.0 + 48)),
            child: Column(
              children: [
                const Text('按住模型行或拖动把手上下移动；也可点击箭头。最上方优先调用。'),
                const SizedBox(height: 8),
                Expanded(
                  child: ReorderableListView.builder(
                    key: const ValueKey('selected-models'),
                    primary: false,
                    itemExtent: 64,
                    buildDefaultDragHandles: false,
                    itemCount: models.length,
                    onReorderItem: (oldIndex, newIndex) => update(() {
                      final item = models.removeAt(oldIndex);
                      models.insert(newIndex, item);
                    }),
                    itemBuilder: (context, index) => Material(
                      key: ValueKey('sort-model-${models[index]}'),
                      color: Theme.of(context).colorScheme.surface,
                      child: Row(
                        children: [
                          Expanded(
                            child: ReorderableDragStartListener(
                              index: index,
                              child: MouseRegion(
                                cursor: SystemMouseCursors.grab,
                                child: Container(
                                  color: Colors.transparent,
                                  padding: const EdgeInsets.all(8),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.drag_handle),
                                      const SizedBox(width: 8),
                                      Text('${index + 1}.'),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          models[index],
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '提高优先级',
                            onPressed: index == 0
                                ? null
                                : () => update(() {
                                    final item = models.removeAt(index);
                                    models.insert(index - 1, item);
                                  }),
                            icon: const Icon(Icons.arrow_upward, size: 18),
                          ),
                          IconButton(
                            tooltip: '降低优先级',
                            onPressed: index == models.length - 1
                                ? null
                                : () => update(() {
                                    final item = models.removeAt(index);
                                    models.insert(index + 1, item);
                                  }),
                            icon: const Icon(Icons.arrow_downward, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, models),
              child: const Text('完成排序'),
            ),
          ],
        ),
      ),
    );
    _reorderOpen = false;
    if (result != null && mounted) {
      setState(() {
        _selected
          ..clear()
          ..addAll(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final height = math.max(
      160.0,
      math.min(560.0, media.size.height - media.viewInsets.bottom - 210),
    );
    final filtered = _models
        .where(
          (m) => m.toLowerCase().contains(_search.text.trim().toLowerCase()),
        )
        .toList();
    return DefaultTabController(
      length: 2,
      child: AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        title: const Text('模型与提示词'),
        content: SizedBox(
          width: 560,
          height: height,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: '模型'),
                  Tab(text: '提示词'),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: TabBarView(
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        primary: false,
                        child: SizedBox(
                          height: math.max(420, constraints.maxHeight),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.presetStore != null)
                                Row(
                                  children: [
                                    Expanded(
                                      child: PopupMenuButton<String>(
                                        tooltip: '套用或删除模型预设',
                                        onSelected: (value) async {
                                          final store = widget.presetStore!;
                                          final name = value.substring(2);
                                          if (value.startsWith('d:')) {
                                            await store.delete(name);
                                            if (mounted) setState(() {});
                                          } else {
                                            final models =
                                                store.read()[name] ?? [];
                                            setState(() {
                                              _selected
                                                ..clear()
                                                ..addAll(models);
                                              for (final model in models) {
                                                if (!_models.contains(model)) {
                                                  _models.add(model);
                                                }
                                              }
                                            });
                                          }
                                        },
                                        itemBuilder: (_) => [
                                          for (final entry
                                              in widget.presetStore!
                                                  .read()
                                                  .entries) ...[
                                            PopupMenuItem(
                                              value: 'a:${entry.key}',
                                              child: Text(
                                                '${entry.key} · ${entry.value.isEmpty ? '自动' : '${entry.value.length} 个模型'}',
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: 'd:${entry.key}',
                                              child: Text('删除预设「${entry.key}」'),
                                            ),
                                          ],
                                          if (widget.presetStore!
                                              .read()
                                              .isEmpty)
                                            const PopupMenuItem(
                                              enabled: false,
                                              child: Text('暂无模型预设'),
                                            ),
                                        ],
                                        child: const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Text('模型预设 ▾'),
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: _presetBusy
                                          ? null
                                          : _savePreset,
                                      child: const Text('保存为预设'),
                                    ),
                                  ],
                                ),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '已选 ${_selected.length} 个 · 按从上到下尝试',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _selected.isEmpty
                                        ? null
                                        : () => setState(_selected.clear),
                                    child: const Text('清空'),
                                  ),
                                ],
                              ),
                              if (_selected.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.only(bottom: 8),
                                  child: Text('自动选择：使用 Manager 默认模型和回退顺序。'),
                                ),
                              if (_selected.isNotEmpty)
                                SizedBox(
                                  height: 104,
                                  child: ListView(
                                    children: [
                                      for (var i = 0; i < _selected.length; i++)
                                        ListTile(
                                          key: ValueKey(
                                            'selected-model-${_selected[i]}',
                                          ),
                                          dense: true,
                                          contentPadding: EdgeInsets.zero,
                                          leading: Text('${i + 1}.'),
                                          title: Text(
                                            _selected[i],
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              if (_selected.length > 1)
                                TextButton.icon(
                                  key: const ValueKey('reorder-models'),
                                  onPressed: _reorderModels,
                                  icon: const Icon(Icons.reorder),
                                  label: const Text('调整模型优先顺序'),
                                ),
                              TextField(
                                key: const ValueKey('model-search'),
                                controller: _search,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: '搜索模型',
                                  prefixIcon: Icon(Icons.search),
                                ),
                              ),
                              Expanded(
                                child: filtered.isEmpty
                                    ? Center(
                                        child: Text(
                                          _models.isEmpty
                                              ? '暂无模型列表，可保留自动选择。'
                                              : '没有匹配的模型',
                                        ),
                                      )
                                    : ListView.builder(
                                        itemCount: filtered.length,
                                        itemBuilder: (context, index) {
                                          final model = filtered[index];
                                          return CheckboxListTile(
                                            key: ValueKey(
                                              'model-option-$model',
                                            ),
                                            dense: true,
                                            contentPadding: EdgeInsets.zero,
                                            value: _selected.contains(model),
                                            controlAffinity:
                                                ListTileControlAffinity.leading,
                                            title: Text(
                                              model,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            onChanged: (checked) =>
                                                setState(() {
                                                  if (checked == true &&
                                                      !_selected.contains(
                                                        model,
                                                      )) {
                                                    _selected.add(model);
                                                  } else if (checked != true) {
                                                    _selected.remove(model);
                                                  }
                                                }),
                                          );
                                        },
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ListView(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('使用 Manager 中的默认提示词'),
                          value: _inherit,
                          onChanged: (value) => setState(() {
                            if (!_inherit) _customPrompt = _prompt.text;
                            _inherit = value;
                            _prompt.text = value
                                ? widget.defaultPrompt
                                : _customPrompt;
                          }),
                        ),
                        TextField(
                          controller: _prompt,
                          enabled: !_inherit,
                          minLines: 4,
                          maxLines: 10,
                          decoration: const InputDecoration(
                            labelText: '系统提示词',
                            helperText: '关闭默认后可单独填写；留空表示此对话没有系统提示词。',
                            helperMaxLines: 3,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              AutomationThreadSettings(
                List<String>.of(_selected),
                _inherit ? null : _prompt.text,
              ),
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
