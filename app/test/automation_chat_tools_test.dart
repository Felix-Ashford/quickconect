import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/core/action_gate.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';
import 'package:quickconect_app/widgets/automation_chat_tools.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('API thread actions fit narrow screens and show active model', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session(SharedPrefs(await SharedPreferences.getInstance()));
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const identity = AutomationIdentity(
      id: 'assistant',
      name: 'assistant',
      displayName: 'Assistant',
      mode: 'api',
      defaultModel: '',
      models: [],
      privateDirectory: true,
    );
    const thread = AutomationThread(
      id: 1,
      identity: 'assistant',
      userId: 2,
      conversationId: 11,
      title: 'Thread',
      selectedModel: '',
      createdAt: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AutomationChatTools(
            session: session,
            identity: identity,
            thread: thread,
            onDirectory: () {},
            onConversationChanged: (_) {},
            onUpdated: () {},
            activeModel: 'gpt-test',
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    for (final label in ['新建对话', '切换对话', '删除对话']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('模型与提示词'), findsOneWidget);
    expect(find.text('上次使用 · gpt-test'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('automation-actions-row')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('automation-model-row')), findsOneWidget);
    final firstRow = tester.getRect(
      find.byKey(const ValueKey('automation-actions-row')),
    );
    final secondRow = tester.getRect(
      find.byKey(const ValueKey('automation-model-row')),
    );
    expect(secondRow.top, greaterThanOrEqualTo(firstRow.bottom));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('repeated tapping the thread directory opens only once', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session(SharedPrefs(await SharedPreferences.getInstance()));
    addTearDown(session.dispose);
    var opened = 0;
    final complete = Completer<void>();
    final gate = ActionGate();
    const identity = AutomationIdentity(
      id: 'assistant',
      name: 'assistant',
      displayName: 'Assistant',
      mode: 'api',
      defaultModel: '',
      models: [],
      privateDirectory: true,
    );
    const thread = AutomationThread(
      id: 1,
      identity: 'assistant',
      userId: 2,
      conversationId: 11,
      title: 'Thread',
      selectedModel: '',
      createdAt: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AutomationChatTools(
            session: session,
            identity: identity,
            thread: thread,
            actionGate: gate,
            onDirectory: () {
              opened++;
              return complete.future;
            },
            onConversationChanged: (_) {},
            onUpdated: () {},
          ),
        ),
      ),
    );
    final button = find.byKey(const ValueKey('automation-switch-thread'));
    await tester.tap(button);
    await tester.pump();
    await tester.tap(button, warnIfMissed: false);
    expect(opened, 1);
    complete.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
