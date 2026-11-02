import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';

Message revised(int revision, {bool retracted = false}) => Message(
  id: 'same-message',
  convId: 7,
  seq: 4,
  revision: revision,
  senderId: 2,
  senderName: 'Bob',
  type: 'text',
  payload: retracted
      ? {'retracted': true}
      : {
          'text': 'version $revision',
          if (revision > 0) 'edited_at': 1700000001,
        },
  createdAt: 1700000000,
  clientMsgId: 'stable-client-id',
);

void main() {
  test(
    'deleted AI reply stays deleted after stale sync and local serialization',
    () {
      final session = Session(MemoryPrefs());
      addTearDown(session.dispose);
      session.msgs[7] = [revised(0)];
      final tombstone = revised(5).toJson()..['payload'] = {'deleted': true};
      session.handleEvent({'type': 'message.updated', 'message': tombstone});
      session.handleEvent({
        'type': 'message.new',
        'message': revised(0).toJson(),
      });
      session.handleEvent({
        'type': 'message.updated',
        'message': revised(2).toJson(),
      });
      final restored = Message.fromJson(session.msgs[7]!.single.toJson());
      expect(restored.isDeleted, isTrue);
      expect(restored.text, isEmpty);
      expect(restored.revision, 5);
    },
  );

  test('message revisions survive local JSON serialization', () {
    final restored = Message.fromJson(revised(12).toJson());
    expect(restored.revision, 12);
    expect(restored.isEdited, isTrue);
    expect(restored.seq, 4);
    final old = revised(0).toJson()..remove('revision');
    expect(Message.fromJson(old).revision, 0);
  });

  test('updates replace in place, reject stale events and do not notify', () {
    final session = Session(MemoryPrefs());
    addTearDown(session.dispose);
    var notifications = 0;
    session.incomingNotifier = (_) => notifications++;
    session.msgs[7] = [revised(0)];
    session.convs[7] = Conversation(
      id: 7,
      type: 'dm',
      members: [],
      lastMessage: revised(0),
      unread: 3,
      lastSeq: 4,
    );
    void update(Message message) => session.handleEvent({
      'type': 'message.updated',
      'message': message.toJson(),
    });
    update(revised(2));
    update(revised(1));
    expect(session.msgs[7]!.single.text, 'version 2');
    expect(session.convs[7]!.lastMessage!.revision, 2);
    expect(session.convs[7]!.unread, 3);
    expect(notifications, 0);
    update(revised(3, retracted: true));
    expect(session.msgs[7]!.single.isRetracted, isTrue);
    expect(messagePreview(session.msgs[7]!.single), '消息已撤回');
    session.handleEvent({
      'type': 'message.new',
      'message': revised(0).toJson(),
    });
    expect(session.msgs[7]!.single.isRetracted, isTrue);
  });

  test('client refuses to edit or retract another user message', () async {
    final session = Session(MemoryPrefs())
      ..me = const User(id: 1, name: 'alice', displayName: 'Alice');
    addTearDown(session.dispose);
    await expectLater(
      session.editMessage(revised(0), 'changed'),
      throwsStateError,
    );
    await expectLater(session.retractMessage(revised(0)), throwsStateError);
  });

  test('delayed send acknowledgement preserves newer edit from websocket', () {
    final session = Session(MemoryPrefs());
    addTearDown(session.dispose);
    session.msgs[7] = [
      revised(4),
      Message.pending(
        convId: 7,
        senderId: 2,
        senderName: 'Bob',
        type: 'text',
        payload: {'text': 'initial'},
        clientMsgId: 'stable-client-id',
      ),
    ];
    session.debugReplacePending('stable-client-id', revised(0));
    expect(session.msgs[7]!.length, 1);
    expect(session.msgs[7]!.single.revision, 4);
  });

  test('local conversation preserves contact avatars', () {
    const conv = Conversation(
      id: 1,
      type: 'dm',
      members: [
        User(id: 2, name: 'bob', displayName: 'Bob', avatarMediaId: 'avatar'),
      ],
      unread: 0,
      lastSeq: 0,
    );
    expect(
      Conversation.fromJson(conv.toJson()).members.single.avatarMediaId,
      'avatar',
    );
  });
}
