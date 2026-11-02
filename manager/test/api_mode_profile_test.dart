import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_manager/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pending avatar saves offline and survives restart without leaking local path to VPS config', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final controller = ManagerController();
    addTearDown(controller.dispose);
    controller.automationProfiles.add(
      AutomationProfile(
        id: 'helper-id',
        name: 'helper',
        avatarMediaId: 'existing-avatar',
        avatarPath: 'C:/pictures/new-avatar.png',
      ),
    );
    await controller.saveAutomationProfiles();
    final remote = jsonDecode(controller.automationConfig) as Map;
    expect((remote['identities'] as List).single['avatar_path'], isNull);
    expect(
      (remote['identities'] as List).single['avatar_media_id'],
      'existing-avatar',
    );
    final restored = ManagerController();
    addTearDown(restored.dispose);
    await restored.load();
    expect(
      restored.automationProfiles.single.avatarPath,
      'C:/pictures/new-avatar.png',
    );
    await restored.writeAutomationConfig(restored.automationConfig);
    expect(restored.output, contains('请先连接目标 VPS'));
    expect(restored.automationProfiles.single.avatarPath, isNotEmpty);
    expect(restored.busy, isFalse);
  });

  test(
    'API profile preserves identity, avatar, budget and independent prompts',
    () {
      final profile = AutomationProfile(
        id: 'stable-id',
        name: 'helper',
        displayName: '助手',
        avatarMediaId: 'avatar-1',
        contextMaxChars: 75000,
        mentionSystemPrompt: 'mention only',
        directSystemPrompt: '',
        titleSystemPrompt: 'custom title',
        modelFallbacks: 'first, second',
      );
      final restored = AutomationProfile.fromJson(profile.toJson());
      expect(restored.id, 'stable-id');
      expect(restored.name, 'helper');
      expect(restored.avatarMediaId, 'avatar-1');
      expect(restored.contextMaxChars, 75000);
      expect(restored.mentionSystemPrompt, 'mention only');
      expect(restored.directSystemPrompt, '');
      expect(restored.titleSystemPrompt, 'custom title');
      expect(restored.toJson()['model_fallbacks'], ['first', 'second']);
      restored.displayName = '新名称';
      restored.avatarMediaId = 'avatar-2';
      expect(restored.name, profile.name);
      expect(restored.id, profile.id);
    },
  );

  test(
    'legacy API profiles get defaults and explicit empty prompts survive',
    () {
      final legacy = AutomationProfile.fromJson({'name': 'helper'});
      expect(legacy.contextMaxChars, 60000);
      expect(legacy.directSystemPrompt, isEmpty);
      expect(legacy.mentionSystemPrompt, defaultMentionPrompt);
      expect(legacy.titleSystemPrompt, defaultTitlePrompt);
      final empty = AutomationProfile.fromJson({
        'mention_system_prompt': '',
        'title_system_prompt': '',
      });
      expect(empty.mentionSystemPrompt, isEmpty);
      expect(empty.titleSystemPrompt, isEmpty);
    },
  );
}
