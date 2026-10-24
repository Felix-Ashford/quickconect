import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_manager/main.dart';

void main() {
  test('reads first usable client key from v8 access section', () {
    expect(ManagerController.parseCliProxyApiKey('''
config-version: 8
access:
  api-keys: ['', actual-client-key, another-key]
api-keys:
  codex:
    - api-key: upstream-provider-secret
'''), 'actual-client-key');
  });

  test('reads legacy client keys', () {
    expect(ManagerController.parseCliProxyApiKey('''
api-keys: [legacy-client-key]
'''), 'legacy-client-key');
  });

  test('explicit empty v8 keys override legacy keys', () {
    expect(ManagerController.parseCliProxyApiKey('''
access:
  api-keys: []
api-keys: [obsolete-key]
'''), '');
  });

  test('provider keys are never mistaken for client keys', () {
    expect(ManagerController.parseCliProxyApiKey('''
api-keys:
  codex:
    - api-key: upstream-provider-secret
'''), '');
    expect(ManagerController.parseCliProxyApiKey('null'), '');
  });
}
