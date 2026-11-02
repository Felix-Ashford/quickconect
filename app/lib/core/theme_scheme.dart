/// 主题定制系统：九项可自定义颜色 + 内置/用户预设 + 持久化。
///
/// 应用方式：ThemeData（primary/顶栏/背景）+ ThemeExtension（气泡等聊天专属色），
/// 控件层统一从 `Theme.of(context)` 取色，改色即时生效。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';

import 'prefs.dart';

/// 一套配色方案。
@immutable
class QcScheme {
  final String name;
  final Color primary; // 主色调（按钮、链接、强调）
  final Color appBar; // 顶栏背景
  final Color scaffoldBg; // 界面背景（列表/设置页）
  final Color chatBg; // 聊天背景
  final Color myBubble; // 我的气泡
  final Color myBubbleText;
  final Color otherBubble; // 对方气泡
  final Color otherBubbleText;
  final Color aiBubble;
  final Color aiBubbleText;
  final Color excludedAiBubble;
  final Color excludedAiBubbleText;
  final Color unreadBadge; // 未读角标

  const QcScheme({
    required this.name,
    required this.primary,
    required this.appBar,
    required this.scaffoldBg,
    required this.chatBg,
    required this.myBubble,
    required this.myBubbleText,
    required this.otherBubble,
    required this.otherBubbleText,
    Color? aiBubble,
    Color? aiBubbleText,
    Color? excludedAiBubble,
    Color? excludedAiBubbleText,
    required this.unreadBadge,
  }) : aiBubble = aiBubble ?? otherBubble,
       aiBubbleText = aiBubbleText ?? otherBubbleText,
       excludedAiBubble = excludedAiBubble ?? const Color(0xFFFFE0B2),
       excludedAiBubbleText = excludedAiBubbleText ?? const Color(0xFF4E342E);

  QcScheme copyWith({
    String? name,
    Color? primary,
    Color? appBar,
    Color? scaffoldBg,
    Color? chatBg,
    Color? myBubble,
    Color? myBubbleText,
    Color? otherBubble,
    Color? otherBubbleText,
    Color? aiBubble,
    Color? aiBubbleText,
    Color? excludedAiBubble,
    Color? excludedAiBubbleText,
    Color? unreadBadge,
  }) => QcScheme(
    name: name ?? this.name,
    primary: primary ?? this.primary,
    appBar: appBar ?? this.appBar,
    scaffoldBg: scaffoldBg ?? this.scaffoldBg,
    chatBg: chatBg ?? this.chatBg,
    myBubble: myBubble ?? this.myBubble,
    myBubbleText: myBubbleText ?? this.myBubbleText,
    otherBubble: otherBubble ?? this.otherBubble,
    otherBubbleText: otherBubbleText ?? this.otherBubbleText,
    aiBubble: aiBubble ?? this.aiBubble,
    aiBubbleText: aiBubbleText ?? this.aiBubbleText,
    excludedAiBubble: excludedAiBubble ?? this.excludedAiBubble,
    excludedAiBubbleText: excludedAiBubbleText ?? this.excludedAiBubbleText,
    unreadBadge: unreadBadge ?? this.unreadBadge,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'primary': primary.toARGB32(),
    'appBar': appBar.toARGB32(),
    'scaffoldBg': scaffoldBg.toARGB32(),
    'chatBg': chatBg.toARGB32(),
    'myBubble': myBubble.toARGB32(),
    'myBubbleText': myBubbleText.toARGB32(),
    'otherBubble': otherBubble.toARGB32(),
    'otherBubbleText': otherBubbleText.toARGB32(),
    'aiBubble': aiBubble.toARGB32(),
    'aiBubbleText': aiBubbleText.toARGB32(),
    'excludedAiBubble': excludedAiBubble.toARGB32(),
    'excludedAiBubbleText': excludedAiBubbleText.toARGB32(),
    'unreadBadge': unreadBadge.toARGB32(),
  };

  factory QcScheme.fromJson(Map<String, dynamic> j) => QcScheme(
    name: j['name'] as String? ?? '自定义',
    primary: Color(j['primary'] as int),
    appBar: Color(j['appBar'] as int),
    scaffoldBg: Color(j['scaffoldBg'] as int),
    chatBg: Color(j['chatBg'] as int),
    myBubble: Color(j['myBubble'] as int),
    myBubbleText: Color(j['myBubbleText'] as int),
    otherBubble: Color(j['otherBubble'] as int),
    otherBubbleText: Color(j['otherBubbleText'] as int),
    aiBubble: j['aiBubble'] is int ? Color(j['aiBubble'] as int) : null,
    aiBubbleText: j['aiBubbleText'] is int
        ? Color(j['aiBubbleText'] as int)
        : null,
    excludedAiBubble: j['excludedAiBubble'] is int
        ? Color(j['excludedAiBubble'] as int)
        : null,
    excludedAiBubbleText: j['excludedAiBubbleText'] is int
        ? Color(j['excludedAiBubbleText'] as int)
        : null,
    unreadBadge: Color(j['unreadBadge'] as int),
  );

