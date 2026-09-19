/// 键值存储抽象：生产用 SharedPreferences，测试用内存实现。
///
/// Session 与证书锁定只依赖这个接口，避免被平台插件绑死（flutter test
/// 的绑定会拦截真实网络，纯 Dart 测试需要完全脱离它）。
library;

import 'package:shared_preferences/shared_preferences.dart';

abstract class Prefs {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
  List<String>? getStringList(String key);
  Future<void> setStringList(String key, List<String> value);
  bool? getBool(String key);
  Future<void> setBool(String key, bool value);
}

/// 生产实现。
class SharedPrefs implements Prefs {
  final SharedPreferences _p;
  SharedPrefs(this._p);

  @override
  String? getString(String key) => _p.getString(key);
  @override
  Future<void> setString(String key, String value) => _p.setString(key, value);
  @override
  Future<void> remove(String key) => _p.remove(key);
  @override
  List<String>? getStringList(String key) => _p.getStringList(key);
  @override
  Future<void> setStringList(String key, List<String> value) =>
      _p.setStringList(key, value);
  @override
  bool? getBool(String key) => _p.getBool(key);
  @override
  Future<void> setBool(String key, bool value) => _p.setBool(key, value);
}

/// 测试实现。
class MemoryPrefs implements Prefs {
  final Map<String, Object> _m = {};

  @override
  String? getString(String key) => _m[key] as String?;
  @override
  Future<void> setString(String key, String value) async {
    _m[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _m.remove(key);
  }

  @override
  List<String>? getStringList(String key) => _m[key] as List<String>?;
  @override
  Future<void> setStringList(String key, List<String> value) async {
    _m[key] = List<String>.from(value);
  }

  @override
  bool? getBool(String key) => _m[key] as bool?;
  @override
  Future<void> setBool(String key, bool value) async {
    _m[key] = value;
  }
}
