import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/android_keepalive.dart';
import '../core/ios_keepalive.dart';
import '../core/session.dart';
import '../core/action_gate.dart';
import '../core/models.dart';
import 'appearance_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _actions = ActionGate(
    onChanged: () {
      if (mounted) setState(() {});
    },
  );
  final _imagePicker = ImagePicker();
  bool _iosKeepAlive = false;
  bool _androidKeepAlive = false;
  late Future<int> _localMessageCount;
  late Future<int> _localMediaSize;

  @override
  void initState() {
    super.initState();
    final session = context.read<Session>();
    _iosKeepAlive = session.prefs.getBool('ios_keepalive') ?? false;
    _androidKeepAlive = session.prefs.getBool('android_keepalive') ?? false;
    _refreshLocalStats();
  }

  void _refreshLocalStats() {
    final session = context.read<Session>();
    _localMessageCount = session.localMessageCount();
    _localMediaSize = session.localMediaCacheSize();
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
            leading: _AvatarPreview(user: me, session: session),
            title: Text(me?.displayName ?? ''),
            subtitle: Text('@${me?.name ?? ''} · ${session.serverBase}'),
            trailing: IconButton(
              tooltip: '更换头像',
              icon: const Icon(Icons.camera_alt_outlined),
              onPressed: _actions.busy
                  ? null
                  : () => _actions.run(() => _changeAvatar(context)),
            ),
          ),
          const Divider(),

          // ---------- 本地聊天记录 ----------
          _SectionHeader('本地聊天记录'),
          SwitchListTile(
            secondary: const Icon(Icons.save_outlined),
            title: const Text('在本机保存聊天记录'),
            subtitle: const Text('关闭后停止保存新记录；已有记录可用下方操作清除'),
            value: session.localChatStorageEnabled,
            onChanged: _actions.busy
                ? null
                : (value) => _actions.run(() async {
                    await session.setLocalChatStorageEnabled(value);
                    if (mounted) setState(_refreshLocalStats);
                  }),
          ),
          FutureBuilder<int>(
            future: _localMessageCount,
            builder: (context, snapshot) => ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('本机聊天记录'),
              subtitle: Text(
                snapshot.hasData
                    ? '已保存 ${snapshot.data} 条消息，仅保存在本设备'
                    : '正在读取本地记录…',
              ),
            ),
          ),
          FutureBuilder<int>(
            future: _localMediaSize,
            builder: (context, snapshot) => ListTile(
              leading: const Icon(Icons.perm_media_outlined),
              title: const Text('本机附件缓存'),
              subtitle: Text(
                snapshot.hasData ? _formatBytes(snapshot.data!) : '正在统计…',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清除本机聊天记录'),
            subtitle: const Text('只删除本设备的缓存，不影响服务器和其他设备'),
            onTap: _actions.busy
                ? null
                : () => _actions.run(() => _confirmClearLocalHistory(context)),
          ),
          const Divider(),

          // ---------- 外观 ----------
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观定制'),
            subtitle: const Text('自定义配色、实时预览、保存预设方案'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _actions.busy
                ? null
                : () => _actions.run(
                    () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const AppearancePage()),
                    ),
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
              subtitle: Text(
                device.subscribeUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: '复制',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: device.subscribeUrl));
                  ScaffoldMessenger.of(this.context)
                      .showSnackBar(const SnackBar(content: Text('已复制订阅链接')));
                },
              ),
            ),
            Center(
              child: OutlinedButton.icon(
                onPressed: _actions.busy ? null : () => _actions.run(_sendTest),
                icon: const Icon(Icons.notifications_active_outlined, size: 18),
                label: const Text('发送测试通知'),
              ),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('设备信息未就绪，请重新进入本页', style: TextStyle(fontSize: 12)),
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
              onPressed: _actions.busy
                  ? null
                  : () => _actions.run(() => _confirmLogout(context)),
              icon: const Icon(Icons.logout),
              label: const Text('退出登录'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  /// 测试推送：交给服务器发（与真实消息走同一条路径），
  /// 这样「测试收到」就等于「真推送能收到」，而不是只测了手机的网络。
  Future<void> _sendTest() async {
    final api = context.read<Session>().api;
    if (api == null) return;
    try {
      await api.pushTest();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发送，请在 ntfy App 中查看')));
    } catch (e) {
      if (!mounted) return;
      final msg = '$e'.replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败：$msg')));
    }
  }

  Future<void> _changeAvatar(BuildContext context) async {
    final session = context.read<Session>();
    final picked = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 512,
      maxHeight: 512,
      imageQuality: 88,
    );
    if (picked == null || !context.mounted) return;
    try {
      final bytes = await picked.readAsBytes();
      await session.updateMyAvatar(bytes, name: picked.name);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('头像已更新')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('头像上传失败：$e')));
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
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<Session>().logout();
      if (context.mounted) Navigator.pop(context);
    }
  }

  Future<void> _confirmClearLocalHistory(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本机聊天记录？'),
        content: const Text('这会删除本设备保存的聊天缓存，但不会删除服务器记录。下次打开会话时，服务器历史仍会重新同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await context.read<Session>().clearLocalChatHistory();
    if (context.mounted) {
      setState(_refreshLocalStats);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('本机聊天记录已清除')));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
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

class _AvatarPreview extends StatelessWidget {
  final User? user;
  final Session session;
  const _AvatarPreview({required this.user, required this.session});

  @override
  Widget build(BuildContext context) {
    final name = user?.displayName.trim() ?? '';
    final initial = name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final mediaId = user?.avatarMediaId ?? '';
    if (mediaId.isEmpty) return CircleAvatar(child: Text(initial));
    return FutureBuilder<Uint8List>(
      future: session.mediaStore.downloadAvatar(mediaId),
      builder: (context, snapshot) => CircleAvatar(
        backgroundImage: snapshot.data == null
            ? null
            : MemoryImage(snapshot.data!),
        child: snapshot.data == null ? Text(initial) : null,
      ),
    );
  }
}