  /// 深浅自动判断（供派生文字/图标色参考）。
  bool get isLight => scaffoldBg.computeLuminance() > 0.5;

  /// 在某背景色上的自动对比色。
  static Color contrastOn(Color bg) => bg.computeLuminance() > 0.5
      ? const Color(0xFF1C1C1C)
      : const Color(0xFFF5F5F5);

  // ---------- 内置预设 ----------

  static const builtIns = <QcScheme>[
    // 青绿（默认，即原版观感）
    QcScheme(
      name: '青绿',
      primary: Color(0xFF00897B),
      appBar: Color(0xFFCDE8E0),
      scaffoldBg: Color(0xFFF0F4EF),
      chatBg: Color(0xFFEFF5F0),
      myBubble: Color(0xFFB7E7DC),
      myBubbleText: Color(0xFF173B34),
      otherBubble: Color(0xFFE3EAE4),
      otherBubbleText: Color(0xFF1C1C1C),
      unreadBadge: Color(0xFFE53935),
    ),
    // 微信经典
    QcScheme(
      name: '微信绿',
      primary: Color(0xFF07C160),
      appBar: Color(0xFFEDEDED),
      scaffoldBg: Color(0xFFEDEDED),
      chatBg: Color(0xFFEDEDED),
      myBubble: Color(0xFF95EC69),
      myBubbleText: Color(0xFF17341B),
      otherBubble: Color(0xFFFFFFFF),
      otherBubbleText: Color(0xFF1C1C1C),
      unreadBadge: Color(0xFFFA5151),
    ),
    // 暗夜
    QcScheme(
      name: '暗夜',
      primary: Color(0xFF4DB6AC),
      appBar: Color(0xFF16211F),
      scaffoldBg: Color(0xFF101615),
      chatBg: Color(0xFF151D1B),
      myBubble: Color(0xFF1F4740),
      myBubbleText: Color(0xFFD9F2EC),
      otherBubble: Color(0xFF242C2A),
      otherBubbleText: Color(0xFFE0E6E4),
      unreadBadge: Color(0xFFFF7043),
    ),
    // 樱花粉
    QcScheme(
      name: '樱花粉',
      primary: Color(0xFFEC6A9C),
      appBar: Color(0xFFFBDDE7),
      scaffoldBg: Color(0xFFFDF3F6),
      chatBg: Color(0xFFFFF5F8),
      myBubble: Color(0xFFF9C2D4),
      myBubbleText: Color(0xFF4A1F2E),
      otherBubble: Color(0xFFFFFFFF),
      otherBubbleText: Color(0xFF3A2A30),
      unreadBadge: Color(0xFFE91E63),
    ),
    // 海盐蓝
    QcScheme(
      name: '海盐蓝',
      primary: Color(0xFF1E88E5),
      appBar: Color(0xFFD6E8FA),
      scaffoldBg: Color(0xFFF2F7FB),
      chatBg: Color(0xFFF3F8FD),
      myBubble: Color(0xFFBBDEFB),
      myBubbleText: Color(0xFF0D2A45),
      otherBubble: Color(0xFFFFFFFF),
      otherBubbleText: Color(0xFF1C1C1C),
      unreadBadge: Color(0xFFFFB300),
    ),
  ];
}

/// 聊天专属色通过 ThemeExtension 下发，气泡/面板统一取用。
@immutable
class QcColors extends ThemeExtension<QcColors> {
  final Color myBubble;
  final Color myBubbleText;
  final Color otherBubble;
  final Color otherBubbleText;
  final Color aiBubble;
  final Color aiBubbleText;
  final Color excludedAiBubble;
  final Color excludedAiBubbleText;
  final Color chatBg;
  final Color unreadBadge;

  const QcColors({
    required this.myBubble,
    required this.myBubbleText,
    required this.otherBubble,
    required this.otherBubbleText,
    required this.aiBubble,
    required this.aiBubbleText,
    required this.excludedAiBubble,
    required this.excludedAiBubbleText,
    required this.chatBg,
    required this.unreadBadge,
  });

  factory QcColors.ofScheme(QcScheme s) => QcColors(
    myBubble: s.myBubble,
    myBubbleText: s.myBubbleText,
    otherBubble: s.otherBubble,
    otherBubbleText: s.otherBubbleText,
    aiBubble: s.aiBubble,
    aiBubbleText: s.aiBubbleText,
    excludedAiBubble: s.excludedAiBubble,
    excludedAiBubbleText: s.excludedAiBubbleText,
    chatBg: s.chatBg,
    unreadBadge: s.unreadBadge,
  );

  @override
  QcColors lerp(QcColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return QcColors(
      myBubble: c(myBubble, other.myBubble),
      myBubbleText: c(myBubbleText, other.myBubbleText),
      otherBubble: c(otherBubble, other.otherBubble),
      otherBubbleText: c(otherBubbleText, other.otherBubbleText),
      aiBubble: c(aiBubble, other.aiBubble),
      aiBubbleText: c(aiBubbleText, other.aiBubbleText),
      excludedAiBubble: c(excludedAiBubble, other.excludedAiBubble),
      excludedAiBubbleText: c(excludedAiBubbleText, other.excludedAiBubbleText),
      chatBg: c(chatBg, other.chatBg),
      unreadBadge: c(unreadBadge, other.unreadBadge),
    );
  }

