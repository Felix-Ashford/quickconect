import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';
import 'package:quickconect_app/core/theme_scheme.dart';
import 'package:quickconect_app/widgets/message_bubble.dart';
import 'package:quickconect_app/pages/chat_page.dart';
import 'package:quickconect_app/widgets/contact_picker.dart';

void main() {
  testWidgets(
    'excluded reply uses custom color without context text and keeps delete action',
    (tester) async {
      final session = Session(MemoryPrefs());
      addTearDown(session.dispose);
      var deletions = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: session,
          child: MaterialApp(
            theme: buildQcTheme(
              QcScheme.builtIns.first.copyWith(excludedAiBubble: Colors.pink),
            ),
            home: Scaffold(
              body: MessageBubble(
                message: Message(
                  id: 'excluded',
                  convId: 1,
                  seq: 2,
                  senderId: 2,
                  senderName: 'Helper',
                  type: 'text',
                  payload: {'text': 'Old answer'},
                  createdAt: 1700000000,
                  clientMsgId: 'excluded',
                ),
                isMine: false,
                isAutomation: true,
                excludedFromAIContext: true,
                onDelete: () => deletions++,
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('不在 AI 上下文'), findsNothing);
      final surface = tester.widget<Container>(
        find.byKey(const ValueKey('message-surface-excluded')),
      );
      expect((surface.decoration as BoxDecoration).color, Colors.pink);
      await tester.tap(find.byTooltip('消息操作'));
      await tester.pumpAndSettle();
      expect(find.text('修改消息'), findsNothing);
      expect(find.text('撤回消息'), findsNothing);
      await tester.tap(find.text('删除上下文外消息'));
      await tester.pumpAndSettle();
      expect(deletions, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('short messages and images fit content; history starts at top', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session(SharedPrefs(await SharedPreferences.getInstance()));
    addTearDown(session.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    session.me = const User(id: 1, name: 'alice', displayName: 'Alice');
    session.msgs[1] = [
      Message(
        id: 'short',
        convId: 1,
        seq: 1,
        senderId: 1,
        senderName: 'Alice',
        type: 'text',
        format: 'markdown',
        payload: {'text': 'Hello'},
        createdAt: 1700000000,
        clientMsgId: 'short',
      ),
      Message(
        id: 'image',
        convId: 1,
        seq: 2,
        senderId: 2,
        senderName: 'Bob',
        type: 'image',
        payload: {'w': 200, 'h': 200},
        createdAt: 1700000001,
        clientMsgId: 'image',
      ),
    ];
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: const MaterialApp(home: ChatPage(convId: 1)),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final first = tester.getRect(
      find.byKey(const ValueKey('message-surface-short')),
    );
    final image = tester.getRect(
      find.byKey(const ValueKey('message-surface-image')),
    );
    expect(first.width, lessThan(300));
    expect(image.width, lessThan(260));
    expect(first.top, lessThan(120));
    expect(image.top, greaterThan(first.top));
    expect(image.bottom, lessThan(600));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('directory shows people without prior chats with avatars', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session(SharedPrefs(await SharedPreferences.getInstance()));
    addTearDown(session.dispose);
    session.me = const User(id: 1, name: 'alice', displayName: 'Alice');
    session.users = [
      session.me!,
      const User(id: 2, name: 'bob', displayName: 'Bob'),
      const User(id: 3, name: 'carol', displayName: 'Carol'),
    ];
    session.convs[9] = Conversation(
      id: 9,
      type: 'dm',
      members: [
        session.me!,
        const User(id: 4, name: 'removed', displayName: 'Deleted user'),
      ],
      unread: 0,
      lastSeq: 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ContactPicker(session: session)),
      ),
    );
    expect(find.text('Carol'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
    expect(find.byType(MessageAvatar), findsNWidgets(2));
    expect(find.text('Deleted user'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('message surface follows available chat width across resizes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final session = Session(SharedPrefs(await SharedPreferences.getInstance()));
    addTearDown(session.dispose);
    addTearDown(() => tester.view.resetPhysicalSize());
    addTearDown(() => tester.view.resetDevicePixelRatio());
    tester.view.devicePixelRatio = 1;
    final message = Message(
      id: 'layout',
      convId: 1,
      seq: 1,
      senderId: 1,
      senderName: 'Test',
      type: 'text',
      format: 'markdown',
      payload: {'text': List.filled(120, 'message').join(' ')},
      createdAt: 1700000000,
      clientMsgId: 'layout',
    );
    for (final width in [375.0, 964.0, 1600.0, 375.0]) {
      tester.view.physicalSize = Size(width, 1200);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: session,
          child: MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [MessageBubble(message: message, isMine: true)],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rect = tester.getRect(
        find.byKey(const ValueKey('message-surface-layout')),
      );
      expect(rect.width, closeTo(width - 52, 0.01));
      expect(rect.right, closeTo(width, 0.01));
    }
    await tester.pumpWidget(const SizedBox());
  });
}
