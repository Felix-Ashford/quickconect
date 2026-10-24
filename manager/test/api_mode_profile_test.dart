import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_manager/main.dart';

void main() {
  test('API profile preserves identity, avatar, budget and independent prompts', () {
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
  });

  test('legacy API profiles get defaults and explicit empty prompts survive', () {
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
  });
}
