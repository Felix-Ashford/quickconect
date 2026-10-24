/// 数据模型：与服务端 JSON 一一对应。
library;

enum MsgStatus { sending, sent, failed }

class DeviceInfo {
  final int id;
  final String name;
  final String platform;
  final String pushTopic; // ntfy 推送铃主题（本设备专属）

  const DeviceInfo({
    required this.id,
    required this.name,
    required this.platform,
    required this.pushTopic,
  });

  /// ntfy App 的订阅链接（二维码内容）。
  String get subscribeUrl => 'https://ntfy.sh/$pushTopic';
}

class User {
  final int id;
  final String name;
  final String displayName;
  final String avatarMediaId;

  const User({
    required this.id,
    required this.name,
    required this.displayName,
    this.avatarMediaId = '',
  });

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: j['id'] as int,
    name: j['name'] as String,
    displayName: j['display_name'] as String? ?? j['name'] as String,
    avatarMediaId: j['avatar_media_id'] as String? ?? '',
  );
}

class Conversation {
  final int id;
  final String type; // dm | group(预留)
  final List<User> members;
  final Message? lastMessage;
  final int unread;
  final int lastSeq;

  const Conversation({
    required this.id,
    required this.type,
    required this.members,
    this.lastMessage,
    required this.unread,
    required this.lastSeq,
  });

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as int,
    type: j['type'] as String,
    members: (j['members'] as List<dynamic>? ?? [])
        .map((e) => User.fromJson(e as Map<String, dynamic>))
        .toList(),
    lastMessage: j['last_message'] == null
        ? null
        : Message.fromJson(j['last_message'] as Map<String, dynamic>),
    unread: (j['unread'] as num?)?.toInt() ?? 0,
    lastSeq: (j['last_seq'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'members': members
        .map(
          (user) => {
            'id': user.id,
            'name': user.name,
            'display_name': user.displayName,
            'avatar_media_id': user.avatarMediaId,
          },
        )
        .toList(),
    'last_message': lastMessage?.toJson(),
    'unread': unread,
    'last_seq': lastSeq,
  };

  /// 私聊对象（成员里除了自己以外的那个人）。
  User? peer(int meId) {
    for (final m in members) {
      if (m.id != meId) return m;
    }
    return null;
  }

  Conversation copyWith({int? unread}) => Conversation(
    id: id,
    type: type,
    members: members,
    lastMessage: lastMessage,
    unread: unread ?? this.unread,
    lastSeq: lastSeq,
  );
}

class AutomationIdentity {
  final String id, name, displayName, mode, defaultModel;
  final int userId, contextMaxChars;
  final String avatarMediaId, defaultSystemPrompt;
  final bool mentionEnabled;
  final List<String> models;
  final bool privateDirectory;
  const AutomationIdentity({
    required this.id,
    required this.name,
    required this.displayName,
    required this.mode,
    required this.defaultModel,
    required this.models,
    required this.privateDirectory,
    this.userId = 0,
    this.contextMaxChars = 60000,
    this.avatarMediaId = '',
    this.defaultSystemPrompt = '',
    this.mentionEnabled = true,
  });
  factory AutomationIdentity.fromJson(Map<String, dynamic> j) =>
      AutomationIdentity(
        id: j['id'] as String? ?? '',
        name: j['name'] as String? ?? '',
        displayName: j['display_name'] as String? ?? '',
        mode: j['mode'] as String? ?? 'api',
        defaultModel: j['default_model'] as String? ?? '',
        models: (j['models'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        privateDirectory: j['private_directory'] as bool? ?? true,
        userId: (j['user_id'] as num?)?.toInt() ?? 0,
        contextMaxChars: (j['context_max_chars'] as num?)?.toInt() ?? 60000,
        avatarMediaId: j['avatar_media_id'] as String? ?? '',
        defaultSystemPrompt: j['default_system_prompt'] as String? ?? '',
        mentionEnabled: j['mention_enabled'] as bool? ?? true,
      );
}

class AutomationThread {
  final int id, userId, conversationId;
  final String identity, title, selectedModel;
  final int createdAt;
  final String? systemPrompt;
  final bool titleManual;
  const AutomationThread({
    required this.id,
    required this.identity,
    required this.userId,
    required this.conversationId,
    required this.title,
    required this.selectedModel,
    required this.createdAt,
    this.systemPrompt,
    this.titleManual = false,
  });
  factory AutomationThread.fromJson(Map<String, dynamic> j) => AutomationThread(
    id: (j['id'] as num).toInt(),
    identity: j['identity'] as String? ?? '',
    userId: (j['user_id'] as num).toInt(),
    conversationId: (j['conversation_id'] as num).toInt(),
    title: j['title'] as String? ?? '',
    selectedModel: j['selected_model'] as String? ?? '',
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    systemPrompt: j['system_prompt'] as String?,
    titleManual: j['title_manual'] as bool? ?? false,
  );
}

class Message {
  final String id;
  final int convId;
  final int seq; // 服务器序列号；本地未确认的乐观消息为 -1
  final int revision; // 修订版本；旧消息默认为 0
  final int senderId;
  final String senderName;
  final String senderAvatarMediaId;
  final String type; // text | image | file | voice | sticker
  final String format;
  final int formatVersion;
  final Map<String, dynamic> payload; // 完整负载（media_id、name、duration_ms 等）
  final int createdAt; // 秒级时间戳
  final String clientMsgId; // 客户端幂等 ID
  MsgStatus status; // 仅本地乐观消息使用

  Message({
    required this.id,
    required this.convId,
    required this.seq,
    this.revision = 0,
    required this.senderId,
    required this.senderName,
    this.senderAvatarMediaId = '',
    required this.type,
    this.format = 'plain',
    this.formatVersion = 1,
    required this.payload,
    required this.createdAt,
    required this.clientMsgId,
    this.status = MsgStatus.sent,
  });

  /// text 消息的内容；其他类型为空。
  String get text => payload['text'] as String? ?? '';

  factory Message.fromJson(Map<String, dynamic> j) {
    final payload = (j['payload'] as Map<String, dynamic>?) ?? const {};
    return Message(
      id: j['id'] as String,
      convId: j['conv_id'] as int,
      seq: (j['seq'] as num).toInt(),
      revision: (j['revision'] as num?)?.toInt() ?? 0,
      senderId: j['sender_id'] as int,
      senderName: j['sender_name'] as String? ?? '',
      senderAvatarMediaId: j['sender_avatar_media_id'] as String? ?? '',
      type: j['type'] as String,
      format:
          j['format'] as String? ?? ((payload['format'] as String?) ?? 'plain'),
      formatVersion:
          (j['format_version'] as num?)?.toInt() ??
          (payload['format_version'] as num?)?.toInt() ??
          1,
      payload: payload,
      createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      clientMsgId: j['client_msg_id'] as String? ?? '',
    );
  }

  /// 本地乐观消息（尚未有服务器 seq/id）。
  factory Message.pending({
    required int convId,
    required int senderId,
    required String senderName,
    required String type,
    required Map<String, dynamic> payload,
    required String clientMsgId,
  }) => Message(
    id: 'pending-$clientMsgId',
    convId: convId,
    seq: -1,
    senderId: senderId,
    senderName: senderName,
    type: type,
    format: payload['format'] as String? ?? 'plain',
    formatVersion: (payload['format_version'] as num?)?.toInt() ?? 1,
    payload: payload,
    createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    clientMsgId: clientMsgId,
    senderAvatarMediaId: '',
    status: MsgStatus.sending,
  );

  bool get isPending => seq < 0;
  bool get isRetracted => payload['retracted'] == true;
  bool get isEdited => payload['edited_at'] != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'conv_id': convId,
    'seq': seq,
    'revision': revision,
    'sender_id': senderId,
    'sender_name': senderName,
    'sender_avatar_media_id': senderAvatarMediaId,
    'type': type,
    'format': format,
    'format_version': formatVersion,
    'payload': payload,
    'created_at': createdAt,
    'client_msg_id': clientMsgId,
  };

  /// 列表/气泡里的提示文案（非 text 类型）。
  String get fallbackText {
    final name = payload['name'] as String?;
    switch (type) {
      case 'image':
        return '[图片]';
      case 'file':
        return name != null ? '[文件] $name' : '[文件]';
      case 'voice':
        return '[语音]';
      case 'sticker':
        return '[表情]';
      default:
        return '[消息]';
    }
  }
}

/// 从消息提取列表预览文案。
String messagePreview(Message m) => m.isRetracted
    ? '消息已撤回'
    : m.type == 'text'
    ? m.text
    : m.fallbackText;
