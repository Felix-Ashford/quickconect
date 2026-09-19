import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/android_keepalive.dart';
import '../core/ios_keepalive.dart';
import '../core/session.dart';
import 'appearance_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _iosKeepAlive = false;
  bool _androidKeepAlive = false;

  @override
  void initState() {
    super.initState();
    final session = context.read<Session>();
    _iosKeepAlive = session.prefs.getBool('ios_keepalive') ?? false;
    _androidKeepAlive = session.prefs.getBool('android_keepalive') ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<Session>();
    final me = session.me;
    final device = session.device;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          // ---------- 账号 ----------
          ListTile(
            leading: CircleAvatar(
              child: Text(me != null && me.displayName.isNotEmpty ? me.displayName[0] : '?'),
            ),
            title: Text(me?.displayName ?? ''),
            subtitle: Text('@${me?.name ?? ''} · ${session.serverBase}'),
          ),
          const Divider(),

          // ---------- 外观 ----------
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观定制'),
            subtitle: const Text('自定义配色、实时预览、保存预设方案'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppearancePage()),
            ),
          ),

          // ---------- 推送铃 ----------
          _SectionHeader('推送铃（App 被杀后的离线通知）'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '免费签名的 App 拿不到苹果推送，由 ntfy App 代为转达：'
              '手机上安装 ntfy（App Store 或 ntfy.sh 下载），用下面的二维码或链接订阅本设备专属频道。'
              '消息内容不会经过第三方，仅有「您有 N 条新消息」的提醒。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (device != null && device.pushTopic.isNotEmpty) ...[
            const SizedBox(height: 12),
            Center(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: device.subscribeUrl,
                  size: 150,
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('订阅链接', style: TextStyle(fontSize: 13)),
              subtitle: Text(device.subscribeUrl,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: device.subscribeUrl));
                  ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('已复制订阅链接')));
                },
              ),
            ),
            Center(
              child: OutlinedButton.icon(
                onPressed: () => _sendTest(device.pushTopic),
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: const Text('发送测试通知'),
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('设备信息未就绪，请重新进入本页',
                  style: TextStyle(fontSize: 12)),
            ),
          const Divider(),

          // ---------- 平台专属保活 ----------
          if (Platform.isIOS) ...[
            _SectionHeader('保持在线（iOS）'),
            SwitchListTile(
              title: const Text('静音保活'),
              subtitle: const Text('后台播放静音音频防止系统挂起，通知实时；耗电会增加'),
              value: _iosKeepAlive,
              onChanged: (v) async {
                await IosKeepAlive.setEnabled(v);
                await session.prefs.setBool('ios_keepalive', v);
                if (mounted) setState(() => _iosKeepAlive = v);
              },
            ),
            const Divider(),
          ],
          if (Platform.isAndroid) ...[
            _SectionHeader('后台保持连接（Android）'),
            SwitchListTile(
              title: const Text('前台服务'),
              subtitle: const Text('常驻通知保持连接，退到后台后消息仍实时'),
              value: _androidKeepAlive,
              onChanged: (v) async {
                await AndroidKeepAlive.setEnabled(v);
                await session.prefs.setBool('android_keepalive', v);
                if (mounted) setState(() => _androidKeepAlive = v);
              },
            ),
            ListTile(
              leading: const Icon(Icons.battery_saver_outlined),
              title: const Text('申请忽略电池优化'),
              subtitle: const Text('国产系统更不容易杀后台'),
              onTap: () async {
                await Permission.ignoreBatteryOptimizations.request();
              },
            ),
            const Divider(),
          ],

          // ---------- 关于 ----------
          _SectionHeader('关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('QuickConect'),
            subtitle: Text('私人即时通讯 · 数据自持'),
          ),
          const SizedBox(height: 24),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: () => _confirmLogout(context),
              icon: const Icon(Icons.logout),
              label: const Text('退出登录'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Future<void> _sendTest(String topic) async {
    try {
      final resp = await http
          .post(
            Uri.parse('https://ntfy.sh/$topic'),
            headers: {'Title': 'QuickConect 测试'},
            body: '推送铃配置成功！收到这条说明 ntfy 通知链路正常。',
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(resp.statusCode < 300
            ? '已发送，请在 ntfy App 中查看'
            : 'ntfy 返回 ${resp.statusCode}'),
      ));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    }
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<Session>().logout();
      if (context.mounted) Navigator.pop(context);
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
