import 'package:flutter_test/flutter_test.dart';
import 'package:quickconect_manager/main.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets('manager starts without a profile', (tester) async {
    await tester.pumpWidget(const ManagerApp());
    expect(find.text('QuickConect Manager'), findsOneWidget);
  });

  testWidgets('AI card exposes avatar and prompt editing without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    FlutterSecureStorage.setMockInitialValues({
      'profiles': jsonEncode([
        VpsProfile(name: 'Test VPS', host: 'localhost', keyPath: '').toJson(),
      ]),
      'automation-profiles': jsonEncode([
        AutomationProfile(name: 'helper', displayName: '助手').toJson(),
      ]),
    });
    await tester.pumpWidget(const ManagerApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 与自动化身份').first);
    await tester.pumpAndSettle();
    expect(find.text('上传并应用到 VPS'), findsOneWidget);
    await tester.ensureVisible(find.text('编辑头像、名称与配置'));
    await tester.tap(find.text('编辑头像、名称与配置'));
    await tester.pumpAndSettle();
    expect(find.text('选择头像').hitTestable(), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('编辑系统提示词'));
    await tester.tap(find.text('编辑系统提示词'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mention-system-prompt')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('独立对话默认系统提示词'), findsOneWidget);
    expect(find.text('对话标题总结提示词'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
