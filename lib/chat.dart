import 'dart:io';

import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'general_settings.dart';

/// 后台 isolate 用的会话序列化（ChatStore.save 经 compute 调用）
String _encodeConversationJson(Conversation c) => jsonEncode(c.toJson());

/// 会话文件解析（isolate 内执行）：读文件 + JSON 解码
Map<String, dynamic>? _parseConversationFile(String path) {
  try {
    return jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// 会话文件全量解析（isolate 内执行）：读文件 + JSON 解码 +
/// Conversation.fromJson（消息树/分支展开也不占主线程——归档大对话
/// 时壳合并路径的主线程同步解析是卡顿来源）
Conversation? _parseConversationFull(String path) {
  try {
    final j = _parseConversationFile(path);
    if (j == null) return null;
    return Conversation.fromJson(j);
  } catch (_) {
    return null;
  }
}

/// 请求体 JSON 编码（isolate 内执行）：含 N 张 base64 图片的请求体
/// 可达几十 MB，主线程同步编码是上传卡顿来源
String _encodeRequestBody(Map<String, dynamic> body) => jsonEncode(body);

/// 角色枚举（仅 user / assistant，system 在请求时按需构造）
enum Role { user, assistant }

String _roleName(Role r) => r == Role.user ? 'user' : 'assistant';

/// 提供方下的一个模型（id 为 API 模型名；显示名可选）。
/// 能力为纯布尔（有无两种情况，无 null 状态）：
/// 默认多模态不支持、工具调用支持、思考支持（与模型设置默认一致）
class ProviderModel {
  ProviderModel({
    required this.id,
    this.displayName,
    this.supportsMultimodal = false,
    this.supportsTools = true,
    this.supportsThinking = true,
    this.contextWindow,
  });

  final String id;
  String? displayName;

  /// 是否支持多模态（图片输入）
  bool supportsMultimodal;

  /// 是否支持工具调用（function calling）
  bool supportsTools;

  /// 是否支持思考（reasoning）
  bool supportsThinking;

  /// 上下文窗口大小（token 数）；null = 未知
  int? contextWindow;

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'supportsMultimodal': supportsMultimodal,
    'supportsTools': supportsTools,
    'supportsThinking': supportsThinking,
    if (contextWindow != null) 'contextWindow': contextWindow,
  };

  factory ProviderModel.fromJson(Map<String, dynamic> j) => ProviderModel(
    id: j['id'] as String,
    displayName: j['displayName'] as String?,
    supportsMultimodal: j['supportsMultimodal'] as bool? ?? false,
    supportsTools: j['supportsTools'] as bool? ?? true,
    supportsThinking: j['supportsThinking'] as bool? ?? true,
    contextWindow: j['contextWindow'] as int?,
  );
}

/// 模型提供方（DeepSeek / Kimi / Qwen / GLM 或自定义）：
/// baseUrl + apiKey + 模型列表。模型需手动从 API 获取（默认无模型）
class ModelProvider {
  ModelProvider({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.models,
    this.isPreset = false,
  });

  final String name;
  String baseUrl;
  String apiKey;
  final List<ProviderModel> models;

  /// 预置提供方（不可删除）
  final bool isPreset;

  Map<String, dynamic> toJson() => {
    'name': name,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'models': models.map((m) => m.toJson()).toList(),
    'isPreset': isPreset,
  };

  factory ModelProvider.fromJson(Map<String, dynamic> j) => ModelProvider(
    name: j['name'] as String,
    baseUrl: j['baseUrl'] as String? ?? '',
    apiKey: j['apiKey'] as String? ?? '',
    models: (j['models'] as List? ?? [])
        .map((m) => ProviderModel.fromJson(m as Map<String, dynamic>))
        .toList(),
    isPreset: j['isPreset'] as bool? ?? false,
  );
}

/// 预置提供方（仅名称与 API 地址内置；模型默认无，需手动从 API 获取）
final List<ModelProvider> kPresetProviders = [
  ModelProvider(
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    apiKey: '',
    models: const [],
    isPreset: true,
  ),
  ModelProvider(
    name: 'Kimi',
    baseUrl: 'https://api.moonshot.cn/v1',
    apiKey: '',
    models: const [],
    isPreset: true,
  ),
  ModelProvider(
    name: 'Qwen',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    apiKey: '',
    models: const [],
    isPreset: true,
  ),
  ModelProvider(
    name: 'GLM',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    apiKey: '',
    models: const [],
    isPreset: true,
  ),
];

/// 消息的一个历史版本（重新生成前的回复内容 + 思考）
class MessageVersion {
  MessageVersion(this.content, this.thinking);

  final String content;
  final String? thinking;

  Map<String, dynamic> toJson() => {'content': content, 'thinking': thinking};

  factory MessageVersion.fromJson(Map<String, dynamic> j) =>
      MessageVersion(j['content'] as String? ?? '', j['thinking'] as String?);
}

/// 文字替换规则（显示层替换）：
/// [display] = 显示文本（如「用户」），[model] = 模型文本（如 user）。
/// 模型输出含 model → 显示替换为 display；输入含 display → 发给模型替换为 model
class TextReplaceRule {
  TextReplaceRule({
    required this.display,
    required this.model,
    this.enabled = true,
  });

  String display;
  String model;

  /// 规则开关（false = 不应用）
  bool enabled;

  Map<String, dynamic> toJson() => {
    'display': display,
    'model': model,
    'enabled': enabled,
  };

  factory TextReplaceRule.fromJson(Map<String, dynamic> j) => TextReplaceRule(
    display: j['display'] as String? ?? '',
    model: j['model'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
  );
}

/// 显示层应用：模型文本 → 显示文本（展示助手输出时；禁用规则跳过）
String applyDisplayRules(String text, List<TextReplaceRule> rules) {
  for (final r in rules) {
    if (!r.enabled) continue;
    if (r.model.isNotEmpty) text = text.replaceAll(r.model, r.display);
  }
  return text;
}

/// 输入层应用：显示文本 → 模型文本（发送/保存前，模型收到的仍是替换前文本；
/// 禁用规则跳过）
String applyModelRules(String text, List<TextReplaceRule> rules) {
  for (final r in rules) {
    if (!r.enabled) continue;
    if (r.display.isNotEmpty) text = text.replaceAll(r.display, r.model);
  }
  return text;
}

/// 图片消息部件（多模态）：图片以 base64 data URL（原图）随消息持久化
class ImagePart {
  ImagePart({
    required this.name,
    required this.mimeType,
    required this.dataUrl,
    this.thumbUrl,
  });

  final String name;
  final String mimeType;

  /// 发送给 AI 的中档压缩 JPEG（data:image/jpeg;base64,...）
  final String dataUrl;

  /// 前端小图（低分辨率缩略 data URL，气泡/网格显示用）：
  /// 小 10-20 倍，列表滚动零解码压力；null = 用 dataUrl 兜底
  /// （旧消息无缩略图）
  String? thumbUrl;

  /// 前端显示用：优先小图
  String get displayUrl => thumbUrl ?? dataUrl;

  Map<String, dynamic> toJson() => {
    'name': name,
    'mimeType': mimeType,
    'dataUrl': dataUrl,
    'thumbUrl': thumbUrl,
  };

  factory ImagePart.fromJson(Map<String, dynamic> j) => ImagePart(
    name: j['name'] as String? ?? '',
    mimeType: j['mimeType'] as String? ?? 'image/jpeg',
    dataUrl: j['dataUrl'] as String? ?? '',
    thumbUrl: j['thumbUrl'] as String?,
  );
}

/// MCP 服务器配置（用户在设置页添加；持久化）。
/// id 唯一标识，enabled 控制是否在对话中启用。
/// transport：'http'（Streamable HTTP 远程端点，url 必填）/
/// 'stdio'（本地进程 npx 等，移动端无法运行，url 为空）
class McpServer {
  McpServer({
    required this.id,
    required this.name,
    required this.url,
    this.token = '',
    this.enabled = true,
    this.transport = 'http',
    this.command = const [],
  });

  final String id;
  String name;
  String url;
  String token;
  bool enabled;

  /// transport 类型（'http' / 'stdio'）
  String transport;

  /// stdio 原始命令（command + args，仅展示用；移动端不支持运行）
  List<String> command;

  /// stdio 或 URL 为空 → 无法连接（移动端不支持本地进程）
  bool get isStdio => transport == 'stdio' || url.isEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'token': token,
    'enabled': enabled,
    'transport': transport,
    if (command.isNotEmpty) 'command': command,
  };

  factory McpServer.fromJson(Map<String, dynamic> j) => McpServer(
    id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    name: j['name'] as String? ?? '',
    url: j['url'] as String? ?? '',
    token: j['token'] as String? ?? '',
    enabled: j['enabled'] as bool? ?? true,
    transport: j['transport'] as String? ?? 'http',
    command:
        (j['command'] as List?)?.map((c) => c.toString()).toList() ?? const [],
  );
}

/// 从 JSON 配置解析 MCP 服务器列表（宽容解析，支持常见格式）：
/// 1. Claude 风格：{"mcpServers": {"名称": {"url": "...", "token": "...", "headers": {"Authorization": "Bearer xxx"}}}}
/// 2. 单服务器：{"name": "...", "url": "...", "token": "..."}
/// 3. 数组：[{...}, {...}]
/// 解析失败或无有效服务器返回空列表（由调用方提示）
List<McpServer> parseMcpServersJson(String json) {
  final list = <McpServer>[];
  Object? obj;
  try {
    obj = jsonDecode(json);
  } catch (_) {
    return list;
  }
  // 批量导入时保证 id 唯一（同一毫秒内连续创建）
  var seq = 0;
  void addFromMap(String? fallbackName, Map<dynamic, dynamic> v) {
    final s = _mcpServerFromMap(fallbackName, v, seq++);
    if (s != null) list.add(s);
  }

  if (obj is Map) {
    final mcp = obj['mcpServers'];
    if (mcp is Map) {
      // Claude 风格：mcpServers 包装（key = 服务器名）
      mcp.forEach((name, v) {
        if (v is Map) addFromMap(name.toString(), v);
      });
    } else {
      addFromMap(null, obj);
    }
  } else if (obj is List) {
    for (final item in obj) {
      if (item is Map) addFromMap(null, item);
    }
  }
  return list;
}

McpServer? _mcpServerFromMap(
  String? fallbackName,
  Map<dynamic, dynamic> v,
  int seq,
) {
  final name = (v['name']?.toString().trim().isNotEmpty ?? false)
      ? v['name'].toString().trim()
      : (fallbackName?.trim().isNotEmpty ?? false ? fallbackName!.trim() : '');
  final url = (v['url']?.toString() ?? '').trim();
  // stdio 条目：无 url 但有 command（本地进程，如 npx）——识别出来
  // 标记为 stdio，由 UI 提示移动端不支持；完全无 url 也无 command 才跳过
  final hasCommand = v['command'] != null;
  if (url.isEmpty && !hasCommand) return null;
  // token 字段优先；其次从 headers 的 Authorization: Bearer xxx 提取
  var token = (v['token']?.toString() ?? '').trim();
  if (token.isEmpty) {
    final headers = v['headers'];
    if (headers is Map) {
      final auth = (headers['Authorization'] ?? headers['authorization'] ?? '')
          .toString();
      if (auth.startsWith('Bearer ')) token = auth.substring(7).trim();
    }
  }
  // stdio 原始命令（command + args，仅展示）
  final command = <String>[
    if (v['command'] != null) v['command'].toString(),
    if (v['args'] is List) ...(v['args'] as List).map((a) => a.toString()),
  ];
  // 清理尾部斜杠（协议层拼接用）
  final cleanUrl = url.replaceAll(RegExp(r'/$'), '');
  return McpServer(
    id: '${DateTime.now().microsecondsSinceEpoch}_$seq',
    name: name.isEmpty
        ? (cleanUrl.isEmpty ? (fallbackName ?? '') : cleanUrl)
        : name,
    url: cleanUrl,
    token: token,
    enabled: true,
    transport: url.isEmpty ? 'stdio' : 'http',
    command: command,
  );
}

/// 工具调用记录（消息卡片展示）：工具名 + 参数摘要 + 结果状态。
/// 随消息持久化，历史重放可见
class ToolCallRecord {
  ToolCallRecord({
    required this.name,
    required this.query,
    this.resultCount,
    this.output,
    this.images,
    this.expanded = false,
    this.silent = false,
  });

  final String name;

  /// 参数摘要（用于卡片副标题展示）
  final String query;

  /// 结果状态：null = 进行中；-1 = 失败；>=0 = 成功（结果字符数）
  int? resultCount;

  /// 运行输出（Python 工具：stdout/结果摘要；持久化截断 4000 字符）
  String? output;

  /// 运行产图（matplotlib 等）：data URL 列表。瞬态不序列化——
  /// 重载会话后消失（同 mermaid 缓存语义）
  List<String>? images;

  /// 卡片展开态（显示完整输出/图片；瞬态）
  bool expanded;

  /// 静默卡片（send_image）：不渲染分割块，仅标记该轮是工具轮
  ///（据此隐藏消息工具栏）。瞬态不序列化
  bool silent;

  Map<String, dynamic> toJson() => {
    'name': name,
    'query': query,
    'resultCount': resultCount,
    if (output != null && output!.isNotEmpty)
      'output': output!.length > 4000
          ? '${output!.substring(0, 4000)}…'
          : output,
  };

  factory ToolCallRecord.fromJson(Map<String, dynamic> j) => ToolCallRecord(
    name: j['name'] as String? ?? '',
    query: j['query'] as String? ?? '',
    resultCount: j['resultCount'] as int?,
    output: j['output'] as String?,
  );
}

/// 消息的一个分支（llama.cpp 树状分支）：
/// 锚点 = 被分支时该消息的内容快照；tail = 该分支的后续消息链
class MessageBranch {
  MessageBranch(this.anchor, this.tail);

  Message anchor;
  List<Message> tail;

  Map<String, dynamic> toJson() => {
    'anchor': anchor.toJson(),
    'tail': tail.map((m) => m.toJson()).toList(),
  };

  factory MessageBranch.fromJson(Map<String, dynamic> j) {
    // 兼容旧结构：{content, tail}（无 anchor 字段，旧版仅用户消息分支）
    final anchor = j['anchor'] != null
        ? Message.fromJson(j['anchor'] as Map<String, dynamic>)
        : Message(
            role: Role.user,
            content: j['content'] as String? ?? '',
            ts: DateTime.now(),
          );
    return MessageBranch(
      anchor,
      (j['tail'] as List? ?? [])
          .map((m) => Message.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// 文件部件（文本附件）：内容随消息发送，模型可阅读全文
class MessageFilePart {
  MessageFilePart({
    required this.name,
    required this.size,
    required this.content,
    this.truncated = false,
  });

  final String name;

  /// 原始字节数（截断前）
  final int size;

  /// 读取到的文本内容（超过上限时已截断）
  final String content;

  /// 是否因超过读取上限被截断
  final bool truncated;

  Map<String, dynamic> toJson() => {
    'name': name,
    'size': size,
    'content': content,
    'truncated': truncated,
  };

  factory MessageFilePart.fromJson(Map<String, dynamic> j) => MessageFilePart(
    name: j['name'] as String? ?? '',
    size: j['size'] as int? ?? 0,
    content: j['content'] as String? ?? '',
    truncated: j['truncated'] as bool? ?? false,
  );
}

/// 一条消息：正式回复 content + 思考过程 thinking（reasoning_content）
class Message {
  Message({
    required this.role,
    required this.content,
    this.thinking,
    required this.ts,
    this.error = false,
  });

  final Role role;
  String content;
  String? thinking;
  final DateTime ts;

  /// 是否为错误消息（红字显示）
  bool error;

  /// 输出是否被截断（finish_reason = length；气泡下显示「继续生成」）
  bool truncated = false;

  /// 历史版本（重新生成时把旧回复压入；不含当前；仅助手消息）
  List<MessageVersion>? versions;

  /// 分支（llama.cpp 树状分支）：含全部版本（含当前显示的分支）。
  /// 当前分支的后续链实时存于会话消息列表，切换时写回/换入。
  /// 用户消息（分支按钮）与助手消息（重新生成）通用
  List<MessageBranch>? branches;

  /// 分支导航位置：0 = 最新分支（branches[0]）。仅视图态，不持久化
  int viewPos = 0;

  /// 图片部件（多模态；仅用户消息，原图 base64 持久化）
  List<ImagePart>? imageParts;

  /// 文件部件（文本附件；仅用户消息，内容随请求发送）
  List<MessageFilePart>? fileParts;

  /// 工具调用记录（MCP 工具调用；仅助手消息，随消息持久化展示）
  List<ToolCallRecord>? toolCalls;

  /// 当前显示的内容（分支视图内容已随切换载入 content；
  /// 历史 versions 为旧数据兼容，仅无分支时生效）
  String get displayContent {
    if (branches != null && branches!.isNotEmpty) return content;
    if (versions == null || versions!.isEmpty) return content;
    return viewPos == 0 ? content : versions![viewPos - 1].content;
  }

  /// 当前显示的思考（历史 versions 兼容；分支视图返回 thinking）
  String? get displayThinking {
    if (branches != null && branches!.isNotEmpty) return thinking;
    if (versions == null || versions!.isEmpty) return thinking;
    return viewPos == 0 ? thinking : versions![viewPos - 1].thinking;
  }

  /// 分支总数（当前 + 历史分支）
  int get branchCount => (branches?.length ?? 0);

  /// 发往模型的完整文本：文件部件按 llama.cpp 风格格式化
  /// （File: 名称\nContent: 内容）后拼接正文
  String get modelContent {
    final f = fileParts;
    if (f == null || f.isEmpty) return content;
    final blocks = f
        .map((p) => 'File: ${p.name}\nContent:\n${p.content}')
        .join('\n\n');
    return content.trim().isEmpty ? blocks : '$blocks\n\n$content';
  }

  /// [withBranches] false 时省略 branches（Conversation.toJson 的
  /// 去重序列化专用：分支尾以索引引用形式由外层统一写入）
  Map<String, dynamic> toJson({bool withBranches = true}) => {
    'role': role.index,
    'content': content,
    'thinking': thinking,
    'ts': ts.toIso8601String(),
    'error': error,
    'truncated': truncated,
    'viewPos': viewPos,
    if (versions != null && versions!.isNotEmpty)
      'versions': versions!.map((v) => v.toJson()).toList(),
    if (withBranches && branches != null && branches!.isNotEmpty)
      'branches': branches!.map((b) => b.toJson()).toList(),
    if (imageParts != null && imageParts!.isNotEmpty)
      'imageParts': imageParts!.map((p) => p.toJson()).toList(),
    if (fileParts != null && fileParts!.isNotEmpty)
      'fileParts': fileParts!.map((p) => p.toJson()).toList(),
    if (toolCalls != null && toolCalls!.isNotEmpty)
      'toolCalls': toolCalls!.map((t) => t.toJson()).toList(),
  };

  factory Message.fromJson(Map<String, dynamic> j) {
    final m =
        Message(
            role: Role.values[j['role'] as int],
            content: j['content'] as String? ?? '',
            thinking: j['thinking'] as String?,
            ts: DateTime.parse(j['ts'] as String),
            error: j['error'] as bool? ?? false,
          )
          ..truncated = j['truncated'] as bool? ?? false
          ..versions = (j['versions'] as List?)
              ?.map((v) => MessageVersion.fromJson(v as Map<String, dynamic>))
              .toList()
          ..branches = (j['branches'] as List?)
              ?.map((b) => MessageBranch.fromJson(b as Map<String, dynamic>))
              .toList()
          ..imageParts = (j['imageParts'] as List?)
              ?.map((p) => ImagePart.fromJson(p as Map<String, dynamic>))
              .toList()
          ..fileParts = (j['fileParts'] as List?)
              ?.map((p) => MessageFilePart.fromJson(p as Map<String, dynamic>))
              .toList()
          ..toolCalls = (j['toolCalls'] as List?)
              ?.map((t) => ToolCallRecord.fromJson(t as Map<String, dynamic>))
              .toList();
    final savedPos = j['viewPos'] as int?;
    if (m.branches != null && m.branches!.isNotEmpty) {
      if (savedPos == null) {
        // 旧数据迁移：当时 live 不在列表中 → 末尾补 live 槽位并指向它
        m.branches!.add(
          MessageBranch(
            Message(
              role: m.role,
              content: m.content,
              thinking: m.thinking,
              ts: m.ts,
              error: m.error,
            )..versions = m.versions,
            <Message>[],
          ),
        );
        m.viewPos = m.branches!.length - 1;
      } else {
        m.viewPos = savedPos.clamp(0, m.branches!.length - 1);
      }
    }
    return m;
  }
}

/// 一个会话
class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.messages,
    required this.updatedAt,
    this.modelId,
    this.systemPrompt,
    this.mcpServerIds,
    this.archived = false,
    this.locked = false,
    this.archivedAt,
    this.builtinToolsEnabled,
    this.loaded = true,
  });

  final String id;
  String title;
  final List<Message> messages;
  DateTime updatedAt;
  String? modelId;

  /// 会话级 system 提示词（新建对话不继承）
  String? systemPrompt;

  /// 会话级 MCP 配置：null = 跟随全局（启用所有 enabled 服务器）；
  /// 非 null = 该会话仅启用列表中的服务器 id（空列表 = 禁用全部 MCP）
  List<String>? mcpServerIds;

  /// 是否已归档（从主历史列表移除，可在设置页恢复/永久删除）
  bool archived;

  /// 瞬态标记（不序列化）：true = 完整对象（消息在内存）；
  /// false = 元数据壳（列表用，消息未加载，save 时自动从文件合并）
  bool loaded;

  /// 锁定（阻止自动归档；手动归档/删除不受限）
  bool locked;

  /// 归档时间（自动删除计时起点）
  DateTime? archivedAt;

  /// 会话级内置工具开关（时间/位置）：null = 跟随全局设置
  bool? builtinToolsEnabled;

  Map<String, dynamic> toJson() {
    // fmt 2：分支尾去重——tail 存消息索引引用而非全量副本。
    // 此前同一消息在每个分支尾都被完整序列化一遍（O(分支×消息)，
    // 图片 base64 一并翻倍），长对话多分支时 JSON 平方级膨胀，
    // 编码内存暴涨/文件巨大 → 保存失败（被误报"存储空间不足"）。
    // 主列表编号 0..n-1；仅存在于其他时间线的消息进 extraMsgs 池
    final extra = <Message>[];
    final ids = Expando<int>();
    for (var i = 0; i < messages.length; i++) {
      ids[messages[i]] = i;
    }
    int refOf(Message m) {
      final r = ids[m];
      if (r != null) return r;
      for (var k = 0; k < extra.length; k++) {
        if (identical(extra[k], m)) return messages.length + k;
      }
      extra.add(m);
      return messages.length + extra.length - 1;
    }

    Map<String, dynamic> msgJson(Message m) {
      final j = m.toJson(withBranches: false);
      final b = m.branches;
      if (b != null && b.isNotEmpty) {
        j['branches'] = b
            .map(
              (br) => {
                'anchor': br.anchor.toJson(),
                'tail': br.tail.map(refOf).toList(),
              },
            )
            .toList();
      }
      return j;
    }

    return {
      'id': id,
      'title': title,
      'fmt': 2,
      'messages': messages.map(msgJson).toList(),
      if (extra.isNotEmpty) 'extraMsgs': extra.map((m) => m.toJson()).toList(),
      'updatedAt': updatedAt.toIso8601String(),
      'modelId': modelId,
      if (systemPrompt != null) 'systemPrompt': systemPrompt,
      if (mcpServerIds != null) 'mcpServerIds': mcpServerIds,
      'archived': archived,
      'locked': locked,
      if (archivedAt != null) 'archivedAt': archivedAt!.toIso8601String(),
      if (builtinToolsEnabled != null) 'builtinToolsEnabled': builtinToolsEnabled,
    };
  }

  /// v2 索引引用 → v1 全量形状展开（复用既有解析路径）。
  /// 引用替换为源消息 map（不拷贝：源自身也在主列表里，同趟完成
  /// 其引用展开，天然收敛；fromJson 为每次出现建独立 Message，
  /// 与 v1 语义一致——分支尾与主列表不共享对象）
  static Map<String, dynamic> _expandV2(Map<String, dynamic> j) {
    final msgs = (j['messages'] as List).cast<Map<String, dynamic>>();
    final extra =
        ((j['extraMsgs'] as List?) ?? const [])
            .cast<Map<String, dynamic>>();
    Object? resolve(Object e) {
      if (e is Map) return e; // 混排的完整对象原样保留
      if (e is! int) return null;
      if (e >= 0 && e < msgs.length) return msgs[e];
      final k = e - msgs.length;
      return k >= 0 && k < extra.length ? extra[k] : null;
    }

    for (final m in msgs) {
      final bs = m['branches'] as List?;
      if (bs == null) continue;
      for (final b in bs.cast<Map<String, dynamic>>()) {
        final tail = b['tail'] as List?;
        if (tail == null) continue;
        b['tail'] = [
          for (final e in tail)
            if (resolve(e) case final r?) r,
        ];
      }
    }
    j.remove('extraMsgs');
    return j;
  }

  factory Conversation.fromJson(Map<String, dynamic> j) {
    // v2：分支尾索引引用先展开回 v1 全量形状（复用既有解析路径）
    final data = (j['fmt'] as int? ?? 1) >= 2 ? _expandV2(j) : j;
    final msgs =
        (data['messages'] as List)
            .map((m) => Message.fromJson(m as Map<String, dynamic>))
            .toList();
    return Conversation(
    id: j['id'] as String,
    title: j['title'] as String,
    messages: msgs,
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    modelId: j['modelId'] as String?,
    systemPrompt: j['systemPrompt'] as String?,
    mcpServerIds: (j['mcpServerIds'] as List?)
        ?.map((s) => s.toString())
        .toList(),
    archived: j['archived'] as bool? ?? false,
    locked: j['locked'] as bool? ?? false,
    archivedAt: j['archivedAt'] != null
        ? DateTime.tryParse(j['archivedAt'] as String)
        : null,
    builtinToolsEnabled: j['builtinToolsEnabled'] as bool?,
    loaded: true,
  );
  }
}

/// 持久化封装：会话正文存独立文件（`convs/<id>.json`），SharedPreferences
/// 只存轻量元数据索引（conv_index）+ 各项设置——此前全部塞 prefs 单一
/// XML，会话涨到几十 MB 后冷启动要整体解析（对话/模型列表"加载半天"
/// 的根源），且每次保存全量重写整个文件
class ChatStore {
  static const _idsKey = 'conv_ids'; // 旧版索引（迁移检测用）
  static const _indexKey = 'conv_index';
  final SharedPreferences _prefs;
  late final Directory _dir;

  ChatStore(this._prefs, this._dir);

  /// 进程级缓存：多次 create 复用同一实例（SharedPreferences 是单例，
  /// 避免重复初始化；各入口拿到的都是同一数据源）
  static ChatStore? _cached;

  static Future<ChatStore> create() async {
    if (_cached != null) return _cached!;
    final prefs = await SharedPreferences.getInstance();
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/convs');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final s = ChatStore(prefs, dir);
    await s._migrateFromPrefs();
    return _cached = s;
  }

  /// 一次性迁移：旧版 prefs 里的 `conv_<id>` 正文搬到文件，索引换成
  /// 轻量元数据（搬家后 prefs 恢复小文件，冷启动即恢复毫秒级）
  Future<void> _migrateFromPrefs() async {
    final legacyIds = _prefs.getStringList(_idsKey);
    final hasIndex = _prefs.getString(_indexKey) != null;
    if (legacyIds == null || legacyIds.isEmpty) {
      if (!hasIndex) await _prefs.setString(_indexKey, '[]');
      return;
    }
    final index = <Map<String, dynamic>>[];
    for (final id in legacyIds) {
      final raw = _prefs.getString('conv_$id');
      if (raw == null) continue;
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        File('${_dir.path}/$id.json').writeAsStringSync(raw);
        index.add(_indexEntryFromJson(j, id));
      } catch (_) {
        // 损坏数据跳过
      }
      await _prefs.remove('conv_$id');
    }
    await _prefs.setString(_indexKey, jsonEncode(index));
    await _prefs.remove(_idsKey);
  }

  Map<String, dynamic> _indexEntryFromJson(Map<String, dynamic> j, String id) =>
      {
        'id': id,
        'title': j['title'] ?? '',
        'updatedAt': j['updatedAt'] ?? '',
        'modelId': j['modelId'],
        'archived': j['archived'] ?? false,
        'locked': j['locked'] ?? false,
        'archivedAt': j['archivedAt'],
      };

  Map<String, dynamic> _indexEntryOf(Conversation c) => {
    'id': c.id,
    'title': c.title,
    'updatedAt': c.updatedAt.toIso8601String(),
    'modelId': c.modelId,
    'archived': c.archived,
    'locked': c.locked,
    'archivedAt': c.archivedAt?.toIso8601String(),
  };

  Conversation _shellFromEntry(Map<String, dynamic> e) => Conversation(
    id: e['id'] as String,
    title: (e['title'] as String?) ?? '',
    messages: [],
    updatedAt:
        DateTime.tryParse((e['updatedAt'] as String?) ?? '') ?? DateTime.now(),
    modelId: e['modelId'] as String?,
    archived: (e['archived'] as bool?) ?? false,
    locked: (e['locked'] as bool?) ?? false,
    archivedAt: e['archivedAt'] != null
        ? DateTime.tryParse(e['archivedAt'] as String)
        : null,
    loaded: false,
  );

  List<Map<String, dynamic>> _readIndex() {
    final raw = _prefs.getString(_indexKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<Map<String, dynamic>> index) =>
      _prefs.setString(_indexKey, jsonEncode(index));

  File _file(String id) => File('${_dir.path}/$id.json');

  /// 读取全部会话（按索引顺序，最新在前）——只返回元数据壳，
  /// 消息正文按需加载（loadConversation）。列表场景（抽屉/归档）
  /// 只需要标题时间，冷启动不再全量解析正文
  List<Conversation> loadAll() => _readIndex().map(_shellFromEntry).toList();

  /// 加载单个会话完整正文（打开会话时调用）；文件缺失/损坏返回 null
  Conversation? loadConversation(String id) {
    try {
      final raw = _file(id).readAsStringSync();
      return Conversation.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 异步加载（isolate 读文件 + JSON 解析）：带图会话的文件几 MB，
  /// 主线程同步解析会卡顿数百毫秒（切换对话卡顿的根源）
  Future<Conversation?> loadConversationAsync(String id) async {
    try {
      final f = _file(id);
      if (!f.existsSync()) return null;
      return await compute(_parseConversationFull, f.path);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Conversation c) async {
    // 壳对象（元数据被修改，如自动归档/锁定/恢复）：从文件合并正文，
    // 防止把空消息列表写回文件丢数据
    if (!c.loaded) {
      // isolate 加载（大对话主线程同步解析 = 归档/锁定卡顿来源）
      final existing = await loadConversationAsync(c.id);
      if (existing != null) {
        existing
          ..title = c.title
          ..updatedAt = c.updatedAt
          ..archived = c.archived
          ..archivedAt = c.archivedAt
          ..locked = c.locked
          ..modelId = c.modelId;
        c = existing;
      } else {
        c.loaded = true; // 文件不存在（新会话首次保存），按完整对象落盘
      }
    }
    // JSON 编码放后台 isolate：分支树大会话的序列化不在 UI 线程执行
    //（分支切换卡顿来源）
    final json = await compute(_encodeConversationJson, c);
    _file(c.id).writeAsStringSync(json);
    // 更新索引（保持顺序：已存在原位更新，新的插最前）
    final index = _readIndex();
    final entry = _indexEntryOf(c);
    final i = index.indexWhere((e) => e['id'] == c.id);
    if (i >= 0) {
      index[i] = entry;
    } else {
      index.insert(0, entry);
    }
    await _writeIndex(index);
  }

  Future<void> rename(String id, String title) async {
    // isolate 加载 + 编码：大对话重命名不在主线程解析/序列化
    final c = await loadConversationAsync(id);
    if (c == null) return;
    c.title = title;
    final json = await compute(_encodeConversationJson, c);
    _file(id).writeAsStringSync(json);
    final index = _readIndex();
    final i = index.indexWhere((e) => e['id'] == id);
    if (i >= 0) {
      index[i] = _indexEntryOf(c);
      await _writeIndex(index);
    }
  }

  /// 提示词（system prompt）：读取/保存（空串视为无）
  String? loadPrompt() {
    final p = _prefs.getString('chat_prompt');
    return (p == null || p.isEmpty) ? null : p;
  }

  Future<void> savePrompt(String prompt) =>
      _prefs.setString('chat_prompt', prompt);

  /// 思考深度（0 关闭 / 1 开启 / 2 最高）：固化到存档，启动时恢复
  int loadThinkingDepth() => _prefs.getInt('thinking_depth') ?? 0;

  Future<void> saveThinkingDepth(int depth) =>
      _prefs.setInt('thinking_depth', depth);

  /// 最后使用的对话模型：固化到存档，软件重启不重置
  String loadModelName() => _prefs.getString('model_name') ?? '';

  Future<void> saveModelName(String id) => _prefs.setString('model_name', id);

  /// 通用设置（粘贴/标题策略/AI标题/渲染开关）：单条 JSON String
  GeneralSettings loadGeneralSettings() {
    final raw = _prefs.getString('general_settings');
    if (raw == null || raw.isEmpty) return GeneralSettings.defaults;
    return GeneralSettings.decode(raw);
  }

  Future<void> saveGeneralSettings(GeneralSettings s) =>
      _prefs.setString('general_settings', s.encode());

  /// 文字替换规则（显示层替换）：读取/保存
  List<TextReplaceRule> loadReplaceRules() {
    final raw = _prefs.getStringList('replace_rules') ?? <String>[];
    final list = <TextReplaceRule>[];
    for (final s in raw) {
      try {
        list.add(
          TextReplaceRule.fromJson(jsonDecode(s) as Map<String, dynamic>),
        );
      } catch (_) {
        // 损坏数据跳过
      }
    }
    return list;
  }

  Future<void> saveReplaceRules(List<TextReplaceRule> rules) =>
      _prefs.setStringList(
        'replace_rules',
        rules.map((r) => jsonEncode(r.toJson())).toList(),
      );

  /// MCP 服务器列表：读取（默认空，用户手动添加）
  List<McpServer> loadMcpServers() {
    final raw = _prefs.getStringList('mcp_servers') ?? <String>[];
    final list = <McpServer>[];
    for (final s in raw) {
      try {
        list.add(McpServer.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {
        // 损坏数据跳过
      }
    }
    return list;
  }

  Future<void> saveMcpServers(List<McpServer> list) => _prefs.setStringList(
    'mcp_servers',
    list.map((s) => jsonEncode(s.toJson())).toList(),
  );

  /// 模型提供方列表：读取（无存档则返回预置——预置无模型，需手动获取）
  List<ModelProvider> loadProviders() {
    final raw = _prefs.getStringList('model_providers') ?? <String>[];
    if (raw.isEmpty) {
      return kPresetProviders
          .map(
            (p) => ModelProvider(
              name: p.name,
              baseUrl: p.baseUrl,
              apiKey: p.apiKey,
              models: [],
              isPreset: true,
            ),
          )
          .toList();
    }
    final list = <ModelProvider>[];
    for (final s in raw) {
      try {
        list.add(ModelProvider.fromJson(jsonDecode(s) as Map<String, dynamic>));
      } catch (_) {
        // 损坏数据跳过
      }
    }
    return list.isEmpty
        ? kPresetProviders
              .map(
                (p) => ModelProvider(
                  name: p.name,
                  baseUrl: p.baseUrl,
                  apiKey: p.apiKey,
                  models: [],
                  isPreset: true,
                ),
              )
              .toList()
        : list;
  }

  Future<void> saveProviders(List<ModelProvider> list) => _prefs.setStringList(
    'model_providers',
    list.map((p) => jsonEncode(p.toJson())).toList(),
  );

  Future<void> delete(String id) async {
    final f = _file(id);
    if (f.existsSync()) f.deleteSync();
    final index = _readIndex()..removeWhere((e) => e['id'] == id);
    await _writeIndex(index);
  }
}

/// LLM 流式增量（思考段 / 答案段分别给出）
class LlmDelta {
  const LlmDelta({
    this.thinking,
    this.content,
    this.done = false,
    this.finishReason,
  });
  final String? thinking; // reasoning_content 增量
  final String? content; // 正式回复增量
  final bool done;

  /// 结束原因（'length' = 输出被截断）
  final String? finishReason;
}

/// 流式工具调用增量（按 index 累积 id/name/arguments）
class LlmToolCallDelta {
  const LlmToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.arguments,
  });
  final int index;
  final String? id;
  final String? name;
  final String? arguments;
}

/// 带工具调用的流式增量：content/thinking 增量 + tool_calls 增量 + 结束标记
class LlmToolsDelta {
  const LlmToolsDelta({
    this.thinking,
    this.content,
    this.toolCall,
    this.done = false,
    this.finishReason,
  });
  final String? thinking;
  final String? content;
  final LlmToolCallDelta? toolCall;
  final bool done;

  /// 结束原因（'length' = 输出被截断）
  final String? finishReason;
}

/// LLM 服务：OpenAI 兼容 chat/completions 流式，解析 reasoning_content 与 content
class LlmService {
  /// [baseUrl]/[apiKey] 来自设置页的模型提供方配置（不再有内置测试 API）
  LlmService({required String baseUrl, required String apiKey})
    : _baseUrl = baseUrl,
      _apiKey = apiKey;

  final String _baseUrl;
  final String _apiKey;

  /// 思考深度四档：none / low / high / max（主控字段 reasoning.effort，
  /// 新版 OpenAI/DeepSeek 生态通行格式），并附带兼容字段覆盖其余
  /// 控制体系，各服务取自己认识的字段、忽略其余——
  /// · 开关型：chat_template_kwargs.enable_thinking（llama.cpp/Qwen3）、
  ///   顶层 thinking.type（DeepSeek）
  /// · 力度型：reasoning.effort（主）/ reasoning_effort（旧顶层）
  /// · 预算型：thinking.budget_tokens（Anthropic）、thinkingConfig.
  ///   thinkingBudget（Gemini）、reasoning_budget（llama.cpp）
  /// 深度 0 = none（关闭思考：不带 effort 与预算，防止
  /// 「thinking disabled + effort」400）；1 = low；2 = high；3 = max
  /// （max 档预算对齐 DeepSeek max 的量级）
  static const _efforts = ['none', 'low', 'high', 'max'];
  static const _budgets = [0, 4096, 16384, 32768];

  Map<String, dynamic> _thinkingParams(int depth) {
    final d = depth.clamp(0, 3);
    final on = d > 0;
    final effort = _efforts[d];
    final budget = _budgets[d];
    return {
      // 主控：四档 effort（none 显式发送）
      'reasoning': {'effort': effort},
      // 兼容：开关型（Anthropic thinking.type + budget_tokens）
      'chat_template_kwargs': {'enable_thinking': on, 'thinking': on},
      'thinking': {
        'type': on ? 'enabled' : 'disabled',
        if (on) 'budget_tokens': budget,
      },
      // 兼容：旧顶层 effort / 预算型（关闭档不带，防 400）
      if (on) 'reasoning_effort': effort,
      if (on) 'reasoning_budget': budget,
      if (on) 'thinkingConfig': {'thinkingBudget': budget},
    };
  }

  /// 发起对话，返回增量流（包含思考段与答案段）。onError 由调用方 listen(onError) 处理。
  /// [model] 选择模型；[thinkingDepth] 思考深度（0 none / 1 low / 2 high / 3 max，
  /// 请求参数见 [_thinkingParams]）；
  /// [systemPrompt] 非空时作为 system 消息插入最前；
  /// [tools] 非空时随请求附带（OpenAI function calling 格式，供 MCP 工具调用用）。
  /// [toolChoice] 控制工具选择策略（默认 'auto'）。
  Stream<LlmDelta> chat(
    List<Message> history, {
    required String model,
    int thinkingDepth = 1,
    String? systemPrompt,
    List<Map<String, dynamic>>? tools,
    String toolChoice = 'auto',
  }) async* {
    final url = Uri.parse(
      '${_baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions',
    );
    final messages = <Map<String, dynamic>>[
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        {'role': 'system', 'content': systemPrompt.trim()},
      ...history
          .where(
            // 思考不回传（DeepSeek 官方建议不回发 reasoning）；
            // thinking-only 消息（截断在思考阶段）也不发送——
            // 空 content 的 assistant 消息会被 API 400 拒绝
            (m) =>
                m.content.isNotEmpty ||
                (m.imageParts?.isNotEmpty ?? false) ||
                (m.fileParts?.isNotEmpty ?? false),
          )
          .map(
            (m) => {'role': _roleName(m.role), 'content': _contentPayload(m)},
          ),
    ];
    final req = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      // 大请求体（含 base64 图片）在 isolate 编码，防主线程卡顿
      ..body = await compute(_encodeRequestBody, {
        'model': model,
        'messages': messages,
        'stream': true,
        ..._thinkingParams(thinkingDepth),
        if (tools != null && tools.isNotEmpty) ...{
          'tools': tools,
          'tool_choice': toolChoice,
        },
      });
    if (_apiKey.trim().isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $_apiKey';
    }

    final client = http.Client();
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final body = await res.stream.bytesToString();
        throw Exception('HTTP ${res.statusCode}: $body');
      }
      // 逐行解析 SSE
      await for (final chunk
          in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final line = chunk.trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          yield const LlmDelta(done: true);
          return;
        }
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final first = choices.first as Map<String, dynamic>;
          final delta = first['delta'] as Map<String, dynamic>?;
          final fr = first['finish_reason'] as String?;
          // 结束 chunk（delta 空但 finish_reason 非空）也要产出
          if (delta == null && fr == null) continue;
          yield LlmDelta(
            thinking: delta?['reasoning_content'] as String?,
            content: delta?['content'] as String?,
            finishReason: fr,
          );
        } catch (_) {
          // 单行解析失败跳过，继续后续
        }
      }
      yield const LlmDelta(done: true);
    } finally {
      client.close();
    }
  }

  /// 消息 content 载荷：有图片 → OpenAI 多模态数组；否则纯文本字符串。
  /// 文件部件（文本附件）内容已并入 modelContent。
  /// 仅用户消息的图片进载荷——助手图片是 send_image 工具发给用户看的，
  /// 回传 image_url 会被多数端点 400（assistant 角色不支持图像内容）
  Object _contentPayload(Message m) {
    final images = m.imageParts;
    if (m.role != Role.user || images == null || images.isEmpty) {
      return m.modelContent;
    }
    return [
      {'type': 'text', 'text': m.modelContent},
      ...images.map(
        (img) => {
          'type': 'image_url',
          'image_url': {'url': img.dataUrl},
        },
      ),
    ];
  }

  /// 通过 API 获取文本 token 数（llama.cpp / vLLM 的 /tokenize 端点，
  /// 返回真实 tokenizer 计数）。请求体同时带 llama.cpp（content）与
  /// vLLM（prompt）两种字段，不认识的字段被忽略。
  /// 端点不存在/超时/解析失败返回 null（调用方降级为估算）
  Future<int?> tokenize(String text, {required String model}) async {
    if (text.trim().isEmpty) return 0;
    final url = Uri.parse('${_baseUrl.replaceAll(RegExp(r'/$'), '')}/tokenize');
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              if (_apiKey.trim().isNotEmpty) 'Authorization': 'Bearer $_apiKey',
            },
            body: jsonEncode({
              'model': model,
              'content': text,
              'prompt': text,
              'add_special': false,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      // llama.cpp: {"tokens": [...]}；vLLM: {"count": N} 或 {"tokens": [...]}
      final tokens = j['tokens'];
      if (tokens is List) return tokens.length;
      final count = j['count'];
      if (count is int) return count;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 带工具调用的流式对话（MCP ReAct 用）。
  /// 与 chat() 类似，但额外解析 delta.tool_calls 增量（按 index 累积）。
  /// [thinkingDepth] 思考深度（0 关闭 / 1 开启 / 2 最高，同 chat()）。
  /// 调用方在收到 done=true 后检查累积的 tool_calls 决定是否继续 ReAct 轮次。
  Stream<LlmToolsDelta> chatWithTools(
    List<Map<String, dynamic>> messages, {
    required String model,
    int thinkingDepth = 1,
    List<Map<String, dynamic>>? tools,
    String toolChoice = 'auto',
  }) async* {
    final url = Uri.parse(
      '${_baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions',
    );
    final req = http.Request('POST', url)
      ..headers['Content-Type'] = 'application/json'
      // 大请求体（含 base64 图片）在 isolate 编码，防主线程卡顿
      ..body = await compute(_encodeRequestBody, {
        'model': model,
        'messages': messages,
        'stream': true,
        ..._thinkingParams(thinkingDepth),
        if (tools != null && tools.isNotEmpty) ...{
          'tools': tools,
          'tool_choice': toolChoice,
        },
      });
    if (_apiKey.trim().isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $_apiKey';
    }
    final client = http.Client();
    try {
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final body = await res.stream.bytesToString();
        throw Exception('HTTP ${res.statusCode}: $body');
      }
      await for (final chunk
          in res.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final line = chunk.trim();
        if (line.isEmpty || !line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') {
          yield const LlmToolsDelta(done: true);
          return;
        }
        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          final choices = json['choices'] as List?;
          if (choices == null || choices.isEmpty) continue;
          final first = choices.first as Map<String, dynamic>;
          final delta = first['delta'] as Map<String, dynamic>?;
          final fr = first['finish_reason'] as String?;
          if (delta == null && fr == null) continue;
          final thinking = delta?['reasoning_content'] as String?;
          final content = delta?['content'] as String?;
          final tcs = delta?['tool_calls'] as List?;
          // 工具调用增量（可能有多个，逐个产出）
          if (tcs != null) {
            for (final raw in tcs) {
              final t = raw as Map<String, dynamic>;
              final fn = (t['function'] as Map<String, dynamic>?) ?? const {};
              yield LlmToolsDelta(
                toolCall: LlmToolCallDelta(
                  index: t['index'] as int? ?? 0,
                  id: t['id'] as String?,
                  name: fn['name'] as String?,
                  arguments: fn['arguments'] as String?,
                ),
              );
            }
          }
          // 内容/思考增量（与 tool_calls 同一 delta 可能并存）；
          // 结束 chunk（delta 空但 finish_reason 非空）也要产出
          if ((thinking?.isNotEmpty ?? false) ||
              (content?.isNotEmpty ?? false) ||
              fr != null) {
            yield LlmToolsDelta(
              thinking: thinking,
              content: content,
              finishReason: fr,
            );
          }
        } catch (_) {
          // 单行解析失败跳过
        }
      }
      yield const LlmToolsDelta(done: true);
    } finally {
      client.close();
    }
  }

  /// 标题生成提示词：始终要求中文标题（应用为中文界面，
  /// 与 llama.cpp TITLE_GENERATION.DEFAULT_PROMPT 同构）。
  /// 用户在通用设置里配了自定义提示词时，本方法不调用。
  String _buildTitlePrompt(String user, String assistant) {
    final body = 'User: $user\n\nAssistant: $assistant\n\nTitle:';
    return '根据下面的对话，生成一个简短精炼的标题（6-8 个汉字），'
        '概括对话主题。只返回标题文字，不要任何其他内容，不要使用引号。'
        '\n\n$body';
  }

  /// 生成会话标题（llama.cpp 风格）：独立短请求，返回模型原始输出
  /// （清洗与回退逻辑在调用方）。失败返回空串。
  /// [customPrompt] 非空时优先使用（含 {{USER}}/{{ASSISTANT}} 占位符，
  /// 由用户在通用设置里配置）；否则用内置默认提示词。
  Future<String> generateTitle(
    String userContent,
    String assistantContent, {
    required String model,
    String? customPrompt,
  }) async {
    final prompt = (customPrompt != null && customPrompt.trim().isNotEmpty)
        ? customPrompt
              .replaceAll('{{USER}}', userContent)
              .replaceAll('{{ASSISTANT}}', assistantContent)
        : _buildTitlePrompt(userContent, assistantContent);
    final url = Uri.parse(
      '${_baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions',
    );
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              if (_apiKey.trim().isNotEmpty) 'Authorization': 'Bearer $_apiKey',
            },
            body: jsonEncode({
              // 标题生成用当前模型（短输出，不思考）。
              // max_tokens 不能太小：思考型模型（deepseek-reasoner 等）会先
              // 消耗大量 token 思考，预算不足时 content 为空、标题丢失
              'model': model,
              'messages': [
                {'role': 'user', 'content': prompt},
              ],
              'stream': false,
              'max_tokens': 1024,
              'temperature': 0.3,
            }),
          )
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return '';
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) return '';
      final msg =
          (choices.first as Map<String, dynamic>)['message']
              as Map<String, dynamic>?;
      // content 优先；思考型模型 content 可能仍为空（思考占满预算）——
      // 回退取思考结尾含中文的最后一行（中文标题要求；思考常以英文进行，
      // 优先引号内结论，如 `I'll go with "A Poem About Spring"`）
      var title = msg?['content'] as String? ?? '';
      if (title.trim().isEmpty) {
        final reasoning = msg?['reasoning_content'] as String? ?? '';
        final cjk = RegExp(r'[\u4e00-\u9fff]');
        for (final line in reasoning.trim().split('\n').reversed) {
          if (line.trim().isEmpty) continue;
          final quoted = RegExp(r'"([^"]+)"').firstMatch(line);
          final candidate = quoted?.group(1) ?? line;
          if (candidate.contains(cjk)) {
            title = candidate;
            break;
          }
        }
      }
      return title;
    } catch (_) {
      return '';
    }
  }
}
