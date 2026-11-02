import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:quickconect_app/core/model_presets.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/theme_scheme.dart';
import 'package:quickconect_app/pages/appearance_page.dart';
import 'package:quickconect_app/widgets/automation_thread_settings.dart';

void main() {
  test('old color schemes gain excluded colors and Windows uses Chinese system fonts', () {
    final old = QcScheme.builtIns.first.toJson()
      ..remove('excludedAiBubble')
      ..remove('excludedAiBubbleText');
    final scheme = QcScheme.fromJson(old);
    expect(scheme.excludedAiBubble, const Color(0xFFFFE0B2));
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final style = buildQcTheme(scheme).textTheme.bodyMedium!;
    expect(style.fontFamily, 'Microsoft YaHei UI');
    expect(style.fontFamilyFallback, contains('Microsoft YaHei'));
  });

  test('model presets preserve order and isolate scopes', () async {
    final prefs = MemoryPrefs();
    final store = ModelPresetStore(prefs, 'server|alice|helper');
    await store.save('常用', ['beta', 'alpha', 'beta']);
    expect(ModelPresetStore(prefs, store.scope).read()['常用'], [
      'beta',
      'alpha',
    ]);
    expect(ModelPresetStore(prefs, 'server|bob|helper').read(), isEmpty);
    await store.save('常用', []);
    expect(store.read()['常用'], isEmpty);
    await store.delete('常用');
    expect(store.read(), isEmpty);
  });

  test('color presets retain AI colors after restart', () async {
    final prefs = MemoryPrefs();
    final theme = ThemeController(prefs);
    await theme.apply(
      theme.scheme.copyWith(
        aiBubble: Colors.purple,
        primary: Colors.orange,
        excludedAiBubble: Colors.amber,
        excludedAiBubbleText: Colors.brown,
      ),
    );
    await theme.savePreset('我的方案');
    final restored = ThemeController(prefs);
    await restored.load();
    expect(restored.userPresets.single.name, '我的方案');
    expect(
      restored.userPresets.single.aiBubble.toARGB32(),
      Colors.purple.toARGB32(),
    );
    expect(restored.scheme.primary.toARGB32(), Colors.orange.toARGB32());
    expect(
      restored.scheme.excludedAiBubble.toARGB32(),
      Colors.amber.toARGB32(),
    );
    expect(
      restored.scheme.excludedAiBubbleText.toARGB32(),
      Colors.brown.toARGB32(),
    );
    await restored.savePreset('我的方案');
    expect(restored.userPresets.length, 1);
    await restored.deletePreset('我的方案');
    expect(restored.userPresets, isEmpty);
    theme.dispose();
    restored.dispose();
  });

  testWidgets('appearance exposes named preset save', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final theme = ThemeController(MemoryPrefs());
    addTearDown(theme.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: theme,
        child: const MaterialApp(home: AppearancePage()),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('save-color-preset')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('preset-name')), '深紫');
    await tester.pump();
    await tester.tap(find.text('保存预设'));
    await tester.pumpAndSettle();
    expect(theme.userPresets.single.name, '深紫');
    expect(find.text('深紫'), findsOneWidget);
    expect(find.byTooltip('删除预设「深紫」'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'model preset can be named and restored on narrow screen with keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final store = ModelPresetStore(MemoryPrefs(), 'server|alice|helper');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AutomationThreadSettingsDialog(
                    thread: const AutomationThread(
                      id: 1,
                      identity: 'helper',
                      userId: 1,
                      conversationId: 1,
                      title: '',
                      selectedModel: 'alpha',
                      selectedModels: ['beta', 'alpha'],
                      createdAt: 0,
                    ),
                    defaultPrompt: '',
                    availableModels: const ['alpha', 'beta', 'gamma'],
                    presetStore: store,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存为预设'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('preset-name')), '备用顺序');
      await tester.pump();
      await tester.tap(find.text('保存预设'));
      await tester.pumpAndSettle();
      expect(store.read()['备用顺序'], ['beta', 'alpha']);
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('套用或删除模型预设'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('备用顺序 · 2 个模型'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('selected-model-beta')), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('model-search')));
      await tester.enterText(
        find.byKey(const ValueKey('model-search')),
        'alpha',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
