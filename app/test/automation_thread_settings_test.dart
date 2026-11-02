import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/widgets/automation_thread_settings.dart';

const thread = AutomationThread(
  id: 1,
  identity: 'helper',
  userId: 2,
  conversationId: 7,
  title: 'Test',
  selectedModel: 'alpha',
  selectedModels: ['alpha', 'beta'],
  createdAt: 0,
);

void main() {
  testWidgets(
    'search preserves checked models and reordered choice is returned',
    (tester) async {
      AutomationThreadSettings? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<AutomationThreadSettings>(
                    context: context,
                    builder: (_) => const AutomationThreadSettingsDialog(
                      thread: thread,
                      defaultPrompt: 'default',
                      availableModels: ['alpha', 'beta', 'gamma'],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('model-search')), 'GAM');
      await tester.pump();
      expect(find.byKey(const ValueKey('model-option-alpha')), findsNothing);
      expect(
        find.byKey(const ValueKey('selected-model-alpha')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('model-option-gamma')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reorder-models')));
      await tester.pumpAndSettle();
      final handle = find.byIcon(Icons.drag_handle).at(1);
      final start = tester.getCenter(handle);
      final gesture = await tester.startGesture(
        start,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(kPressTimeout);
      await gesture.moveTo(start - const Offset(0, 32));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.moveTo(start - const Offset(0, 64));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('sort-model-beta'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('sort-model-alpha'))).dy,
        ),
      );
      await tester.tap(find.text('完成排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result?.models, ['beta', 'alpha', 'gamma']);
      expect(result?.systemPrompt, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow dialog supports clearing models and explicit empty prompt',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      AutomationThreadSettings? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<AutomationThreadSettings>(
                    context: context,
                    builder: (_) => const AutomationThreadSettingsDialog(
                      thread: thread,
                      defaultPrompt: 'default',
                      availableModels: ['alpha', 'beta'],
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      expect(find.text('自动选择：使用 Manager 默认模型和回退顺序。'), findsOneWidget);
      await tester.tap(find.text('提示词'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result?.models, isEmpty);
      expect(result?.systemPrompt, '');
      expect(tester.takeException(), isNull);
    },
  );
}
