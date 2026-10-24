import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/cert_pinning.dart';
import '../core/session.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _fingerprint = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final s = context.read<Session>();
    _server.text = s.serverBase;
    _username.text = s.prefs.getString('last_username') ?? '';
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _fingerprint.dispose();
    super.dispose();
  }

  String get _defaultDeviceName {
    if (Platform.isWindows) return 'Windows 电脑';
    if (Platform.isIOS) return 'iPhone/iPad';
    if (Platform.isAndroid) return 'Android 手机';
    return '未知设备';
  }

  Future<void> _submit() async {
    final session = context.read<Session>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final isSecure =
          !_server.text.trim().startsWith('http://') &&
          _server.text.trim().isNotEmpty;
      final fpRaw = _fingerprint.text.trim();
      if (isSecure) {
        final fp = PinningStore.normalizeFingerprint(fpRaw);
        if (fpRaw.isEmpty) {
          setState(() => _error = 'HTTPS 服务器需要填写证书指纹（向管理员索取，64 位十六进制）');
          return;
        }
        if (fp == null) {
          setState(() => _error = '证书指纹格式不对：应为 64 位十六进制（可带冒号或空格，大小写不限）');
          return;
        }
        await PinningStore.trust(session.prefs, fp);
      }
      await session.login(
        server: _server.text,
        username: _username.text.trim(),
        password: _password.text,
        deviceName: _defaultDeviceName,
        platform: Platform.operatingSystem,
      );
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isHttp = _server.text.trim().startsWith('http://');
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.chat_bubble_rounded, size: 64, color: cs.primary),
                const SizedBox(height: 8),
                Text(
                  'QuickConect',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _server,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '服务器地址',
                    hintText: '例如 1.2.3.4:8443',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.dns_outlined),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (isHttp) ...[
                  const SizedBox(height: 8),
                  Text(
                    '使用 http:// 明文连接（仅限本地调试）',
                    style: TextStyle(color: cs.error, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _username,
                  decoration: const InputDecoration(
                    labelText: '用户名',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _fingerprint,
                  decoration: const InputDecoration(
                    labelText: '证书指纹（https 时必填，向管理员索取）',
                    hintText: '64 位十六进制',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                ),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(color: cs.error, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                ],
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.all(16),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
