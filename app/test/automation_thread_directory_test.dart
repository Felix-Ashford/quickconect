import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/widgets/automation_thread_directory.dart';

AutomationThread thread(int id) => AutomationThread(
  id: id,
  identity: 'helper',
  userId: 1,
  conversationId: id,
  title: 'Thread $id',
  selectedModel: '',
  createdAt: id,
);

void main() {
  testWidgets(
    'deleting the current thread confirms once and selects replacement',
    (tester) async {
      final pending = Completer<AutomationThread?>();
      var deletes = 0;
      AutomationDirectorySelection? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result =
                      await showModalBottomSheet<AutomationDirectorySelection>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) => AutomationThreadDirectory(
                          name: 'Helper',
                          threads: [thread(1), thread(2)],
                          currentConversationId: 1,
                          createThread: () async => thread(3),
                          deleteThread: (item) {
                            expect(item.conversationId, 1);
                            deletes++;
                            return pending.future;
                          },
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
      final delete = find.byTooltip('删除对话').first;
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deletes, 0);
      expect(find.text('Thread 1'), findsOneWidget);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pump();
      expect(deletes, 1);
      final buttons = tester.widgetList<IconButton>(find.byType(IconButton));
      expect(buttons.every((button) => button.onPressed == null), isTrue);
      pending.complete(thread(2));
      await tester.pumpAndSettle();
      expect(result?.conversationId, 2);
      expect(find.byType(AutomationThreadDirectory), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
