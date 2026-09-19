/// 证书锁定：客户端只信任指纹匹配的自签服务器证书。
///
/// 机制：main() 启动时安装全局 HttpOverrides，所有 dart:io 的 HTTPS
/// （REST 与 WebSocket 都在内）在校验失败时回调这里；只有当对端证书的
/// SHA-256 指纹在受信集合内才放行。
///
/// 指纹来源两种：
///  1. 登录页「证书指纹」栏粘贴（部署服务器上 gen_certs.sh 会打印）；
///  2. 后续正式版可内置到 assets（实现位：PinningStore.loadBundled）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'prefs.dart';

class PinningStore {
  /// 受信任的证书 SHA-256 指纹（小写十六进制，无冒号）。
  static final Set<String> accepted = {};

  static const _prefsKey = 'pinned_fingerprints';

  /// 启动时从本地存储恢复。
  static void loadFromPrefs(Prefs prefs) {
    accepted
      ..clear()
      ..addAll(prefs.getStringList(_prefsKey) ?? const []);
  }

  /// 归一化用户粘贴的指纹（去冒号/空格、转小写），校验为 64 位十六进制。
  static String? normalizeFingerprint(String raw) {
    final hex = raw.replaceAll(':', '').replaceAll(' ', '').toLowerCase();
    if (hex.length != 64) return null;
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(hex)) return null;
    return hex;
  }

  static Future<void> trust(Prefs prefs, String fingerprint) async {
    accepted.add(fingerprint);
    await prefs.setStringList(_prefsKey, accepted.toList());
  }

  static String fingerprintOf(X509Certificate cert) =>
      sha256.convert(cert.der).toString();

  /// 对端证书指纹是否受信。
  static bool isTrusted(X509Certificate cert) =>
      accepted.contains(fingerprintOf(cert));
}

class PinningOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) {
      return PinningStore.isTrusted(cert);
    };
    return client;
  }
}

/// 工具：从 PEM 文本提取 DER 并算指纹（供「导出/展示」场景复用）。
String? fingerprintFromPem(String pem) {
  final b64 = pem
      .split(RegExp(r'-----[A-Z ]+-----'))
      .map((s) => s.replaceAll(RegExp(r'\s'), ''))
      .where((s) => s.length > 32)
      .join();
  try {
    final der = base64Decode(b64);
    return sha256.convert(der).toString();
  } catch (_) {
    return null;
  }
}
