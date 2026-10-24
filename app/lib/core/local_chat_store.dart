import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 本地聊天记录仓库。每个服务器账号使用独立文件，避免切换账号时串数据。
/// 只保存已获得服务器序号的消息；图片、文件和语音正文仍通过 media_id 从服务器取得。
class LocalChatStore {
  final String server;
  final String username;
  File? _file;

  LocalChatStore({required this.server, required this.username});

  Future<File> _resolveFile() async {
    final dir = await getApplicationSupportDirectory();
    final key = sha256.convert(utf8.encode('$server\n$username')).toString();
    final folder = Directory('${dir.path}${Platform.pathSeparator}QuickConect');
    await folder.create(recursive: true);
    final file = _file ??= File(
      '${folder.path}${Platform.pathSeparator}chat_$key.json',
    );
    final backup = File('${file.path}.bak');
    if (!await file.exists() && await backup.exists()) {
      await backup.rename(file.path);
    }
    return file;
  }

  Future<
    ({Map<int, List<Message>> messages, Map<int, Conversation> conversations})
  >
  load() async {
    final file = await _resolveFile();
    if (!await file.exists()) {
      return (
        messages: <int, List<Message>>{},
        conversations: <int, Conversation>{},
      );
    }
    try {
      final root =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final rawMessages = root['messages'] as Map<String, dynamic>? ?? root;
      final rawConversations =
          root['conversations'] as Map<String, dynamic>? ?? const {};
      final result = <int, List<Message>>{};
      final conversations = <int, Conversation>{};
      for (final entry in rawConversations.entries) {
        final convId = int.tryParse(entry.key);
        if (convId == null || entry.value is! Map) continue;
        try {
          conversations[convId] = Conversation.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        } catch (_) {}
      }
      for (final entry in rawMessages.entries) {
        final convId = int.tryParse(entry.key);
        final values = entry.value;
        if (convId == null || values is! List) continue;
        final messages = <Message>[];
        for (final value in values) {
          if (value is! Map) continue;
          try {
            final message = Message.fromJson(Map<String, dynamic>.from(value));
            if (!message.isPending) messages.add(message);
          } catch (_) {
            // 单条损坏记录不应阻止其余历史恢复。
          }
        }
        messages.sort((a, b) => a.seq.compareTo(b.seq));
        if (messages.isNotEmpty) result[convId] = messages;
      }
      return (messages: result, conversations: conversations);
    } catch (_) {
      return (
        messages: <int, List<Message>>{},
        conversations: <int, Conversation>{},
      );
    }
  }

  Future<void> save(
    Map<int, List<Message>> messages,
    Map<int, Conversation> conversations,
  ) async {
    final file = await _resolveFile();
    final root = <String, dynamic>{};
    for (final entry in messages.entries) {
      final saved = entry.value
          .where((m) => !m.isPending)
          .map((m) => m.toJson())
          .toList();
      if (saved.isNotEmpty) root['${entry.key}'] = saved;
    }
    final temp = File('${file.path}.tmp');
    final convRoot = <String, dynamic>{
      for (final entry in conversations.entries)
        '${entry.key}': entry.value.toJson(),
    };
    await temp.writeAsString(
      jsonEncode({'version': 1, 'conversations': convRoot, 'messages': root}),
      flush: true,
    );
    final backup = File('${file.path}.bak');
    if (await backup.exists()) await backup.delete();
    final hadOriginal = await file.exists();
    if (hadOriginal) await file.rename(backup.path);
    try {
      await temp.rename(file.path);
      if (await backup.exists()) await backup.delete();
    } catch (_) {
      if (hadOriginal && await backup.exists()) {
        await backup.rename(file.path);
      }
      rethrow;
    }
  }

  Future<int> messageCount() async {
    final all = await load();
    return all.messages.values.fold<int>(0, (sum, list) => sum + list.length);
  }

  Future<void> clear() async {
    final file = await _resolveFile();
    if (await file.exists()) await file.delete();
  }
}
