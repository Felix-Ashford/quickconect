import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_app/core/api_client.dart';
import 'package:quickconect_app/core/models.dart';
import 'package:quickconect_app/core/prefs.dart';
import 'package:quickconect_app/core/session.dart';

const identity = AutomationIdentity(
  id: 'helper',
  name: 'helper',
  displayName: 'Helper',
  mode: 'api',
  defaultModel: '',
  models: [],
  privateDirectory: true,
);

class DirectoryApi extends ApiClient {
  DirectoryApi({String server = 'https://one.example'}) : super(base: server);
  final threads = [
    for (final id in [30, 20, 10])
      AutomationThread(
        id: id,
        identity: 'helper',
        userId: 1,
        conversationId: id,
        title: '$id',
        selectedModel: '',
        createdAt: id,
      ),
  ];
  @override
  Future<List<AutomationThread>> automationThreads(String identity) async =>
      List.of(threads);
  @override
  Future<List<AutomationIdentity>> automationIdentities() async => [identity];
  @override
  Future<List<User>> users() async => [];
  @override
  Future<List<Conversation>> conversations() async => [];
}

Session makeSession(Prefs prefs, ApiClient api, {int user = 1}) =>
    Session(prefs)
      ..api = api
      ..me = User(id: user, name: 'user$user', displayName: 'User');

void main() {
  test('last selection survives Session recreation and does not choose newest thread', () async {
    final prefs = MemoryPrefs();
    await prefs.setBool('local_chat_enabled', false);
    final session = makeSession(prefs, DirectoryApi());
    await session.rememberAutomationThread('helper', 10);
    final restored = makeSession(prefs, DirectoryApi());
    expect(await restored.openAutomation(identity), 10);
    expect(restored.lastAutomationThreadId('helper'), 10);
    session.dispose();
    restored.dispose();
  });

  test('selection is isolated by account, server and identity; deleted selection falls back', () async {
    final prefs = MemoryPrefs();
    await prefs.setBool('local_chat_enabled', false);
    final api = DirectoryApi();
    final session = makeSession(prefs, api);
    await session.rememberAutomationThread('helper', 10);
    expect(session.lastAutomationThreadId('another-helper'), isNull);
    final otherUser = makeSession(prefs, DirectoryApi(), user: 2);
    expect(await otherUser.openAutomation(identity), 30);
    final otherServer = makeSession(
      prefs,
      DirectoryApi(server: 'https://two.example'),
    );
    expect(await otherServer.openAutomation(identity), 30);
    api.threads.removeWhere((t) => t.conversationId == 10);
    expect(await session.openAutomation(identity), 30);
    expect(session.lastAutomationThreadId('helper'), 30);
    for (final item in [session, otherUser, otherServer]) {
      item.dispose();
    }
  });
}