  @override
  QcColors copyWith({
    Color? myBubble,
    Color? myBubbleText,
    Color? otherBubble,
    Color? otherBubbleText,
    Color? aiBubble,
    Color? aiBubbleText,
    Color? excludedAiBubble,
    Color? excludedAiBubbleText,
    Color? chatBg,
    Color? unreadBadge,
  }) => QcColors(
    myBubble: myBubble ?? this.myBubble,
    myBubbleText: myBubbleText ?? this.myBubbleText,
    otherBubble: otherBubble ?? this.otherBubble,
    otherBubbleText: otherBubbleText ?? this.otherBubbleText,
    aiBubble: aiBubble ?? this.aiBubble,
    aiBubbleText: aiBubbleText ?? this.aiBubbleText,
    excludedAiBubble: excludedAiBubble ?? this.excludedAiBubble,
    excludedAiBubbleText: excludedAiBubbleText ?? this.excludedAiBubbleText,
    chatBg: chatBg ?? this.chatBg,
    unreadBadge: unreadBadge ?? this.unreadBadge,
  );
}

/// 由配色方案构建完整 ThemeData。
ThemeData buildQcTheme(QcScheme s) {
  final brightness = s.isLight ? Brightness.light : Brightness.dark;
  final seeded = ColorScheme.fromSeed(
    seedColor: s.primary,
    brightness: brightness,
  );
  final colorScheme = seeded.copyWith(
    primary: s.primary,
    surface: s.scaffoldBg,
    surfaceContainerHighest: s.otherBubble,
  );
  return ThemeData(
    // Windows 中文优先使用系统内置简体字形，避免 CJK 回退选中日文字体。
    fontFamily: defaultTargetPlatform == TargetPlatform.windows
        ? 'Microsoft YaHei UI'
        : null,
    fontFamilyFallback: defaultTargetPlatform == TargetPlatform.windows
        ? const ['Microsoft YaHei', 'Segoe UI', 'Segoe UI Emoji']
        : null,
    colorScheme: colorScheme,
    useMaterial3: true,
    scaffoldBackgroundColor: s.scaffoldBg,
    appBarTheme: AppBarTheme(
      backgroundColor: s.appBar,
      foregroundColor: QcScheme.contrastOn(s.appBar),
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    dividerTheme: DividerThemeData(
      color: s.isLight
          ? Colors.black.withValues(alpha: 0.08)
          : Colors.white.withValues(alpha: 0.08),
    ),
    extensions: <ThemeExtension<dynamic>>[QcColors.ofScheme(s)],
  );
}

/// 取聊天专属色。
QcColors qcColorsOf(BuildContext context) =>
    Theme.of(context).extension<QcColors>() ??
    QcColors.ofScheme(QcScheme.builtIns.first);

/// 主题控制器：当前方案 + 用户预设的持久化与切换。
class ThemeController extends ChangeNotifier {
  static const _curKey = 'theme_scheme';
  static const _presetsKey = 'theme_presets';

  final Prefs prefs;
  QcScheme scheme;
  List<QcScheme> userPresets;

  ThemeController(this.prefs)
    : scheme = QcScheme.builtIns.first,
      userPresets = const [];

  Future<void> load() async {
    final cur = prefs.getString(_curKey);
    if (cur != null) {
      try {
        scheme = QcScheme.fromJson(jsonDecodeMap(cur));
      } catch (_) {}
    }
    final raw = prefs.getString(_presetsKey);
    if (raw != null) {
      try {
        userPresets = (jsonDecodeList(raw))
            .map((j) => QcScheme.fromJson(j))
            .toList();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// 应用并持久化当前方案。
  Future<void> apply(QcScheme s) async {
    scheme = s;
    await prefs.setString(_curKey, jsonEncodeMap(s.toJson()));
    notifyListeners();
  }

  /// 把当前方案存为用户预设；同名覆盖。
  Future<void> savePreset(String name) async {
    final s = scheme.copyWith(name: name);
    userPresets = [
      for (final p in userPresets)
        if (p.name != name) p,
      s,
    ];
    await _savePresets();
    await apply(s);
  }

  Future<void> deletePreset(String name) async {
    userPresets = [
      for (final p in userPresets)
        if (p.name != name) p,
    ];
    await _savePresets();
    notifyListeners();
  }

  Future<void> _savePresets() async {
    await prefs.setString(
      _presetsKey,
      jsonEncodeList(userPresets.map((p) => p.toJson()).toList()),
    );
  }
}

// ---------- JSON ----------

Map<String, dynamic> jsonDecodeMap(String raw) =>
    (jsonDecode(raw) as Map).cast<String, dynamic>();

List<Map<String, dynamic>> jsonDecodeList(String raw) =>
    (jsonDecode(raw) as List).cast<Map<String, dynamic>>();

String jsonEncodeMap(Map<String, dynamic> map) => jsonEncode(map);

String jsonEncodeList(List<Map<String, dynamic>> list) => jsonEncode(list);
