import 'dart:async';
import 'dart:convert'
    show base64Decode, base64Encode, jsonDecode, jsonEncode, utf8;
import 'dart:io' show Directory, File;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:cupertino_liquid_glass/cupertino_liquid_glass.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:inspire_blur/inspire_blur.dart';
import 'package:photo_view/photo_view.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:screen_corner_radius/screen_corner_radius.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat.dart';
import 'general_settings.dart';
import 'ui_tokens.dart';
import 'markdown_view.dart';
import 'mcp.dart';
import 'settings_page.dart';

/// ── 模型复合身份（方案 A）──
/// 模型唯一键 = (提供方名, 模型 id) 二元组。
/// 运行时以编码字符串传递/存储（JSON 数组，避免用户输入的分隔符冲突），
/// 需还原时用 [_decodeModelKey] 解析。
typedef ModelKey = ({String provider, String id});

String _encodeModelKey(String provider, String id) =>
    jsonEncode([provider, id]);

ModelKey? _decodeModelKey(String s) {
  try {
    final j = jsonDecode(s);
    if (j is List && j.length == 2 && j[0] is String && j[1] is String) {
      return (provider: j[0], id: j[1]);
    }
  } catch (_) {}
  return null;
}

/// 品牌色：亮色模式与暗色模式各一份
const Color kBrandColorLight = Color(0xFF3D5AFE);
const Color kBrandColorDark = Color(0xFF8C9EFF);

/// 页面过渡：新页面从右滑入覆盖，前页面保持原位不动
/// （不左移、不缩小、不变透明——去掉 iOS 风格旧页左移效果）
class _SlideCoverPageTransitionsBuilder extends PageTransitionsBuilder {
  const _SlideCoverPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 仅驱动新页面自身滑入；旧页面不参与任何变换（保持原位）
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    );
  }
}

/// 页面背景：纯灰，无杂色
const Color kBackgroundLight = Color(0xFFF5F5F5);
const Color kBackgroundDark = Color(0xFF161616);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 沉浸式：内容延伸到状态栏后面
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 锁定竖屏（与 AndroidManifest screenOrientation 双保险）
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  // 预热模糊 shader，避免首帧卡顿
  Inspire.warmUp();
  runApp(const LlmUiApp());
}

class LlmUiApp extends StatefulWidget {
  const LlmUiApp({super.key});

  @override
  State<LlmUiApp> createState() => _LlmUiAppState();
}

class _LlmUiAppState extends State<LlmUiApp> {
  /// 主题模式（主流软件行为：默认跟随系统，可选浅色/深色，固化存档）
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    // 读取存档的主题模式（默认跟随系统）
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      final v = p.getString('theme_mode');
      setState(() {
        _themeMode = switch (v) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      });
    });
  }

  /// 循环切换：跟随系统 → 浅色 → 深色 → 跟随系统
  void _cycleTheme() {
    setState(() {
      _themeMode = switch (_themeMode) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      };
    });
    // 固化存档，重启保持
    SharedPreferences.getInstance().then(
      (p) => p.setString('theme_mode', _themeMode.name),
    );
  }

  /// 实际亮暗（跟随系统模式下按系统亮度判定）
  bool get _isDark =>
      _themeMode == ThemeMode.dark ||
      (_themeMode == ThemeMode.system &&
          WidgetsBinding.instance.platformDispatcher.platformBrightness ==
              Brightness.dark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LLM UI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: kBrandColorLight),
        scaffoldBackgroundColor: kBackgroundLight,
        // 页面切换：新页面从右滑入覆盖，前页面保持原位不动
        // （去掉旧页面左移/缩放效果）
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.iOS: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.macOS: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.windows: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.linux: _SlideCoverPageTransitionsBuilder(),
          },
        ),
        // ── 全局弹窗/提示风格统一（项目灰白语言）──
        dialogTheme: DialogThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent, // 去 surface tint 杂色
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.black.withValues(alpha: 0.85),
          contentTextStyle: const TextStyle(color: Colors.white),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors
                      .grey
                      .shade600 // 勾选：灰（项目无蓝色）
                : Colors.transparent,
          ),
          checkColor: const WidgetStatePropertyAll(Colors.white),
          side: const BorderSide(color: Colors.grey),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: kBrandColorDark,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: kBackgroundDark,
        // 页面切换：新页面从右滑入覆盖，前页面保持原位不动（与亮色主题一致）
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.iOS: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.macOS: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.windows: _SlideCoverPageTransitionsBuilder(),
            TargetPlatform.linux: _SlideCoverPageTransitionsBuilder(),
          },
        ),
        // ── 全局弹窗/提示风格统一（暗色）──
        dialogTheme: DialogThemeData(
          backgroundColor: kSheetBgDark,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: kSheetBgDark,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.white.withValues(alpha: 0.9),
          contentTextStyle: const TextStyle(color: Colors.black),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? Colors.grey.shade300
                : Colors.transparent,
          ),
          checkColor: const WidgetStatePropertyAll(Colors.black),
          side: const BorderSide(color: Colors.grey),
        ),
      ),
      themeMode: _themeMode,
      home: AnnotatedRegion<SystemUiOverlayStyle>(
        // 沉浸式系统栏：状态栏/小白条透明，图标颜色跟随实际亮暗
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: _isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: _isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: _isDark
              ? Brightness.light
              : Brightness.dark,
        ),
        child: HomePage(
          isDark: _isDark,
          themeMode: _themeMode,
          onToggleTheme: _cycleTheme,
        ),
      ),
    );
  }
}

/// 聊天滚动位置（非 reverse + CustomScrollView.center 锚定）：
/// - 上翻（不在底部）：offset 保持 → 顶部锚定天然，内容增长文字不动（零补偿）
/// - 贴底（变化前 extentAfter ≤ 0.5 且非拖动）：offset 钉在新底部（maxScrollExtent）
///   → 底部生长；同帧（correctForNewDimensions 布局阶段）执行，无闪烁
class ChatScrollPosition extends ScrollPositionWithSingleContext {
  ChatScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
  });

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    // 基线：保持当前 offset（非 reverse 顶部锚定，上翻文字不动）
    var target = newPosition.pixels;
    // 贴底：变化前在底部（距底 ≤0.5）且非拖动 → 钉在新底部（底部生长）
    if (activity is! DragScrollActivity && oldPosition.extentAfter <= 0.5) {
      target = newPosition.maxScrollExtent;
    }
    target = target.clamp(
      newPosition.minScrollExtent,
      newPosition.maxScrollExtent,
    );
    if (target != pixels) {
      correctPixels(target);
      return false; // 位置已纠正：重新布局循环（官方安全路径）
    }
    return true;
  }
}

/// 聊天滚动控制器：使用自定义 position（同帧补偿逻辑）
class ChatScrollController extends ScrollController {
  ChatScrollController();

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return ChatScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
    );
  }
}

/// 主页面：页眉（透明度渐变 + 模糊度渐变）+ 死区 + 滚动列表 + 底部输入栏
/// 右滑抽屉：当前页面（带圆角）右移缩小变暗变模糊，露出浅灰抽屉页面
class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.isDark,
    required this.themeMode,
    required this.onToggleTheme,
  });

  /// 是否深色模式（实际亮暗；跟随系统模式下按系统亮度）
  final bool isDark;

  /// 主题模式（跟随系统 / 浅色 / 深色，抽屉按钮循环切换）
  final ThemeMode themeMode;

  /// 循环切换主题模式
  final VoidCallback onToggleTheme;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  /// 死区高度：列表第一项（背景色块），随内容滚动
  static const double _deadZoneHeight = 45;

  /// 页眉体高度（玻璃区域，不含状态栏）

  /// 抽屉右移距离
  static const double _drawerShift = 300;

  /// 屏幕圆角半径（从系统获取，失败回退 28）
  double _screenCornerRadius = 28;

  /// 抽屉进度（0 关闭 ~ 1 全开），拖动与动画统一由它驱动。
  /// 动画帧由 AnimatedBuilder 重建（仅受进度影响的部分），
  /// 避免每帧 setState 重建整页（消息列表多时卡顿）
  late final AnimationController _drawerController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  /// 拖动起点（用于滑动角度阈值判定）
  Offset? _dragStart;

  /// 滑动角度阈值：与水平线夹角超过 30°（tan30°≈0.577）不触发抽屉
  static const double _dragAngleThreshold = 0.577;

  /// 思考深度状态：0 关闭 / 1 开启 / 2 最高
  int _thinkingDepth = 0;

  /// 页眉模型选择：当前模型名（裸 id，来自设置页提供方，默认无）
  String _modelName = '';

  /// 当前模型的归属提供方名（与 [_modelName] 合成模型唯一身份）
  String _currentProviderName = '';

  /// 当前模型复合键（provider + id 的编码串；空 = 未选模型）
  String get _currentKey =>
      _modelName.isEmpty ? '' : _encodeModelKey(_currentProviderName, _modelName);

  /// 模型提供方列表（设置页配置，持久化；默认预置无模型）
  List<ModelProvider> _providers = [];

  /// 模型索引：复合键 → 提供方（运行时物化，变更时重建，查询 O(1)）
  Map<String, ModelProvider> _modelIndex = {};

  /// 可选模型列表（裸 id 集合，供设置页 AI 标题选择等"按名"消费方使用）
  List<String> get _models => [
    for (final p in _providers)
      for (final m in p.models) m.id,
  ];

  /// 模型下拉选项：复合键集合（唯一、可区分重名），索引重建时同步更新
  List<String> get _modelKeys => _modelIndex.keys.toList();

  /// 按复合键查所属提供方（O(1)）
  ModelProvider? _providerFor(String key) => _modelIndex[key];

  /// 复合键显示标签：显示名优先；无显示名且重名时加提供方前缀消歧
  String _labelForKey(String key) {
    final k = _decodeModelKey(key);
    if (k == null) return key;
    final p = _modelIndex[key];
    if (p != null) {
      for (final m in p.models) {
        if (m.id == k.id && m.displayName != null && m.displayName!.isNotEmpty) {
          return m.displayName!;
        }
      }
    }
    final dup =
        _modelIndex.keys.where((x) => _decodeModelKey(x)?.id == k.id).length > 1;
    return dup ? '${k.provider}/${k.id}' : k.id;
  }

  /// 重建模型索引：仅在 _providers 变更的两个入口调用（启动加载、设置页回调）。
  /// 注意（方案 A 约束）：身份绑定于 provider.name——若未来开放"提供方改名"，
  /// 需在该改名点同步迁移 model_name 存档与重建索引。
  void _rebuildModelIndex() {
    _modelIndex = {
      for (final p in _providers)
        for (final m in p.models) _encodeModelKey(p.name, m.id): p,
    };
  }

  /// 按当前模型构建 LLM 服务（提供方配置；无模型返回 null）
  LlmService? _buildLlm() {
    final provider = _providerFor(_currentKey);
    if (provider == null || provider.baseUrl.isEmpty) return null;
    return LlmService(baseUrl: provider.baseUrl, apiKey: provider.apiKey);
  }

  /// 会话列表（本地持久化）
  List<Conversation> _conversations = [];

  /// 归档会话列表（内存缓存：设置页归档管理直接使用，进入零延迟；
  /// 恢复/删除后由 _onArchivedChanged 重载）
  List<Conversation> _archivedConversations = [];

  /// 通用设置（粘贴/标题策略/AI标题/渲染开关；本地持久化）
  GeneralSettings _general = GeneralSettings.defaults;

  /// 文字替换规则（显示层替换，来自设置页；发送/显示时应用）
  List<TextReplaceRule> _replaceRules = [];

  /// MCP 服务器列表（设置页配置，持久化）
  List<McpServer> _mcpServers = [];

  /// MCP 客户端连接池（按 server.id 缓存，按需 initialize）
  final Map<String, McpClient> _mcpClients = {};

  /// 无会话（新对话未发送）时暂存的会话级 MCP 配置，
  /// 首次发送创建 Conversation 时应用
  List<String>? _pendingMcpIds;

  /// 无会话时暂存的会话级内置工具开关（bool?，null = 跟随全局）
  bool? _pendingBuiltinTools;

  /// 当前会话 id（null = 新对话，发送首条消息时新建）
  String? _currentId;

  /// LLM 流式响应中（禁发送、显示停止按钮）
  bool _isResponding = false;

  /// ReAct 循环运行中（await-for 无法被 cancel 中断，用标志位让循环自行退出）
  bool _isReactRunning = false;

  /// 停止请求标志（ReAct 循环在检查点中断并清理）
  bool _stopRequested = false;

  /// 本次响应是否被截断（finish_reason = length；写回 assistantMsg.truncated）
  bool _lastTruncated = false;

  /// 中断流式用的当前订阅（停止按钮调用）
  StreamSubscription<Object>? _streamSub;

  /// 对话滚动控制（自动滚到底 + 上翻同帧补偿）
  final ChatScrollController _chatScroll = ChatScrollController();

  /// 滚动通知：跟踪用户手指拖动（当前无抢滚动逻辑，保留供调试）
  bool _onScrollNotification(ScrollNotification n) {
    return false;
  }

  ChatStore? _store;

  /// 当前会话的 system 提示词（会话级，新建对话不继承）
  String? get _prompt => _currentConversation?.systemPrompt;

  /// 内联编辑中的消息索引（null = 无；llama-ui 风格原地编辑）
  int? _editingIndex;

  /// 分支编辑中的用户消息索引（null = 无）。
  /// 与编辑共用内联编辑器，但确认后截断该消息之后的内容并重新生成（开启分支对话）
  int? _branchIndex;

  /// 是否在编辑系统提示词（内联，列表顶部）
  bool _editingSystem = false;

  /// 长按显示操作按钮的条目索引（null = 无）
  int? _historyLongPressed;

  /// 内联重命名标题的条目索引（null = 无）
  int? _renamingIndex;

  /// 历史对话搜索态（true 时标题下方显示搜索框）
  bool _historySearching = false;

  /// 历史搜索关键词（标题模糊匹配）
  String _historyQuery = '';

  /// 历史对话批量管理模式
  bool _batchMode = false;

  /// 批量管理选中的会话 id
  final Set<String> _batchSelected = {};

  /// 自动归档/清理周期定时器（每 6 小时）
  Timer? _maintainTimer;

  /// AI 标题生成（llama.cpp 风格）：新会话首轮回复完成后触发。
  /// 记录目标会话 id 与首条用户消息（仅一次，完成后清空）
  String? _titleGenConvId;
  String? _titleGenUser;

  /// 当前会话（无则 null）
  Conversation? get _currentConversation => _currentId == null
      ? null
      : _conversations.where((c) => c.id == _currentId).firstOrNull;

  /// 主动滚动到底（发送消息/切换会话等明确贴底场景）。
  /// 非 reverse：底部 = maxScrollExtent；流式贴底跟随由
  /// ChatScrollPosition 同帧钉底（无需此处调用）
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScroll.hasClients) return;
      _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
    });
  }

  /// 新建会话（_currentId 置空，主页列表清空；首次发送时落库）
  void _newConversation() {
    setState(() {
      _currentId = null;
      _historyLongPressed = null;
      // 清掉未消费的会话级 MCP 配置/内置工具暂存（每个新对话从跟随全局开始）
      _pendingMcpIds = null;
      _pendingBuiltinTools = null;
    });
  }

  /// 发送消息：追加用户消息 + 流式接收助手回复
  Future<void> _onSend(String text, List<String> attachmentNames) async {
    // 附件处理：图片 → 多模态 ImagePart（base64 原图真实上传）；
    // 文本文件（txt 等）→ 读取全文存入文件部件（llama.cpp 风格
    // File: 名称/Content，模型可阅读）；其他文件 → 名字拼进文本
    final imageParts = <ImagePart>[];
    final fileParts = <MessageFilePart>[];
    final nameParts = <String>[];
    for (final att in _attachments) {
      if (!att.isImage) {
        // PDF 解析为图像（通用设置开启时）：渲染每页为 PNG 图片，
        // 多模态模型可直接查看内容；失败/无页 → 降级为文件名
        if (_general.pdfAsImage && att.name.toLowerCase().endsWith('.pdf')) {
          try {
            final parts = await _pdfToImages(att);
            if (parts.isNotEmpty) {
              imageParts.addAll(parts);
              continue;
            }
          } catch (_) {}
        }
        // 文本类附件：读取内容存入文件部件；读取失败/内容为空 → 降级为文件名
        if (isTextAttachmentName(att.name)) {
          try {
            final (content, truncated) = await att.readText();
            if (content.trim().isNotEmpty) {
              fileParts.add(
                MessageFilePart(
                  name: att.name,
                  size: att.size ?? 0,
                  content: content,
                  truncated: truncated,
                ),
              );
              if (truncated) {
                _toast('${att.name} 较大，已截断前 $kMaxTextAttachmentBytes 字节');
              }
              continue;
            }
          } catch (_) {}
        }
        nameParts.add(att.name);
        continue;
      }
      try {
        final bytes = await att.readBytes();
        if (bytes.isEmpty) {
          nameParts.add(att.name);
          continue;
        }
        final mime = _mimeFromName(att.name);
        imageParts.add(
          ImagePart(
            name: att.name,
            mimeType: mime,
            dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
          ),
        );
      } catch (_) {
        // 读取失败：降级为文件名
        nameParts.add(att.name);
      }
    }
    final fullText = nameParts.isEmpty
        ? text
        : '${nameParts.map((n) => '[附件: $n]').join(' ')} $text';

    // 1) 取/新建会话
    final existing = _currentConversation;
    final bool isNewConv = existing == null;
    final Conversation conv;
    if (existing != null) {
      conv = existing;
    } else {
      conv = Conversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        // 默认标题 = 时间戳（llama.cpp：`Chat <时间戳>`）
        title: _defaultTitle(),
        messages: [],
        updatedAt: DateTime.now(),
        modelId: _modelName,
        // 新对话应用暂存的会话级 MCP 配置（null = 跟随全局）
        mcpServerIds: _pendingMcpIds,
        // 新对话应用暂存的内置工具开关（null = 跟随全局）
        builtinToolsEnabled: _pendingBuiltinTools,
      );
      _pendingMcpIds = null;
      _pendingBuiltinTools = null;
      setState(() {
        _conversations.insert(0, conv);
        _currentId = conv.id;
      });
    }

    // 2) 追加用户消息，然后请求回复
    // 文字替换：模型收到的文本 = 替换规则应用后的文本（用户看到的仍是显示文本）
    final modelText = applyModelRules(fullText, _replaceRules);
    setState(() {
      conv.messages.add(
        Message(role: Role.user, content: modelText, ts: DateTime.now())
          ..imageParts = imageParts.isEmpty ? null : imageParts
          ..fileParts = fileParts.isEmpty ? null : fileParts,
      );
      // 发送完成：清空附件条
      _attachments.clear();
      // 首条消息（会话刚建、或先建了 system 提示词的会话）：
      // 按通用设置的标题策略决定标题 + 是否触发 AI 标题
      if (conv.messages.length == 1) {
        switch (_general.titleStrategy) {
          case TitleStrategy.timestamp:
            // 保持新建会话时的时间戳标题，不覆盖
            break;
          case TitleStrategy.firstLine:
            if (text.trim().isNotEmpty) conv.title = _titleFromFirstLine(text);
          case TitleStrategy.ai:
            // 先首行（避免回复期间标题是默认时间戳），回复完成后 AI 覆盖
            if (text.trim().isNotEmpty) conv.title = _titleFromFirstLine(text);
            _titleGenConvId = conv.id;
            _titleGenUser = text;
        }
      }
    });
    if (isNewConv) await _persist(conv);
    _generate(conv);
  }

  /// 按扩展名推断图片 MIME（默认 image/jpeg）
  String _mimeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      'heic' => 'image/heic',
      'heif' => 'image/heif',
      'svg' => 'image/svg+xml',
      _ => 'image/jpeg',
    };
  }

  /// 将 PDF 附件解析为图像（每页渲染成 PNG 图片部件）。
  /// 用 pdfrx（pdfium 引擎，跨平台）。最多渲染前 10 页（防请求爆炸）；
  /// 失败时抛出让调用方降级为文件名
  Future<List<ImagePart>> _pdfToImages(_Attachment att) async {
    final p = att.path;
    if (p == null || p.isEmpty) return const [];
    final doc = await PdfDocument.openFile(p);
    try {
      final parts = <ImagePart>[];
      final count = math.min(doc.pages.length, 10);
      for (var i = 0; i < count; i++) {
        // 渲染宽 1024（高度按页面比例自动）
        final img = await doc.pages[i].render(width: 1024);
        if (img == null) continue;
        try {
          final raster = await img.createImage();
          final data = await raster.toByteData(format: ui.ImageByteFormat.png);
          if (data != null) {
            parts.add(
              ImagePart(
                name: '${att.name} 第${i + 1}页',
                mimeType: 'image/png',
                dataUrl:
                    'data:image/png;base64,${base64Encode(data.buffer.asUint8List())}',
              ),
            );
          }
        } finally {
          img.dispose();
        }
      }
      return parts;
    } finally {
      doc.dispose();
    }
  }

  /// 轻提示（项目统一风格）
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1500),
      ),
    );
  }

  /// 默认会话标题（llama.cpp：`Chat ${new Date().toLocaleString()}`）
  String _defaultTitle() {
    final now = DateTime.now();
    final pad = (int n) => n.toString().padLeft(2, '0');
    return 'Chat ${now.year}/${now.month}/${now.day} ${pad(now.hour)}:${pad(now.minute)}';
  }

  /// 从消息内容取标题（llama.cpp generateConversationTitle：第一条非空行）
  String _titleFromFirstLine(String content) {
    for (final line in content.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return content.trim();
  }

  /// 内置工具名（模型调用时区分 MCP 工具）
  static const kBuiltinTimeTool = 'builtin__get_current_time';
  static const kBuiltinLocationTool = 'builtin__get_location';
  static const kBuiltinSearchTool = 'builtin__web_search';

  /// 内置工具开关（当前对话生效值：会话级 ?? 全局）
  bool get _builtinToolsEffective {
    final conv = _currentConversation;
    if (conv != null) {
      return conv.builtinToolsEnabled ?? _general.builtinToolsEnabled;
    }
    return _pendingBuiltinTools ?? _general.builtinToolsEnabled;
  }

  /// 切换当前对话的内置工具开关（无会话时暂存，创建会话时应用）
  void _toggleBuiltinTools() {
    final next = !_builtinToolsEffective;
    final conv = _currentConversation;
    if (conv != null) {
      setState(() => conv.builtinToolsEnabled = next);
      _persist(conv);
    } else {
      setState(() => _pendingBuiltinTools = next);
    }
  }

  /// 收集所有可用工具（MCP + 内置），转成 OpenAI tools 格式。
  /// 工具名加前缀 `mcp__<serverId>__<toolName>` 防冲突；内置工具用 builtin__ 前缀。
  /// 返回 (tools 定义列表, 工具名→(server, tool) 映射)。失败的服务器跳过并提示
  Future<(List<Map<String, dynamic>>, Map<String, (McpServer, McpToolDef)>)>
  _collectMcpTools() async {
    // 当前模型不支持工具调用：不收集任何工具（内置 + MCP 一并禁用），
    // 请求不携带任何工具相关字段（走普通对话路径）
    if (!_modelSupportsTools) {
      return (<Map<String, dynamic>>[], <String, (McpServer, McpToolDef)>{});
    }
    final tools = <Map<String, dynamic>>[];
    final map = <String, (McpServer, McpToolDef)>{};
    // 内置工具（时间/位置/搜索）：会话级或全局开启时提供，按明细开关过滤
    if (_builtinToolsEffective) {
      tools.addAll([
        if (_general.builtinTimeEnabled) _builtinToolDefs[0],
        if (_general.builtinLocationEnabled) _builtinToolDefs[1],
        if (_general.builtinSearchEnabled) _builtinToolDefs[2],
      ]);
    }
    // 会话级 MCP 配置：null = 跟随全局（所有 enabled）；非 null = 仅该会话启用的 id
    final allowed = _currentMcpIds;
    for (final s in _mcpServers.where((x) => x.enabled)) {
      // stdio 服务器（无远程端点）：跳过，不产生连接失败的提示噪音
      if (s.isStdio) continue;
      // 会话自定义配置：只收集勾选的服务器
      if (allowed != null && !allowed.contains(s.id)) continue;
      try {
        final client = _mcpClients.putIfAbsent(
          s.id,
          () => McpClient(url: s.url, token: s.token),
        );
        final toolDefs = await client.listTools();
        for (final t in toolDefs) {
          final fullName = 'mcp__${s.id}__${t.name}';
          tools.add({
            'type': 'function',
            'function': {
              'name': fullName,
              'description': '[${s.name}] ${t.description}'.trim(),
              'parameters': t.inputSchema,
            },
          });
          map[fullName] = (s, t);
        }
      } catch (e) {
        _toast('MCP 服务器「${s.name}」连接失败，已跳过');
      }
    }
    return (tools, map);
  }

  /// 内置工具定义（OpenAI function calling 格式）：
  /// - 获取当前时间（含时区）
  /// - 获取设备地理位置（经纬度，需定位权限）
  /// - 联网搜索（DeepSeek Anthropic 兼容端点原生 web_search 服务端工具）
  static final List<Map<String, dynamic>> _builtinToolDefs = [
    {
      'type': 'function',
      'function': {
        'name': kBuiltinTimeTool,
        'description':
            '获取设备当前的日期和时间（含时区）。当用户询问当前时间、日期、'
            '今天是几号等实时信息时调用。',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': kBuiltinLocationTool,
        'description':
            '获取设备当前的地理位置（经纬度）。当用户询问当前位置、'
            '在哪个城市、定位等需要位置信息时调用。',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
    {
      'type': 'function',
      'function': {
        'name': kBuiltinSearchTool,
        'description':
            '联网搜索互联网获取实时信息（新闻、事件、资料、验证等）。'
            '当用户需要最新/不确定的信息，或你的知识无法回答时调用；'
            '返回带来源链接的搜索结果列表。',
        'parameters': {
          'type': 'object',
          'properties': {
            'query': {'type': 'string', 'description': '搜索查询词（简明扼要，一次搜索一个主题）'},
          },
          'required': ['query'],
        },
      },
    },
  ];

  /// 执行内置工具（时间/位置/联网搜索），返回给模型的结果文本。
  /// [query] 仅 web_search 使用（工具参数里的查询词）
  Future<String> _execBuiltinTool(String name, {String query = ''}) async {
    if (name == kBuiltinTimeTool) {
      final now = DateTime.now();
      final offset = now.timeZoneOffset;
      final sign = offset.isNegative ? '-' : '+';
      final h = offset.inHours.abs().toString().padLeft(2, '0');
      final m = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
      final pad = (int n) => n.toString().padLeft(2, '0');
      return '当前时间：${now.year}-${pad(now.month)}-${pad(now.day)} '
          '${pad(now.hour)}:${pad(now.minute)}:${pad(now.second)} '
          '（UTC$sign$h:$m，${now.timeZoneName}）';
    }
    if (name == kBuiltinLocationTool) {
      try {
        // 请求定位权限（首次弹窗）
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          return '无法获取位置：定位权限被拒绝。请到系统设置中开启定位权限后重试。';
        }
        if (!await Geolocator.isLocationServiceEnabled()) {
          return '无法获取位置：设备定位服务未开启。';
        }
        // 优先取缓存位置（秒回；forceLocationManager = 原生 LocationManager，
        // 不依赖 Google Play 服务——无 GMS 的设备 FusedLocationProvider 会挂起超时）
        final cached = await Geolocator.getLastKnownPosition(
          forceAndroidLocationManager: true,
        );
        if (cached != null) {
          return '设备当前地理位置：纬度 ${cached.latitude.toStringAsFixed(4)}，'
              '经度 ${cached.longitude.toStringAsFixed(4)}'
              '（精度约 ${cached.accuracy.toStringAsFixed(0)} 米）';
        }
        // 无缓存：实时定位（原生 LocationManager，20 秒内）
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: AndroidSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: const Duration(seconds: 20),
            forceLocationManager: true,
          ),
        );
        return '设备当前地理位置：纬度 ${pos.latitude.toStringAsFixed(4)}，'
            '经度 ${pos.longitude.toStringAsFixed(4)}'
            '（精度约 ${pos.accuracy.toStringAsFixed(0)} 米）';
      } catch (e) {
        return '无法获取位置：$e';
      }
    }
    if (name == kBuiltinSearchTool) {
      return _webSearch(query);
    }
    return '未知的内置工具：$name';
  }

  /// DeepSeek 原生联网搜索（Anthropic 兼容端点 + web_search_20250305
  /// 服务端工具，同 @deepseek-ai/dsh-web-search-deepseek 的做法）：
  /// 一次完整 Messages 调用，由 DeepSeek 服务器执行搜索，解析
  /// web_search_tool_result 结构化块，与 text 块 citations 摘录按 URL
  /// 关联后，格式化为带来源的列表返回给模型继续推理
  Future<String> _webSearch(String query) async {
    final q = query.trim();
    if (q.isEmpty) return '搜索失败：查询词为空';
    // 搜索绑死 DeepSeek 服务商：key 固定取 DeepSeek 提供方（预置不可删），
    // 与当前聊天模型所属提供方解耦——Kimi/Qwen/GLM 聊天时搜索照样可用
    ModelProvider? dsProvider;
    for (final p in _providers) {
      if (p.name == 'DeepSeek') {
        dsProvider = p;
        break;
      }
    }
    if (dsProvider == null || dsProvider.apiKey.isEmpty) {
      return '搜索失败：未配置 DeepSeek 服务商的 API Key（设置→模型提供方→DeepSeek）';
    }
    final apiKey = dsProvider.apiKey;
    // DeepSeek 搜索专用端点（Anthropic 格式，与聊天端点不同）
    const endpoint = 'https://api.deepseek.com/anthropic/v1/messages';
    try {
      final resp = await http
          .post(
            Uri.parse(endpoint),
            headers: {
              'x-api-key': apiKey,
              'authorization': 'Bearer $apiKey',
              'anthropic-version': '2023-06-01',
              'content-type': 'application/json',
              'accept': 'application/json',
            },
            body: jsonEncode({
              'model': _modelName,
              'max_tokens': 1024,
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'text',
                      'text': 'Perform a web search for the query: $q',
                    },
                  ],
                },
              ],
              'tools': [
                {
                  'type': 'web_search_20250305',
                  'name': 'web_search',
                  'max_uses': 5,
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        var msg = 'DeepSeek 搜索 API 错误（HTTP ${resp.statusCode}）';
        try {
          final e = jsonDecode(utf8.decode(resp.bodyBytes));
          final detail = e['error'];
          if (detail is Map && detail['message'] != null) {
            msg = detail['message'].toString();
          }
        } catch (_) {}
        return '搜索失败：$msg';
      }
      final data =
          jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final blocks = (data['content'] as List?) ?? const [];
      // 1) 收集 web_search_result 条目（url/title/page_age）
      final results = <Map<String, String>>[];
      for (final b in blocks) {
        if (b is! Map || b['type'] != 'web_search_tool_result') continue;
        for (final item in (b['content'] as List? ?? const [])) {
          if (item is! Map || item['type'] != 'web_search_result') continue;
          results.add({
            'url': item['url']?.toString() ?? '',
            'title': item['title']?.toString() ?? '',
            'page_age': item['page_age']?.toString() ?? '',
          });
        }
      }
      if (results.isEmpty) {
        return '搜索失败：未返回结构化搜索结果（可能未触发原生搜索），请换关键词重试';
      }
      // 2) citations 摘录（text 块内，按 url 关联；首个出现优先）
      final snippets = <String, String>{};
      for (final b in blocks) {
        if (b is! Map || b['type'] != 'text') continue;
        for (final c in (b['citations'] as List? ?? const [])) {
          if (c is! Map) continue;
          final u = c['url']?.toString() ?? '';
          final s = c['cited_text']?.toString() ?? '';
          if (u.isNotEmpty && s.isNotEmpty && !snippets.containsKey(u)) {
            snippets[u] = s;
          }
        }
      }
      // 3) 格式化：去重（max_uses>1 时同一页面可能多次出现）+ 摘录
      final lines = <String>['搜索到 ${results.length} 个结果：'];
      final seen = <String>{};
      var i = 0;
      for (final r in results) {
        final url = r['url']!;
        if (url.isEmpty || !seen.add(url)) continue;
        i++;
        final title = r['title'] ?? '';
        final pageAge = r['page_age'] ?? '';
        final snippet = snippets[url] ?? '';
        lines.add('$i. ${title.isEmpty ? url : title}');
        if (pageAge.isNotEmpty) lines.add('   （$pageAge）');
        lines.add('   $url');
        if (snippet.isNotEmpty) lines.add('   $snippet');
      }
      return lines.join('\n');
    } on TimeoutException {
      return '搜索失败：请求超时（30 秒），请稍后重试';
    } catch (e) {
      return '搜索失败：$e';
    }
  }

  /// ReAct 消息 content 载荷：有图片 → OpenAI 多模态数组（与
  /// LlmService._contentPayload 一致）；否则纯文本
  Object _reactContentPayload(Message m) {
    final images = m.imageParts;
    if (images == null || images.isEmpty) return m.modelContent;
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

  /// MCP ReAct 工具调用对话：模型自主决定调用 MCP 工具并迭代回答。
  /// 工具调用以卡片形式实时追加到助手消息（工具名 + 参数 + 状态）
  Future<void> _runMcpReact(
    Conversation conv,
    Message assistantMsg,
    LlmService llm,
    String model,
    String? systemPrompt,
    List<Map<String, dynamic>> mcpTools,
    Map<String, (McpServer, McpToolDef)> toolMap, {
    int thinkingDepth = 1,
  }) async {
    // 轮数上限（可配置）：工具可随时调用，多留一轮给最终回答；
    // 模型在上限内仍可正常回答，极端情况下全调工具也不会无限循环
    final maxRounds = _general.reactMaxRounds.clamp(2, 20);
    // 循环独立气泡：每轮一个 assistant 气泡，工具调用作为轮次分割。
    // 第一轮复用 _generate 创建的占位气泡，之后每轮结束创建新气泡
    var current = assistantMsg..toolCalls = [];
    // 基础消息列表（含多模态 content）；排除末尾的空助手占位
    final historyList = [...conv.messages]..removeLast();
    final messages = <Map<String, dynamic>>[
      if (systemPrompt != null && systemPrompt.trim().isNotEmpty)
        {'role': 'system', 'content': systemPrompt.trim()},
      ...historyList
          .where(
            (m) =>
                m.content.isNotEmpty ||
                (m.imageParts?.isNotEmpty ?? false) ||
                (m.fileParts?.isNotEmpty ?? false) ||
                (m.thinking?.isNotEmpty ?? false),
          )
          .map(
            (m) => {
              'role': m.role == Role.user ? 'user' : 'assistant',
              // 图片走多模态数组（同 LlmService._contentPayload）——
              // 否则图片消息在 ReAct 路径下丢失
              'content': _reactContentPayload(m),
            },
          ),
    ];

    // 停止时清理当前气泡：空则删除，非空则正常完成
    void finishOnStop() {
      _flushStreamBufferNow(); // 残余 delta 先上屏再判定空/截断
      final empty =
          current.content.trim().isEmpty &&
          (current.thinking?.trim().isEmpty ?? true) &&
          (current.toolCalls?.isEmpty ?? true);
      if (empty) {
        setState(() {
          conv.messages.remove(current);
          _isResponding = false;
        });
        _persist(conv);
      } else {
        // 停止 = 输出未完成：标记截断，气泡下显示工具栏 + 可继续生成
        current.truncated = true;
        _finishResponding(conv, current);
      }
    }

    try {
      // 是否正常回答退出（模型给出直接回答 break）；false = 循环耗尽
      var answered = false;
      for (var round = 0; round < maxRounds; round++) {
        if (_stopRequested) {
          finishOnStop();
          return;
        }
        // 每轮都带工具：模型可随时再搜索/查询。之前最后一轮不带工具
        // （强制回答防死循环），但模型在无工具时可能凭惯性输出 XML
        // 工具调用文本（llama.cpp 风格 <tool_calls>）而非回答——
        // 轮数上限 +1 留给最终回答，XML 调用见下方识别兜底
        final acc = StringBuffer();
        final pendingCalls = <int, ({String id, String name, String args})>{};
        // 本轮结束原因（'length' = 输出被截断）
        var roundFinish = '';
        await for (final d in llm.chatWithTools(
          messages,
          model: model,
          thinkingDepth: thinkingDepth,
          tools: mcpTools,
        )) {
          if (!mounted) return;
          if (_stopRequested) {
            finishOnStop();
            return;
          }
          if (d.done) break;
          if (d.finishReason == 'length') roundFinish = 'length';
          if ((d.thinking?.isNotEmpty ?? false) ||
              (d.content?.isNotEmpty ?? false)) {
            // 流式节流：delta 累积后 ~30fps 合并上屏
            _streamAccumulate(current, d.thinking, d.content, acc: acc);
          }
          if (d.toolCall != null) {
            final tc = d.toolCall!;
            final existing =
                pendingCalls[tc.index] ?? (id: '', name: '', args: '');
            pendingCalls[tc.index] = (
              id: existing.id + (tc.id ?? ''),
              name: existing.name + (tc.name ?? ''),
              args: existing.args + (tc.arguments ?? ''),
            );
          }
        }
        // 无 JSON 工具调用 → 检查模型是否以 XML 文本形式输出了工具调用
        //（llama.cpp 风格 <tool_calls><invoke name="...">）；识别后
        // 当作真实工具调用执行，避免把调用语法原文当成最终回答
        if (pendingCalls.isEmpty) {
          final xmlCalls = _parseXmlToolCalls(acc.toString());
          if (xmlCalls.isNotEmpty) {
            acc.clear();
            var idx = 0;
            for (final c in xmlCalls) {
              pendingCalls[idx++] = (id: '', name: c.name, args: c.args);
            }
          }
        }
        // 无工具调用 → 本轮即最终回答（当前气泡就是最终气泡）
        if (pendingCalls.isEmpty) {
          current.truncated = roundFinish == 'length';
          answered = true;
          break;
        }

        // 追加 assistant 消息（含 tool_calls），执行工具。
        // 注意：一条 assistant 消息的每个 tool_call_id 都必须有对应 tool 消息，
        // 所以全部工具执行完后再统一追加「一条 assistant + 全部 tool 消息」
        // （逐条追加且 assistant 带累积列表会导致服务器 400）
        final assistantToolCalls = <Map<String, dynamic>>[];
        final toolMessages = <Map<String, dynamic>>[];
        for (final entry
            in pendingCalls.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))) {
          if (_stopRequested) {
            finishOnStop();
            return;
          }
          final call = entry.value;
          final toolCallId = call.id.isEmpty ? 'call_${entry.key}' : call.id;
          assistantToolCalls.add({
            'id': toolCallId,
            'type': 'function',
            'function': {'name': call.name, 'arguments': call.args},
          });
          // 卡片：工具名（去前缀）+ 参数摘要，挂在本轮气泡上。
          // 内置工具名剥离 builtin__ 前缀
          final toolDef = toolMap[call.name];
          final displayName = call.name.startsWith('builtin__')
              ? call.name.substring('builtin__'.length)
              : (toolDef?.$2.name ?? call.name);
          final card = ToolCallRecord(
            name: displayName,
            query: _summarizeArgs(call.args),
          );
          setState(() => current.toolCalls!.add(card));

          // 执行工具：内置工具走本地执行，MCP 工具走远程调用
          String resultText;
          int resultCode;
          try {
            if (call.name.startsWith('builtin__')) {
              final args = _parseArgs(call.args);
              resultText =
                  await _execBuiltinTool(
                    call.name,
                    query: (args['query'] as String?) ?? '',
                  ).timeout(
                    // 内置工具整体超时（位置工具含权限弹窗 + 定位，需留足时间）
                    const Duration(seconds: 35),
                    onTimeout: () => '内置工具调用超时（35 秒），请稍后重试',
                  );
              resultText = resultText.isEmpty ? '(空结果)' : resultText;
              resultCode = resultText.length;
            } else {
              final server = toolDef!.$1;
              final client = _mcpClients[server.id]!;
              final args = _parseArgs(call.args);
              final result = await client.callTool(toolDef.$2.name, args);
              resultText = result.text.isEmpty ? '(空结果)' : result.text;
              resultCode = resultText.length;
            }
          } catch (e) {
            resultText = '工具调用失败：$e';
            resultCode = -1;
          }
          if (!mounted) return;
          if (_stopRequested) {
            finishOnStop();
            return;
          }
          setState(() => card.resultCount = resultCode);
          toolMessages.add({
            'role': 'tool',
            'tool_call_id': toolCallId,
            'content': resultText,
          });
        }
        // 统一追加：一条 assistant（完整 tool_calls）+ 全部 tool 响应
        messages
          ..add({
            'role': 'assistant',
            'content': acc.toString(),
            'tool_calls': assistantToolCalls,
          })
          ..addAll(toolMessages);
        // 分割由请求动作驱动：本轮请求响应（含工具调用）结束后，
        // 发送工具结果，下一次请求开启新的独立气泡。
        // 工具卡片与分支留在发起请求的本轮气泡上（不做前端移交）
        final next = Message(
          role: Role.assistant,
          content: '',
          ts: DateTime.now(),
        )..toolCalls = [];
        setState(() {
          conv.messages.add(next);
          conv.updatedAt = DateTime.now();
        });
        current = next;
      }
      // 循环结束前 flush 残余 buffer（最后 round 的尾部 token 不丢）
      _flushStreamBufferNow();
      // 循环自然耗尽（!answered）= 每轮都在调用工具，模型始终未给出
      // 直接回答：最后气泡标记截断，并追加红色提醒气泡（提示上限已到）
      if (!answered) {
        current.truncated = true;
        setState(() {
          conv.messages.add(
            Message(
              role: Role.assistant,
              content:
                  '⚠️ 工具调用已达上限（$maxRounds 轮），模型未完成回答，'
                  '输出已截断。可调高「通用设置 → 工具循环上限」后重试。',
              ts: DateTime.now(),
              error: true,
            ),
          );
        });
      }
      if (mounted) _finishResponding(conv, current);
    } catch (e) {
      _flushStreamBufferNow();
      if (mounted) _onRespondError(conv, current, e);
    } finally {
      _isReactRunning = false;
    }
  }

  /// 参数摘要（卡片副标题）：JSON 解析后取 value 拼接，失败用原始串
  String _summarizeArgs(String args) {
    final t = args.trim();
    if (t.isEmpty) return '';
    try {
      final j = jsonDecode(t) as Map<String, dynamic>;
      final vals = j.values.map((v) => v.toString()).where((s) => s.isNotEmpty);
      final joined = vals.join(' / ');
      return joined.isEmpty ? t : joined;
    } catch (_) {
      return t;
    }
  }

  Map<String, dynamic> _parseArgs(String args) {
    final t = args.trim();
    if (t.isEmpty) return {};
    try {
      return jsonDecode(t) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// 解析模型以 XML 文本形式输出的工具调用（llama.cpp 风格，
  /// 如 `<tool_calls><invoke name="tool"><parameter name="a">v</parameter></invoke></tool_calls>`）。
  /// 返回 (工具名, JSON 参数串) 列表；文本不是工具调用格式时返回空
  List<({String name, String args})> _parseXmlToolCalls(String text) {
    final out = <({String name, String args})>[];
    if (!text.contains('<tool_calls>') && !text.contains('<invoke')) {
      return out;
    }
    final invokeRe = RegExp(
      r'<invoke\s+name="([^"]+)"[^>]*>([\s\S]*?)</invoke>',
    );
    for (final m in invokeRe.allMatches(text)) {
      final name = m.group(1)!.trim();
      if (name.isEmpty) continue;
      final body = m.group(2) ?? '';
      final args = <String, dynamic>{};
      final paramRe = RegExp(
        r'<parameter\s+name="([^"]+)"[^>]*>([\s\S]*?)</parameter>',
      );
      for (final pm in paramRe.allMatches(body)) {
        final key = pm.group(1)!.trim();
        var value = pm.group(2)!.trim();
        // 剥掉参数值最外层的成对引号（模型常把字符串参数写成 "xxx"）
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        if (key.isNotEmpty) args[key] = value;
      }
      out.add((name: name, args: jsonEncode(args)));
    }
    return out;
  }

  /// 请求助手回复：追加空助手占位 + 流式接收（发送/重新生成/编辑后复用）。
  /// 有 MCP 工具时走 ReAct 循环（模型自主决定调用工具）
  Future<void> _generate(Conversation conv) async {
    if (_isResponding) return; // 已有响应进行中
    // 重置停止标志（ReAct 循环检查点用）
    _stopRequested = false;
    _lastTruncated = false;
    // 复用最后一条「空助手消息」（重新生成场景：内容已清空，版本存于 versions），
    // 否则新增占位——避免重新生成后出现多余空消息
    Message assistantMsg;
    final last = conv.messages.isNotEmpty ? conv.messages.last : null;
    if (last != null &&
        last.role == Role.assistant &&
        last.content.isEmpty &&
        (last.thinking?.isEmpty ?? true)) {
      assistantMsg = last;
    } else {
      assistantMsg = Message(
        role: Role.assistant,
        content: '',
        ts: DateTime.now(),
      );
      conv.messages.add(assistantMsg);
    }
    setState(() {
      conv.updatedAt = DateTime.now();
      _isResponding = true;
    });
    _scrollToBottom();

    // 模型名：跟随页眉下拉选择，直接发给服务器（测试服务为局域网模型）
    // 思考深度不再切换模型名，仅作为 UI 偏好——模型返回 reasoning_content 时显示思考块
    final model = _modelName;
    // system 提示词 = 会话级提示词原样发送。
    // 思考深度不注入任何提示词，只通过请求参数控制
    // （chat_template_kwargs / thinking 对象 / reasoning_effort）
    final finalPrompt = (conv.systemPrompt ?? '').trim();
    // 按当前模型构建服务（提供方配置）；无模型/无地址 → 提示
    final llm = _buildLlm();
    if (llm == null) {
      _toast('未配置模型，请到设置页获取模型');
      _onRespondError(conv, assistantMsg, '未配置模型');
      return;
    }
    // MCP 工具：有启用的服务器 → 收集工具走 ReAct 循环（模型自主调用工具）
    final (mcpTools, toolMap) = await _collectMcpTools();
    if (mcpTools.isNotEmpty) {
      _isReactRunning = true;
      await _runMcpReact(
        conv,
        assistantMsg,
        llm,
        model,
        finalPrompt.isEmpty ? null : finalPrompt,
        mcpTools,
        toolMap,
        thinkingDepth: _thinkingDepth,
      );
      return;
    }
    try {
      _streamSub = llm
          .chat(
            [...conv.messages]..removeLast(),
            model: model,
            systemPrompt: finalPrompt.isEmpty ? null : finalPrompt,
            thinkingDepth: _thinkingDepth,
          )
          .listen(
            (delta) {
              if (!mounted) return;
              // 输出被截断标记（finish_reason = length）
              if (delta.finishReason == 'length') _lastTruncated = true;
              // 流式节流：delta 累积后 ~30fps 合并上屏
              _streamAccumulate(assistantMsg, delta.thinking, delta.content);
            },
            onDone: () {
              // 结束前 flush 残余 buffer（最后几个 token 不丢）
              _flushStreamBufferNow();
              assistantMsg.truncated = _lastTruncated;
              _finishResponding(conv, assistantMsg);
            },
            onError: (e) {
              _flushStreamBufferNow();
              _onRespondError(conv, assistantMsg, e);
            },
            cancelOnError: true,
          );
    } catch (e) {
      _onRespondError(conv, assistantMsg, e);
    }
  }

  /// ── 流式节流：token 级 delta 合并到 ~30fps 才 setState。
  /// 整页 rebuild 是流式期间最大开销（此前每 token 一次）；
  /// 视觉无感知（~33ms 一帧），长回复 CPU/掉帧大幅下降。
  /// [_lastStreamFlushMs] 首帧为 0 → 首个 delta 立即上屏 ──
  String _streamBufThinking = '';
  String _streamBufContent = '';
  Timer? _streamFlushTimer;
  Message? _streamMsg;
  int _lastStreamFlushMs = 0;

  /// 累积流式 delta（[acc] 为 ReAct 本轮的 content 缓冲，需即时同步）
  void _streamAccumulate(
    Message msg,
    String? thinking,
    String? content, {
    StringBuffer? acc,
  }) {
    _streamMsg = msg;
    if (thinking != null && thinking.isNotEmpty) {
      _streamBufThinking += thinking;
    }
    if (content != null && content.isNotEmpty) {
      _streamBufContent += content;
      acc?.write(content);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastStreamFlushMs;
    if (elapsed >= 33) {
      _lastStreamFlushMs = now;
      _applyStreamBuffer();
    } else {
      _streamFlushTimer ??= Timer(Duration(milliseconds: 33 - elapsed), () {
        _streamFlushTimer = null;
        _lastStreamFlushMs = DateTime.now().millisecondsSinceEpoch;
        if (mounted) _applyStreamBuffer();
      });
    }
  }

  void _applyStreamBuffer() {
    final msg = _streamMsg;
    if (msg == null) return;
    final t = _streamBufThinking;
    final c = _streamBufContent;
    _streamBufThinking = '';
    _streamBufContent = '';
    if (t.isEmpty && c.isEmpty) return;
    setState(() {
      if (t.isNotEmpty) msg.thinking = (msg.thinking ?? '') + t;
      if (c.isNotEmpty) msg.content += c;
    });
  }

  /// 流式结束/停止/出错前调用：flush 残余 buffer（保证最后几个 token 不丢）
  void _flushStreamBufferNow() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _applyStreamBuffer();
  }

  /// ── 显示层规则替换小缓存：流式重建时旧消息原文不变直接命中，
  /// 跳过全量 replaceAll（规则列表引用变化时整体失效）；
  /// 只缓存中短文本，长消息/超限清空防内存膨胀 ──
  final Map<String, String> _displayCache = {};
  List<TextReplaceRule>? _displayCacheRules;

  String _displayCached(String raw) {
    if (!identical(_displayCacheRules, _replaceRules)) {
      _displayCacheRules = _replaceRules;
      _displayCache.clear();
    }
    final hit = _displayCache[raw];
    if (hit != null) return hit;
    final out = applyDisplayRules(raw, _replaceRules);
    if (raw.length <= 20000) {
      if (_displayCache.length >= 16) _displayCache.clear();
      _displayCache[raw] = out;
    }
    return out;
  }

  /// 复制消息内容（助手消息复制正式回复；复制用户看到的显示文本）
  Future<void> _copyMessage(Message m) async {
    final raw = m.content.isEmpty ? (m.thinking ?? '') : m.content;
    final text = applyDisplayRules(raw, _replaceRules);
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 删除消息：只删除该条消息本身，不影响其后的消息
  /// （如删除问题时不会把回答删掉，与 llama.cpp 一致）
  Future<void> _deleteMessage(int index) async {
    final conv = _currentConversation;
    if (conv == null) return;
    setState(() {
      conv.messages.removeAt(index);
      // 该条正在编辑/分支编辑则一并退出
      if (_editingIndex == index) _editingIndex = null;
      if (_branchIndex == index) _branchIndex = null;
    });
    await _persist(conv);
  }

  /// 编辑提示词（加号面板"提示词"按钮）
  /// 参考 llama-ui 编辑框：多行输入 + Cancel/Save 按钮行
  /// 进入系统提示词内联编辑态（加号面板"提示词"按钮；llama-ui 风格原地编辑）
  /// 提示词是会话级的：无会话时先新建一个空会话作为载体
  void _editPrompt() {
    if (_currentConversation == null) {
      final conv = Conversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: _defaultTitle(),
        messages: [],
        updatedAt: DateTime.now(),
        modelId: _modelName,
      );
      setState(() {
        _conversations.insert(0, conv);
        _currentId = conv.id;
        _editingSystem = true;
        _editingIndex = null;
      });
      _persist(conv);
      return;
    }
    setState(() {
      _editingSystem = true;
      _editingIndex = null;
    });
  }

  /// 应用提示词模板到当前会话（无会话时先新建空会话作为载体）
  void _applyPromptTemplate(PromptTemplate t) {
    if (_currentConversation == null) {
      final conv = Conversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: _defaultTitle(),
        messages: [],
        updatedAt: DateTime.now(),
        modelId: _modelName,
      );
      setState(() {
        _conversations.insert(0, conv);
        _currentId = conv.id;
        conv.systemPrompt = t.prompt;
      });
      _persist(conv);
    } else {
      final conv = _currentConversation!;
      setState(() => conv.systemPrompt = t.prompt);
      _persist(conv);
    }
  }

  // ── 提示词模板（内置种子 + 自定义，统一持久化）──
  static const _kAllTemplatesKey = 'prompt_templates_all';
  static const _kLegacyCustomKey = 'prompt_templates_custom';

  /// 加载模板列表：优先本地持久化（含用户增删改后的完整列表）；
  /// 首次使用以内置模板为种子；兼容旧版单独存储的自定义模板
  Future<List<PromptTemplate>> _loadAllTemplates() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kAllTemplatesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List;
        return [
          for (final e in list)
            if (e is Map)
              PromptTemplate(
                (e['name'] as String?) ?? '未命名',
                (e['description'] as String?) ?? '',
                (e['prompt'] as String?) ?? '',
              ),
        ];
      } catch (_) {}
    }
    // 兼容旧版：自定义模板合并到内置种子
    final legacy = p.getString(_kLegacyCustomKey);
    if (legacy != null && legacy.isNotEmpty) {
      try {
        final list = jsonDecode(legacy) as List;
        return [
          ...kBuiltinPromptTemplates,
          for (final e in list)
            if (e is Map)
              PromptTemplate(
                (e['name'] as String?) ?? '未命名',
                '自定义模板',
                (e['prompt'] as String?) ?? '',
              ),
        ];
      } catch (_) {}
    }
    return [...kBuiltinPromptTemplates];
  }

  Future<void> _saveAllTemplates(List<PromptTemplate> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kAllTemplatesKey,
      jsonEncode([
        for (final t in list)
          {'name': t.name, 'description': t.description, 'prompt': t.prompt},
      ]),
    );
  }

  /// 提示词模板悬浮界面（顶部对齐浮层，两列网格）：
  /// 短按应用；长按卡片 → 左右浮现 编辑/删除 图标按钮（居中）；
  /// 添加/编辑是同一界面的表单层级（返回可回到列表层级）
  Future<void> _showPromptTemplateSheet() async {
    final loaded = await _loadAllTemplates();
    if (!mounted) return;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '提示词模板',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 200),
      transitionBuilder: (context, anim, _, child) =>
          FadeTransition(opacity: anim, child: child),
      pageBuilder: (context, _, _) {
        final scheme = Theme.of(context).colorScheme;
        final dark = Theme.of(context).brightness == Brightness.dark;
        // 浮层内可变状态（pageBuilder 只执行一次，闭包持有不重置）
        final templates = [...loaded];
        PromptTemplate? actionTarget;
        // 表单层级状态：null 且 !adding = 列表层级
        PromptTemplate? formTarget;
        var adding = false;
        final nameCtrl = TextEditingController();
        final promptCtrl = TextEditingController();
        // 短按应用模板
        void apply(PromptTemplate t) {
          Navigator.of(context).pop();
          _applyPromptTemplate(t);
        }

        // 进入表单层级（添加 / 编辑）
        void openForm(PromptTemplate? t) {
          formTarget = t;
          adding = t == null;
          nameCtrl.text = t?.name ?? '';
          promptCtrl.text = t?.prompt ?? '';
        }

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final inForm = adding || formTarget != null;
            return Center(
              // 悬浮界面居中，固定大小（高度取较大值，顶部空隙小）
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 24,
                ),
                child: Material(
                  color: dark ? kSheetBgDark : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: SizedBox(
                    width: math.min(420, MediaQuery.sizeOf(context).width - 48),
                    height: math.min(
                      480,
                      MediaQuery.sizeOf(context).height - 48,
                    ),
                    child: inForm
                        // ── 表单层级：标题 + 滚动输入区 + 底部固定按钮行 ──
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.arrow_back,
                                        size: 20,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      tooltip: '返回',
                                      onPressed: () {
                                        adding = false;
                                        formTarget = null;
                                        setSheetState(() {});
                                      },
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      adding ? '添加模板' : '编辑模板',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                // 输入区：名称框下移（label 不被遮挡），
                                // 内容框撑满剩余高度（到底）
                                Expanded(
                                  child: LayoutBuilder(
                                    builder: (context, c) => SingleChildScrollView(
                                      padding: EdgeInsets.only(
                                        bottom: MediaQuery.viewInsetsOf(
                                          context,
                                        ).bottom,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const SizedBox(height: 10),
                                          TextField(
                                            controller: nameCtrl,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                            // 与全应用输入风格统一：灰色填充圆角
                                            decoration: InputDecoration(
                                              filled: true,
                                              fillColor: Colors.grey.withValues(
                                                alpha: 0.15,
                                              ),
                                              labelText: '模板名称',
                                              labelStyle: TextStyle(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                              floatingLabelStyle: TextStyle(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                              isDense: true,
                                              border: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide.none,
                                              ),
                                              enabledBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide.none,
                                              ),
                                              focusedBorder: OutlineInputBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                borderSide: BorderSide(
                                                  color: scheme.onSurface
                                                      .withValues(alpha: 0.3),
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 16),
                                          // 内容框撑满剩余高度（到底），
                                          // 内容超长时框内滚动
                                          SizedBox(
                                            height: math.max(
                                              160,
                                              c.maxHeight - 74,
                                            ),
                                            child: TextField(
                                              controller: promptCtrl,
                                              maxLines: null,
                                              expands: true,
                                              textAlignVertical:
                                                  TextAlignVertical.top,
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodyMedium,
                                              decoration: InputDecoration(
                                                filled: true,
                                                fillColor: Colors.grey
                                                    .withValues(alpha: 0.15),
                                                labelText: '提示词内容',
                                                labelStyle: TextStyle(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                                floatingLabelStyle: TextStyle(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                                alignLabelWithHint: true,
                                                border: OutlineInputBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  borderSide: BorderSide.none,
                                                ),
                                                enabledBorder:
                                                    OutlineInputBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      borderSide:
                                                          BorderSide.none,
                                                    ),
                                                focusedBorder:
                                                    OutlineInputBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                      borderSide: BorderSide(
                                                        color: scheme.onSurface
                                                            .withValues(
                                                              alpha: 0.3,
                                                            ),
                                                      ),
                                                    ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                // 按钮行：固定在浮层底部
                                Row(
                                  children: [
                                    if (formTarget != null)
                                      TextButton(
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.red
                                              .withValues(alpha: 0.8),
                                        ),
                                        onPressed: () {
                                          templates.remove(formTarget);
                                          _saveAllTemplates(templates);
                                          adding = false;
                                          formTarget = null;
                                          setSheetState(() {});
                                        },
                                        child: const Text('删除'),
                                      ),
                                    const Spacer(),
                                    TextButton(
                                      style: TextButton.styleFrom(
                                        foregroundColor:
                                            scheme.onSurfaceVariant,
                                      ),
                                      onPressed: () {
                                        adding = false;
                                        formTarget = null;
                                        setSheetState(() {});
                                      },
                                      child: const Text('取消'),
                                    ),
                                    const SizedBox(width: 8),
                                    Material(
                                      color: Colors.grey.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(12),
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(12),
                                        onTap: () {
                                          final name = nameCtrl.text.trim();
                                          final prompt = promptCtrl.text.trim();
                                          if (name.isEmpty || prompt.isEmpty) {
                                            return;
                                          }
                                          final t = PromptTemplate(
                                            name,
                                            '自定义模板',
                                            prompt,
                                          );
                                          if (formTarget != null) {
                                            final i = templates.indexOf(
                                              formTarget!,
                                            );
                                            if (i >= 0) templates[i] = t;
                                          } else {
                                            templates.add(t);
                                          }
                                          _saveAllTemplates(templates);
                                          adding = false;
                                          formTarget = null;
                                          setSheetState(() {});
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 10,
                                          ),
                                          child: Text(
                                            '保存',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w500,
                                                ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          )
                        // ── 列表层级 ──
                        : Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.auto_awesome,
                                      size: 18,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '提示词模板',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      icon: Icon(
                                        Icons.add,
                                        size: 18,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      tooltip: '添加模板',
                                      onPressed: () {
                                        openForm(null);
                                        setSheetState(() {});
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Expanded(
                                  child: templates.isEmpty
                                      ? Center(
                                          child: Text(
                                            '暂无模板',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color:
                                                      scheme.onSurfaceVariant,
                                                ),
                                          ),
                                        )
                                      : LayoutBuilder(
                                          builder: (context, c) {
                                            // 行高自适应：模板少时卡片撑满
                                            // 滚动区（无空隙），多时回到最小
                                            // 行高并滚动
                                            final cols = 2;
                                            final rows =
                                                (templates.length / cols)
                                                    .ceil();
                                            final cardW = (c.maxWidth - 8) / 2;
                                            final rowH =
                                                ((c.maxHeight -
                                                            (rows - 1) * 8) /
                                                        rows)
                                                    .clamp(80.0, 200.0);
                                            return GridView.builder(
                                              // 显式零 padding：默认 null 会
                                              // 套用 MediaQuery 顶部 padding
                                              // （状态栏高度），造成网格上方
                                              // 大片空隙
                                              padding: EdgeInsets.zero,
                                              gridDelegate:
                                                  SliverGridDelegateWithFixedCrossAxisCount(
                                                    crossAxisCount: cols,
                                                    mainAxisSpacing: 8,
                                                    crossAxisSpacing: 8,
                                                    childAspectRatio:
                                                        cardW / rowH,
                                                  ),
                                              itemCount: templates.length,
                                              itemBuilder: (context, i) {
                                                final t = templates[i];
                                                final acting = identical(
                                                  actionTarget,
                                                  t,
                                                );
                                                return Material(
                                                  color: acting
                                                      ? Colors.grey.withValues(
                                                          alpha: 0.18,
                                                        )
                                                      : Colors.grey.withValues(
                                                          alpha: 0.12,
                                                        ),
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  child: InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          14,
                                                        ),
                                                    onTap: () {
                                                      if (acting) {
                                                        actionTarget = null;
                                                        setSheetState(() {});
                                                      } else {
                                                        apply(t);
                                                      }
                                                    },
                                                    onLongPress: () {
                                                      actionTarget = acting
                                                          ? null
                                                          : t;
                                                      setSheetState(() {});
                                                    },
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.all(
                                                            10,
                                                          ),
                                                      child: acting
                                                          // 长按态：左编辑 / 右删除（仅图标居中）
                                                          ? Row(
                                                              children: [
                                                                Expanded(
                                                                  child: InkWell(
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          10,
                                                                        ),
                                                                    onTap: () {
                                                                      actionTarget =
                                                                          null;
                                                                      setSheetState(
                                                                        () {},
                                                                      );
                                                                      openForm(
                                                                        t,
                                                                      );
                                                                      setSheetState(
                                                                        () {},
                                                                      );
                                                                    },
                                                                    child: Container(
                                                                      padding: const EdgeInsets.symmetric(
                                                                        vertical:
                                                                            16,
                                                                      ),
                                                                      decoration: BoxDecoration(
                                                                        color: Colors
                                                                            .grey
                                                                            .withValues(
                                                                              alpha: 0.15,
                                                                            ),
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              10,
                                                                            ),
                                                                      ),
                                                                      child: Icon(
                                                                        Icons
                                                                            .edit_outlined,
                                                                        size:
                                                                            18,
                                                                        color: scheme
                                                                            .onSurfaceVariant,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                                const SizedBox(
                                                                  width: 8,
                                                                ),
                                                                Expanded(
                                                                  child: InkWell(
                                                                    borderRadius:
                                                                        BorderRadius.circular(
                                                                          10,
                                                                        ),
                                                                    onTap: () {
                                                                      templates
                                                                          .remove(
                                                                            t,
                                                                          );
                                                                      _saveAllTemplates(
                                                                        templates,
                                                                      );
                                                                      actionTarget =
                                                                          null;
                                                                      setSheetState(
                                                                        () {},
                                                                      );
                                                                    },
                                                                    child: Container(
                                                                      padding: const EdgeInsets.symmetric(
                                                                        vertical:
                                                                            16,
                                                                      ),
                                                                      decoration: BoxDecoration(
                                                                        color: Colors
                                                                            .red
                                                                            .withValues(
                                                                              alpha: 0.12,
                                                                            ),
                                                                        borderRadius:
                                                                            BorderRadius.circular(
                                                                              10,
                                                                            ),
                                                                      ),
                                                                      child: Icon(
                                                                        Icons
                                                                            .delete_outline,
                                                                        size:
                                                                            18,
                                                                        color: Colors
                                                                            .red
                                                                            .withValues(
                                                                              alpha: 0.8,
                                                                            ),
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ),
                                                              ],
                                                            )
                                                          // 普通态：名称 + 描述
                                                          : Column(
                                                              crossAxisAlignment:
                                                                  CrossAxisAlignment
                                                                      .start,
                                                              children: [
                                                                Text(
                                                                  t.name,
                                                                  maxLines: 1,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: Theme.of(context)
                                                                      .textTheme
                                                                      .bodyMedium
                                                                      ?.copyWith(
                                                                        fontWeight:
                                                                            FontWeight.w600,
                                                                      ),
                                                                ),
                                                                const SizedBox(
                                                                  height: 4,
                                                                ),
                                                                Text(
                                                                  t.description,
                                                                  maxLines: 2,
                                                                  overflow:
                                                                      TextOverflow
                                                                          .ellipsis,
                                                                  style: Theme.of(context)
                                                                      .textTheme
                                                                      .bodySmall
                                                                      ?.copyWith(
                                                                        color: scheme
                                                                            .onSurfaceVariant,
                                                                      ),
                                                                ),
                                                              ],
                                                            ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 流式结束：落库；新会话首轮回复完成后触发 AI 标题生成（llama.cpp）
  Future<void> _finishResponding(
    Conversation conv,
    Message assistantMsg,
  ) async {
    _streamSub = null;
    // 完全无内容（正文/思考/工具卡片全空）的助手消息：删除，不留空气泡
    // （模型空回答 / ReAct 最终轮无输出等场景）
    if (assistantMsg.content.trim().isEmpty &&
        (assistantMsg.thinking?.trim().isEmpty ?? true) &&
        (assistantMsg.toolCalls?.isEmpty ?? true)) {
      setState(() {
        conv.messages.remove(assistantMsg);
        _isResponding = false;
        conv.updatedAt = DateTime.now();
      });
      await _persist(conv);
      return;
    }
    setState(() {
      _isResponding = false;
      conv.updatedAt = DateTime.now();
    });
    // 无需滚动：贴底用户 offset 0 天然保持（底部向上生长），
    // 上翻用户由 correctForNewDimensions 顶部基准保持原位
    await _persist(conv);
    // 新会话首轮回复完成 → 用模型生成标题（llama.cpp generateTitleWithLLM）
    if (_titleGenConvId == conv.id) {
      final firstUser = _titleGenUser;
      _titleGenConvId = null;
      _titleGenUser = null;
      if (firstUser != null && assistantMsg.content.isNotEmpty) {
        _generateAiTitle(conv, firstUser, assistantMsg.content);
      }
    }
  }

  /// AI 生成会话标题（llama.cpp 风格）：独立短请求 + 清洗规则，过短回退首行
  Future<void> _generateAiTitle(
    Conversation conv,
    String userContent,
    String assistantContent,
  ) async {
    final llm = _buildLlm();
    if (llm == null) return;
    // AI 标题模型：通用设置指定优先，否则跟随当前对话模型
    final titleModel = _general.aiTitleModel.isEmpty
        ? _modelName
        : _general.aiTitleModel;
    // 自定义提示词（与默认值不同时才透传，避免无谓覆盖）
    final customPrompt =
        _general.aiTitlePrompt != GeneralSettings.kDefaultTitlePrompt
        ? _general.aiTitlePrompt
        : null;
    String title = await llm.generateTitle(
      userContent,
      assistantContent,
      model: titleModel,
      customPrompt: customPrompt,
    );
    // 清洗：去 Trim → 去 Title:/Subject:/Topic:/标题:/主题: 前缀 → 去首尾引号（llama.cpp）
    title = title
        .trim()
        .replaceFirst(
          RegExp(
            r'^(Title:|Subject:|Topic:|标题[:：]|主题[:：])\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'^"|"$'), '')
        .trim();
    // 过短（<3 字符）回退到首条消息首行
    if (title.length < 3) title = _titleFromFirstLine(userContent);
    if (title.isEmpty || !mounted || conv.title == title) return;
    setState(() => conv.title = title);
    await _persist(conv);
  }

  /// 流式出错：助手消息标红 + 落库
  Future<void> _onRespondError(
    Conversation conv,
    Message assistantMsg,
    Object e,
  ) async {
    _streamSub = null;
    if (!mounted) return;
    setState(() {
      _isResponding = false;
      assistantMsg
        ..content = '请求失败：$e'
        ..error = true;
    });
    await _persist(conv);
  }

  /// 停止流式（保留已收部分）。若停止时助手消息完全为空
  /// （还在思考/工具调用阶段，content 与 thinking 都没收到），删除该空气泡。
  /// ReAct 循环用 await-for 无法 cancel，置标志位由循环自行中断清理
  void _onStop() {
    _streamSub?.cancel();
    if (_isReactRunning) {
      _stopRequested = true;
      return;
    }
    final conv = _currentConversation;
    if (conv == null || conv.messages.isEmpty) {
      setState(() => _isResponding = false);
      return;
    }
    final last = conv.messages.last;
    final isEmpty =
        last.role == Role.assistant &&
        last.content.trim().isEmpty &&
        (last.thinking?.trim().isEmpty ?? true) &&
        (last.toolCalls?.isEmpty ?? true);
    if (isEmpty) {
      // 删除空助手消息，不留空气泡（工具调用阶段被截断的常见场景）
      setState(() {
        conv.messages.removeLast();
        _isResponding = false;
      });
      _persist(conv);
    } else {
      // 停止 = 输出未完成：标记截断，气泡下显示工具栏 + 可继续生成
      last.truncated = true;
      _finishResponding(conv, last);
    }
  }

  /// 历史条目内联重命名框（条目原地变输入框，无独立窗口）
  Widget _inlineRenameField(BuildContext context, Conversation c, int index) {
    final controller = TextEditingController(text: c.title);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.grey.withValues(alpha: 0.15),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.3),
                  ),
                ),
              ),
              onSubmitted: (_) => _saveRename(index, controller.text),
            ),
          ),
          const SizedBox(width: 4),
          // 取消
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _renamingIndex = null),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.close,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // 保存
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _saveRename(index, controller.text),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(
                Icons.check,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 保存内联重命名
  Future<void> _saveRename(int index, String text) async {
    final title = text.trim();
    if (title.isEmpty) return;
    final c = _visibleHistory[index];
    setState(() {
      c.title = title;
      _renamingIndex = null;
      _historyLongPressed = null;
    });
    await _store?.rename(c.id, title);
  }

  /// 锁定/解锁对话（锁定的对话不会被自动归档）
  void _toggleLock(Conversation c) {
    setState(() {
      c.locked = !c.locked;
      _historyLongPressed = null;
    });
    _store?.save(c);
  }

  /// 归档会话：从主列表移除，可在设置页恢复/永久删除
  Future<void> _archiveConversation(int index) async {
    final c = _visibleHistory[index];
    setState(() {
      c.archived = true;
      c.archivedAt = DateTime.now();
      _conversations.remove(c);
      _historyLongPressed = null;
      if (_currentId == c.id) _currentId = null; // 归档当前会话 → 回新对话
    });
    await _store?.save(c);
  }

  /// 批量操作条按钮（实底卡片，不透明可见）
  Widget _batchBarButton({
    required String label,
    required VoidCallback? onPressed,
  }) {
    return Material(
      color: Colors.grey.withValues(alpha: 0.3),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurface,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// 批量归档：选中的会话全部归档
  Future<void> _batchArchive() async {
    final targets = _conversations
        .where((c) => _batchSelected.contains(c.id))
        .toList();
    setState(() {
      for (final c in targets) {
        c.archived = true;
        c.archivedAt = DateTime.now();
      }
      _conversations.removeWhere((c) => _batchSelected.contains(c.id));
      _batchSelected.clear();
      _batchMode = false;
      if (_currentId != null &&
          !_conversations.any((c) => c.id == _currentId)) {
        _currentId = null;
      }
    });
    for (final c in targets) {
      await _store?.save(c);
    }
  }

  /// 批量永久删除（带确认）
  /// 打开设置页（抽屉底部"设置"按钮 = 列表；长按页眉模型按钮/搜索开关 = 直达子页）
  void _openSettings({SettingsSection section = SettingsSection.main}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsPage(
          initialSection: section,
          providers: _providers,
          onProvidersChanged: (providers) {
            // 提供方/模型变更：立即生效（模型下拉/请求路由）+ 固化存档
            setState(() {
              _providers = List.of(providers);
              _rebuildModelIndex();
              // 当前模型被移除（提供方删除/模型删除）→ 回退到第一个模型
              if (_modelName.isNotEmpty && !_modelIndex.containsKey(_currentKey)) {
                if (_modelKeys.isEmpty) {
                  _currentProviderName = '';
                  _modelName = '';
                } else {
                  final f = _decodeModelKey(_modelKeys.first)!;
                  _currentProviderName = f.provider;
                  _modelName = f.id;
                  _store?.saveModelName(_encodeModelKey(f.provider, f.id));
                }
              }
            });
            _store?.saveProviders(providers);
          },
          replaceRules: _replaceRules,
          onReplaceRulesChanged: (rules) {
            // 文字替换规则变更：原地更新同一列表（设置页持有的引用同步生效，
            // 无需退出重进）+ 固化存档
            setState(() {
              _replaceRules
                ..clear()
                ..addAll(rules);
            });
            _store?.saveReplaceRules(rules);
          },
          mcpServers: _mcpServers,
          onMcpServersChanged: (servers) {
            // MCP 服务器变更：立即生效 + 固化存档
            setState(() {
              _mcpServers = List.of(servers);
              // 清理已删除服务器的客户端连接
              _mcpClients.removeWhere(
                (id, _) => !servers.any((s) => s.id == id),
              );
            });
            _store?.saveMcpServers(servers);
          },
          generalSettings: _general,
          onGeneralSettingsChanged: (s) {
            // 通用设置变更：立即生效 + 固化存档
            setState(() => _general = s);
            _store?.saveGeneralSettings(s);
          },
          availableModels: _models,
          // 归档对话管理改动后：重载会话列表
          onArchivedChanged: _onArchivedChanged,
          // 归档会话列表 + 存储（设置页归档管理零延迟进入，
          // 与其他设置子页一致：数据构造时传入，滑入即有内容）
          archived: _archivedConversations,
          store: _store,
        ),
      ),
    );
  }

  /// 当前模型显示文本：优先显示名（设置页配置），否则模型 ID（重名加前缀）
  String get _modelLabel {
    if (_modelName.isEmpty) return '未选模型';
    return _labelForKey(_currentKey);
  }

  /// 下拉栏显示的模型：复合键列表，过滤掉当前已选
  List<String> get _visibleModels =>
      _modelKeys.where((m) => m != _currentKey).toList();

  /// 历史列表可见项：非归档 + 搜索标题过滤
  List<Conversation> get _visibleHistory {
    final q = _historyQuery.toLowerCase();
    return _conversations.where((c) {
      if (c.archived) return false;
      if (q.isEmpty) return true;
      return c.title.toLowerCase().contains(q);
    }).toList();
  }

  /// 可见历史项数（批量全选用）
  int get _visibleHistoryCount => _visibleHistory.length;

  /// 下拉栏模型显示文本：与页眉一致（复合键 → 标签）
  String _modelDisplayText(String key) => _labelForKey(key);

  /// 已选附件（图片/文件）
  final List<_Attachment> _attachments = [];

  /// 输入栏容器顶边位置（附件条绑定其上，由输入栏实时上报）
  final ValueNotifier<double> _inputBarTop = ValueNotifier(64);

  /// CustomScrollView center 锚点 key（消息列表顶部锚定）
  final GlobalKey _listCenterKey = GlobalKey();

  /// 选择图片（系统相册多选），完成后关闭加号面板
  Future<void> _pickImages() async {
    final files = await ImagePicker().pickMultiImage();
    if (!mounted) return;
    if (files.isNotEmpty) {
      setState(() {
        _attachments.addAll(
          files.map(
            (f) => _Attachment(isImage: true, name: f.name, path: f.path),
          ),
        );
      });
    }
    Navigator.of(context).pop(); // 关闭加号面板
  }

  /// 选择文件（系统文件多选）。选择完成后**不关闭加号面板**
  /// （可连续添加多个附件；用户手动下拉/点遮罩关闭）。
  /// 图片扩展名自动识别为图片（isImage）——即使走文件入口，
  /// 图片也按多模态发送
  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (!mounted) return;
    if (result != null) {
      setState(() {
        _attachments.addAll(
          result.files.map(
            (f) => _Attachment(
              isImage: isImageFileName(f.name),
              name: f.name,
              path: f.path,
              size: f.size,
            ),
          ),
        );
      });
    }
  }

  /// 粘贴长文本转文件：写入系统临时目录的 .txt，加入附件条。
  /// 由 _GlassInputBar 的粘贴检测回调（单次增量超阈值触发）
  Future<void> _onPasteAsFile(String text) async {
    if (text.isEmpty) return;
    final ts = DateTime.now();
    final pad = (int n) => n.toString().padLeft(2, '0');
    final name =
        'pasted_${ts.year}${pad(ts.month)}${pad(ts.day)}_${pad(ts.hour)}${pad(ts.minute)}${pad(ts.second)}.txt';
    try {
      final dir = Directory.systemTemp;
      final file = File('${dir.path}/$name');
      await file.writeAsString(text);
      final length = await file.length();
      if (!mounted) return;
      setState(() {
        _attachments.add(
          _Attachment(
            isImage: false,
            name: name,
            path: file.path,
            size: length,
          ),
        );
      });
    } catch (e) {
      if (!mounted) return;
      _toast('转文件失败：$e');
    }
  }

  /// 当前对话的 MCP 配置：null = 跟随全局；非 null = 自定义启用的服务器 id
  /// （新对话未发送时读暂存）
  List<String>? get _currentMcpIds =>
      _currentConversation?.mcpServerIds ?? _pendingMcpIds;

  /// 当前模型（按复合身份从索引定位）
  ProviderModel? get _currentModel {
    final key = _currentKey;
    if (key.isEmpty) return null;
    final p = _modelIndex[key];
    if (p == null) return null;
    for (final m in p.models) {
      if (m.id == _modelName) return m;
    }
    return null;
  }

  /// 当前模型能力（有无两种情况；无当前模型/未设置按默认：
  /// 多模态不支持、工具/思考支持）
  bool get _modelSupportsMultimodal =>
      _currentModel?.supportsMultimodal ?? false;
  bool get _modelSupportsTools => _currentModel?.supportsTools ?? true;
  bool get _modelSupportsThinking => _currentModel?.supportsThinking ?? true;

  /// 更新当前对话的 MCP 配置（有会话 → 写入并持久化；无会话 → 暂存）
  void _setCurrentMcpIds(List<String>? ids) {
    final conv = _currentConversation;
    if (conv != null) {
      setState(() => conv.mcpServerIds = ids);
      _persist(conv);
    } else {
      setState(() => _pendingMcpIds = ids);
    }
  }

  /// 加号面板"MCP"：当前对话的 MCP 工具管理弹窗。
  /// 模式：跟随全局设置（默认）或自定义本对话（勾选要启用的服务器）
  void _openMcpManager() {
    // 当前配置：null = 跟随全局；空列表 = 禁用 MCP；非空 = 自定义启用
    final current = _currentMcpIds;
    var mode = current == null ? 0 : (current.isEmpty ? 1 : 2);
    // 自定义勾选：有配置用配置，否则用全局启用的服务器（无缝过渡）
    var selected = <String>{
      if (current != null)
        ...current
      else
        for (final s in _mcpServers.where((x) => x.enabled)) s.id,
    };
    // 自定义勾选列表展开状态（默认收起，规则同 AI 生成对话标题）
    var expanded = false;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? kSheetBgDark
          : Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Row(
                children: [
                  Icon(
                    Icons.hub_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'MCP 工具（当前对话）',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 模式：跟随全局 / 禁用 MCP / 自定义启用
              _mcpModeTile(
                context,
                selected: mode == 0,
                title: '跟随全局',
                subtitle: _globalEnabledSummary(),
                onTap: () {
                  setSheetState(() {
                    mode = 0;
                    selected = {
                      for (final s in _mcpServers.where((x) => x.enabled)) s.id,
                    };
                  });
                  _setCurrentMcpIds(null);
                },
              ),
              const SizedBox(height: 8),
              _mcpModeTile(
                context,
                selected: mode == 1,
                title: '禁用 MCP',
                subtitle: '本对话不启用任何 MCP 工具',
                onTap: () {
                  setSheetState(() => mode = 1);
                  _setCurrentMcpIds([]);
                },
              ),
              const SizedBox(height: 8),
              // 自定义启用：右侧 2/5 热区展开/收起勾选列表（同 AI 生成标题规则）
              _mcpModeTile(
                context,
                selected: mode == 2,
                title: '自定义启用',
                subtitle: mode == 2
                    ? '已选 ${selected.length} 台'
                    : '手动勾选本对话启用的服务器',
                trailing: Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                onTapUp: (d, width) {
                  if (d.localPosition.dx > width * 0.6) {
                    setSheetState(() => expanded = !expanded);
                  } else {
                    setSheetState(() => mode = 2);
                    _setCurrentMcpIds(selected.toList());
                  }
                },
              ),
              const SizedBox(height: 12),
              // 服务器列表（自定义启用且展开时显示，带过渡动画）
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 220),
                sizeCurve: Curves.easeOutCubic,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Column(
                  children: [
                    if (_mcpServers.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Center(
                          child: Text(
                            '未配置 MCP 服务器\n请到设置 → MCP 服务器 添加',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                      )
                    else
                      for (final s in _mcpServers) ...[
                        _mcpServerRow(
                          context,
                          server: s,
                          checked: selected.contains(s.id),
                          onToggle: (v) {
                            setSheetState(() {
                              if (v) {
                                selected.add(s.id);
                              } else {
                                selected.remove(s.id);
                              }
                            });
                            _setCurrentMcpIds(selected.toList());
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                  ],
                ),
                crossFadeState: mode == 2 && expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 全局启用摘要（跟随全局模式的副标题）
  String _globalEnabledSummary() {
    final enabled = _mcpServers.where((x) => x.enabled).length;
    return enabled == 0 ? '未启用任何服务器' : '启用全部 $enabled 台已启用的服务器';
  }

  /// MCP 模式单选行（灰白体系，无主题蓝紫）。[trailing] 行尾箭头（仅视觉）；
  /// [onTapUp] 提供时按点击位置分发（自定义行：右侧热区展开/收起）
  Widget _mcpModeTile(
    BuildContext context, {
    required bool selected,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
    void Function(TapUpDetails d, double width)? onTapUp,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.onSurface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Material(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : Colors.grey.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTapUp != null ? null : onTap,
            onTapUp: onTapUp == null ? null : (d) => onTapUp(d, width),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 20,
                    color: selected ? accent : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: selected ? accent : null,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 8), trailing],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// MCP 服务器勾选行（项目风格卡片 + Switch）
  Widget _mcpServerRow(
    BuildContext context, {
    required McpServer server,
    required bool checked,
    required ValueChanged<bool> onToggle,
  }) {
    return Material(
      color: Colors.grey.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onToggle(!checked),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.hub_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      server.name,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      server.isStdio ? 'stdio（本地进程）' : server.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 药丸型开关（与设置页统一）：浅灰/深灰底 + 细外框 + 圆钮
              Builder(
                builder: (context) {
                  final dark = Theme.of(context).brightness == Brightness.dark;
                  return Switch(
                    value: checked,
                    onChanged: onToggle,
                    activeThumbColor: dark
                        ? Colors.grey.shade300
                        : Colors.grey.shade800,
                    inactiveThumbColor: dark
                        ? Colors.grey.shade300
                        : Colors.grey.shade800,
                    trackColor: WidgetStatePropertyAll(
                      dark ? Colors.grey.shade700 : Colors.grey.shade300,
                    ),
                    trackOutlineColor: WidgetStatePropertyAll(
                      Colors.grey.shade500,
                    ),
                    trackOutlineWidth: const WidgetStatePropertyAll(1.0),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // 输入栏顶边高度变化（多行增高/收起）反映在列表 padding → 布局 →
    // ChatScrollPosition.correctForNewDimensions 统一处理（贴底/上翻补偿），
    // 无需额外监听器
    // 从系统获取屏幕圆角（Android 12+ getRoundedCorner）
    // 部分设备只对个别角返回值或返回 0：取四角最大值，0 时保留默认 28
    ScreenCornerRadius.get().then((r) {
      if (r != null && mounted) {
        final corners = [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight];
        final maxCorner = corners.fold(0.0, (a, b) => a > b ? a : b);
        if (maxCorner > 0) {
          setState(() => _screenCornerRadius = maxCorner);
        }
      }
    });
    // 加载历史会话（system 提示词随会话持久化）
    ChatStore.create().then((s) {
      if (!mounted) return;
      setState(() {
        _store = s;
        _conversations = s.loadAll().where((c) => !c.archived).toList();
        // 归档会话列表（设置页归档管理直接用，零延迟进入）
        _archivedConversations = s.loadAll().where((c) => c.archived).toList()
          ..sort(
            (a, b) => (b.archivedAt ?? b.updatedAt).compareTo(
              a.archivedAt ?? a.updatedAt,
            ),
          );
        // 思考深度固化到本地存档，启动时恢复
        _thinkingDepth = s.loadThinkingDepth();
        // 文字替换规则（设置页）启动时恢复
        _replaceRules = s.loadReplaceRules();
        // MCP 服务器列表（设置页）启动时恢复
        _mcpServers = s.loadMcpServers();
        // 模型提供方（设置页）启动时恢复；默认预置无模型 → 需手动获取
        _providers = s.loadProviders();
        // 重建索引：后续恢复当前模型与查询都依赖它
        _rebuildModelIndex();
        // 恢复最后使用的模型（软件重启不重置）：
        // v2 复合键直接解析；v1 老裸 id 按名回退补全归属并写回升级；
        // 已删除/不存在的模型回退到第一个
        final savedModel = s.loadModelName();
        ModelKey? resolved;
        if (savedModel.isNotEmpty) {
          final k = _decodeModelKey(savedModel);
          if (k != null &&
              _modelIndex.containsKey(_encodeModelKey(k.provider, k.id))) {
            resolved = k;
          } else {
            // v1 兼容：裸 id 匹配第一个命中的模型
            for (final key in _modelIndex.keys) {
              final d = _decodeModelKey(key);
              if (d != null && d.id == savedModel) {
                resolved = d;
                break;
              }
            }
            // 迁移写回（仅当旧值是裸 id 形式）
            if (resolved != null &&
                savedModel != _encodeModelKey(resolved.provider, resolved.id)) {
              _store?.saveModelName(
                _encodeModelKey(resolved.provider, resolved.id),
              );
            }
          }
        }
        if (resolved != null) {
          _currentProviderName = resolved.provider;
          _modelName = resolved.id;
        } else if (_modelKeys.isNotEmpty) {
          final f = _decodeModelKey(_modelKeys.first)!;
          _currentProviderName = f.provider;
          _modelName = f.id;
        } else {
          _currentProviderName = '';
          _modelName = '';
        }
        // 通用设置（粘贴/标题/渲染开关）启动时恢复
        _general = s.loadGeneralSettings();
      });
      // 自动归档/清理（启动时检查一次 + 每 6 小时周期检查）
      _maintainConversations();
      _maintainTimer?.cancel();
      _maintainTimer = Timer.periodic(
        const Duration(hours: 6),
        (_) => _maintainConversations(),
      );
    });
  }

  /// 自动归档 + 自动清理：
  /// - 非锁定、非归档且未活跃超过 autoArchiveDays 天 → 归档
  /// - 已归档且归档超过 autoDeleteDays 天 → 永久删除
  /// 天数 0 = 关闭对应步骤
  Future<void> _maintainConversations() async {
    final store = _store;
    if (store == null) return;
    final all = store.loadAll();
    final now = DateTime.now();
    final archiveDays = _general.autoArchiveDays;
    final deleteDays = _general.autoDeleteDays;
    var changed = false;
    for (final c in all) {
      if (!c.archived) {
        if (archiveDays > 0 &&
            !c.locked &&
            now.difference(c.updatedAt).inDays >= archiveDays) {
          c.archived = true;
          c.archivedAt = now;
          await store.save(c);
          changed = true;
        }
      } else {
        final at = c.archivedAt;
        if (deleteDays > 0 &&
            at != null &&
            now.difference(at).inDays >= deleteDays) {
          await store.delete(c.id);
          changed = true;
        }
      }
    }
    if (changed && mounted) {
      setState(() {
        _conversations = store.loadAll().where((c) => !c.archived).toList();
        if (_currentId != null &&
            !_conversations.any((c) => c.id == _currentId)) {
          _currentId = null;
        }
      });
    }
  }

  /// 设置页归档管理改动后：重载会话列表（恢复/删除归档对话）
  void _onArchivedChanged() {
    final store = _store;
    if (store == null) return;
    setState(() {
      _conversations = store.loadAll().where((c) => !c.archived).toList();
      _archivedConversations = store.loadAll().where((c) => c.archived).toList()
        ..sort(
          (a, b) => (b.archivedAt ?? b.updatedAt).compareTo(
            a.archivedAt ?? a.updatedAt,
          ),
        );
      if (_currentId != null &&
          !_conversations.any((c) => c.id == _currentId)) {
        _currentId = null;
      }
    });
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _maintainTimer?.cancel();
    _chatScroll.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    // 输入栏随键盘升起（主界面不动）
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    // 键盘/输入栏变化反映在列表 padding → 布局 →
    // ChatScrollPosition.correctForNewDimensions 统一处理（贴底/上翻补偿）

    // 滚动列表：死区 + 系统提示词卡片（仅在有提示词或编辑态显示，llama.cpp 同款）+ 消息
    final messages = _currentConversation?.messages ?? const <Message>[];
    final showSystem = (_prompt?.isNotEmpty ?? false) || _editingSystem;
    // 底部留白 = 输入栏顶边（实时高度）+ 键盘高度 + 手势条：
    // 输入栏增高时留白同步变大，最底气泡不会被遮盖。
    // 输入栏是悬浮在列表之上的玻璃层：列表视口全屏，
    // 内容滚动时从输入栏玻璃下滑过（半透明可见），即「悬浮感」。
    // CustomScrollView(center:) 锚定方案（gsy 聊天列表）：
    // center 锚点 = 消息列表顶部（offset 0 时锚点对齐视口顶 →
    // 内容少时天然顶部对齐）；上翻时 offset 保持 → 顶部锚定（文字不动）；
    // 贴底由 ChatScrollPosition 钉在新底部（底部生长）。
    // 消息正序：死区 → system 卡片 → 消息 1..N（最新在底部）
    final listView = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: CustomScrollView(
        controller: _chatScroll,
        center: _listCenterKey, // 锚点：消息列表顶部
        slivers: [
          // 锚点本身（零尺寸）
          SliverPadding(key: _listCenterKey, padding: EdgeInsets.zero),
          // 消息列表（从锚点向下：死区 → system → 消息 → 底部留白）
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              bottomPad + keyboardInset + _inputBarTop.value + 8,
            ),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                if (index == 0) {
                  // 死区（列表最顶部）：与背景色一致的块，避免页眉模糊污染
                  return Container(
                    height: _deadZoneHeight,
                    color: Theme.of(context).scaffoldBackgroundColor,
                  );
                }
                if (showSystem && index == 1) {
                  // 与消息一致的下间距：卡片底部与输入栏之间留出呼吸空间
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _systemCard(context),
                  );
                }
                final msgIndex = index - 1 - (showSystem ? 1 : 0);
                final m = messages[msgIndex];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _messageBubble(context, m, msgIndex),
                );
              }, childCount: 1 + (showSystem ? 1 : 0) + messages.length),
            ),
          ),
        ],
      ),
    );

    // 圆角恒定等于屏幕圆角（不从 0 渐变）
    final radius = _screenCornerRadius;

    // 主页面内容：列表 + 页眉 + 输入栏（始终可交互）。
    // 作为 AnimatedBuilder 的静态 child 复用：抽屉动画期间不重建，
    // 避免消息列表逐帧重排导致卡顿
    final mainContent = Stack(
      children: [
        // 列表 + 页眉（抽屉全开时由点击关闭遮罩锁定交互）
        Stack(
          children: [
            // ── 滚动列表：顶部避让状态栏，视口全屏（内容滚动时
            // 从悬浮输入栏玻璃下滑过，悬浮感）。
            // 点击列表/页面空白区域 → 取消输入栏聚焦（收起键盘）
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
              child: Padding(
                padding: EdgeInsets.only(top: topPad),
                child: listView,
              ),
            ),

            // 空状态提示：新对话（无消息、无 system 提示词）时居中显示。
            // 区域限定在页眉与输入栏之间，不响应点击
            if (messages.isEmpty && !showSystem)
              Positioned(
                top: topPad,
                left: 0,
                right: 0,
                bottom: bottomPad + keyboardInset + _inputBarTop.value + 8,
                child: IgnorePointer(
                  child: Center(
                    child: Text(
                      '新的对话从这开始',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                ),
              ),

            // ── 2. 页眉（独立 StatefulWidget：主页面刷新不影响页眉内部动画）──
            // key 在 Positioned 上：空状态提示出现/消失会改变 children
            // 顺序，无 key 时 Positioned 按 index 匹配会被误配，页眉
            // State 重建、动画中断——key 保证按身份匹配
            Positioned.fill(
              key: const ValueKey('headerSlot'),
              child: _ChatHeader(
                topPad: topPad,
                modelLabel: _modelLabel,
                visibleModels: _visibleModels,
                modelDisplay: _modelDisplayText,
                onModelSelected: (key) {
                  final k = _decodeModelKey(key);
                  if (k == null) return;
                  setState(() {
                    _currentProviderName = k.provider;
                    _modelName = k.id;
                  });
                  _store?.saveModelName(_encodeModelKey(k.provider, k.id));
                },
                onNewConversation: _newConversation,
                onOpenProvidersSettings: () =>
                    _openSettings(section: SettingsSection.providers),
              ),
            ),
          ],
        ),
        // ── 抽屉全开时：点击被收纳的主页面区域 → 关闭抽屉 ──
        // 位于输入栏之下（不挡输入栏）；仅此小块随动画帧重建
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _drawerController,
            builder: (context, _) => _drawerController.value > 0.95
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _drawerController.animateTo(
                      0,
                      curve: Curves.easeOutQuart,
                    ),
                    // 空白：仅用作命中区域，不绘制任何内容
                    child: const ColoredBox(color: Color(0x00000000)),
                  )
                : const SizedBox.shrink(),
          ),
        ),
        // ── 3. 底部：Liquid Glass 输入栏（始终可交互，不受抽屉锁定影响）──
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _GlassInputBar(
            onAddImage: _pickImages,
            onAddFile: _pickFiles,
            containerTopNotifier: _inputBarTop,
            isResponding: _isResponding,
            onSend: _onSend,
            onStop: _onStop,
            onEditPrompt: _editPrompt,
            // 聚焦时不再强制滚底：可见内容由 inset 补偿保持原位
            onFocusChanged: (_) {},
            // 加号面板"MCP"：当前对话的 MCP 工具管理
            onManageMcp: _openMcpManager,
            // 长按加号面板 MCP/内置按钮：直达对应设置页
            onLongPressMcp: () => _openSettings(section: SettingsSection.mcp),
            onLongPressBuiltin: () =>
                _openSettings(section: SettingsSection.general),
            // 内置工具开关（当前对话生效值 + 切换）
            builtinToolsOn: _builtinToolsEffective,
            onToggleBuiltinTools: _toggleBuiltinTools,
            // 粘贴长文本转文件（写入 _attachments）
            onPasteAsFile: _onPasteAsFile,
            pasteLongTextAsFile: _general.pasteLongTextAsFile,
            pasteThreshold: _general.pasteThreshold,
            thinkingDepth: _thinkingDepth,
            onThinkingDepthChanged: (depth) {
              // 面板滑动条与抽屉栏按钮共用同一状态：立即生效 + 持久化
              setState(() => _thinkingDepth = depth);
              _store?.saveThinkingDepth(depth);
            },
            modelSupportsMultimodal: _modelSupportsMultimodal,
            modelSupportsTools: _modelSupportsTools,
            modelSupportsThinking: _modelSupportsThinking,
            hasAttachments: _attachments.isNotEmpty,
          ),
        ),
      ],
    );

    return Scaffold(
      // 键盘弹出时主界面不整体上移（输入栏自行随键盘升起）
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // ── 抽屉页面（浅灰背景，被主页面盖住）──
          // RepaintBoundary：抽屉（历史对话列表）缓存为静态层，
          // 动画期间主页面右移露出时不逐帧重绘
          Positioned.fill(
            child: RepaintBoundary(child: _buildDrawer(topPad: topPad)),
          ),

          // ── 主页面：右滑 → 右移 + 缩小 + 圆角 + 变暗变模糊 ──
          // 动画期间仅重建受进度 t 影响的部分（变换/投影/变暗遮罩），
          // 消息列表等静态内容作为 child 复用，避免每帧重建导致卡顿
          AnimatedBuilder(
            animation: _drawerController,
            builder: (context, child) {
              final tt = _drawerController.value;
              final shift = tt * _drawerShift;
              // 不缩放：只平移（避免大纹理每帧重采样开销 + 视觉更简洁）
              return Transform.translate(
                offset: Offset(shift, 0),
                // 主页面底部投影（悬浮感）：参数固定（不随动画进度变化）——
                // 若 alpha 变化，blurRadius 24 的模糊每帧重算导致卡顿
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.3),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: Stack(
                      children: [
                        // 主页面不透明底（缩放/圆角时不透出下层抽屉内容）
                        Container(
                          color: Theme.of(context).scaffoldBackgroundColor,
                        ),
                        child!,
                        // 半透明变暗遮罩（随进度渐变，无模糊）
                        IgnorePointer(
                          child: Container(
                            color: Colors.black.withValues(alpha: tt * 0.35),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
            // RepaintBoundary：主页面（消息列表/玻璃模糊/输入栏）缓存为
            // 静态纹理层——抽屉动画期间 Transform 直接操作缓存层，
            // 不逐帧重绘内部（消息多时避免每帧绘制大量气泡与模糊导致卡顿）
            child: RepaintBoundary(
              child: Stack(
                children: [
                  // 主内容：列表/页眉/输入栏（静态，动画期间复用）
                  mainContent,
                  // 附件条：主界面内（随 Transform 移动），
                  // 位置绑定输入栏容器顶边；被变暗遮罩覆盖
                  ValueListenableBuilder<double>(
                    valueListenable: _inputBarTop,
                    builder: (context, top, _) {
                      if (_attachments.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Positioned(
                        left: 0,
                        right: 0,
                        bottom: bottomPad + keyboardInset + 8 + top,
                        height: 84,
                        child: _AttachmentBar(
                          attachments: _attachments,
                          onDelete: (i) =>
                              setState(() => _attachments.removeAt(i)),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          // ── 全局手势层：右滑打开 / 左滑关闭 ──
          // 有附件时底部 160px 让给附件条+输入栏（其横向滚动不被抽屉手势抢占）；
          // 无附件时恢复全屏右滑权限
          // translucent：只接收水平拖拽，点击/滚动穿透到下层
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            bottom: _attachments.isEmpty ? 0 : 160,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (d) {
                _dragStart = d.localPosition;
                _drawerController.stop();
              },
              onHorizontalDragUpdate: (d) {
                // 滑动角度阈值：累计方向与水平夹角 > 30° 时忽略
                //（斜向滑动不触发抽屉，避免误触）
                final start = _dragStart;
                if (start != null) {
                  final offset = d.localPosition - start;
                  final angleRatio =
                      offset.dy.abs() /
                      offset.dx.abs().clamp(1.0, double.infinity);
                  if (angleRatio > _dragAngleThreshold) return;
                }
                // 拖动系数放大：更跟手
                _drawerController.value =
                    (_drawerController.value +
                            d.delta.dx / (_drawerShift * 0.8))
                        .clamp(0.0, 1.0);
              },
              onHorizontalDragEnd: (d) {
                final start = _dragStart;
                _dragStart = null;
                // 角度死区：斜向拖动不触发开合，但仍收敛到就近端点
                if (start != null) {
                  final offset = d.localPosition - start;
                  final angleRatio =
                      offset.dy.abs() /
                      offset.dx.abs().clamp(1.0, double.infinity);
                  if (angleRatio > _dragAngleThreshold) {
                    _settleDrawer();
                    return;
                  }
                }
                final v = d.primaryVelocity ?? 0;
                if (v < 0) {
                  // 左滑退出：轻扫（速度 < -300）或滑到 70% 以下即关闭
                  _drawerController.animateTo(
                    (v < -300 || _drawerController.value < 0.7) ? 0.0 : 1.0,
                    curve: Curves.easeOutQuart,
                  );
                } else {
                  // 右滑打开：轻扫（速度 > 300）或超过 30% 即打开
                  _drawerController.animateTo(
                    (v > 300 || _drawerController.value > 0.3) ? 1.0 : 0.0,
                    curve: Curves.easeOutQuart,
                  );
                }
              },
              // 手势被抢占/系统取消（如拖动中列表滚动获胜、来电等）：
              // 收敛到就近端点，避免抽屉停在中间
              onHorizontalDragCancel: () {
                _dragStart = null;
                _settleDrawer();
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 抽屉收敛（所有手势结束路径统一走这里）：动画到就近端点，
  /// 并留一道帧后自检——若动画意外中断仍未到端点，再次收敛
  void _settleDrawer() {
    _drawerController.animateTo(
      _drawerController.value >= 0.5 ? 1.0 : 0.0,
      curve: Curves.easeOutQuart,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 新拖动进行中或动画仍在跑：不干预
      if (!mounted || _dragStart != null || _drawerController.isAnimating) {
        return;
      }
      final v = _drawerController.value;
      if (v > 0.001 && v < 0.999) {
        _drawerController.animateTo(
          v >= 0.5 ? 1.0 : 0.0,
          curve: Curves.easeOutQuart,
        );
      }
    });
  }

  /// 系统提示词卡片（llama-ui 风格：虚线卡片 + 操作按钮 + 内联编辑）
  Widget _systemCard(BuildContext context) {
    final text = _prompt ?? '';
    // 内联编辑态：textarea + Cancel/Save
    if (_editingSystem) {
      final ctrl = TextEditingController(text: text);
      return Align(
        alignment: Alignment.centerRight, // System 卡片靠右
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.25),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'System 提示词',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  minLines: 3,
                  // 行数上限：超过后字段内部滚动（isDense 已移除，滚动不再截断文字）
                  maxLines: 8,
                  // 显式文字样式：深色模式下亮字
                  style: Theme.of(context).textTheme.bodyMedium,
                  // 文本对齐顶部：多行内容不被紧凑装饰压切
                  textAlignVertical: TextAlignVertical.top,
                  decoration: InputDecoration(
                    filled: true,
                    // 深色模式：暗底（避免白底 + 亮字不可见）
                    fillColor: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.white.withValues(alpha: 0.6),
                    // 垂直 padding 归零：滚动内容裁切与背景框边缘完全重合
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 0,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant, // 灰色，非主题蓝
                      ),
                      onPressed: () => setState(() => _editingSystem = false),
                      icon: const Icon(Icons.close, size: 16),
                      label: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    Material(
                      color: Colors.grey.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _saveSystemPrompt(ctrl.text),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.check, size: 16),
                              const SizedBox(width: 8),
                              Text(
                                '保存',
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w500),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    // 常态：虚线风格卡片（文本 + 操作按钮）
    return Align(
      alignment: Alignment.centerRight, // System 卡片靠右
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.2),
              width: 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'System',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              // 提示词内容：最大行数限制（8 行 ≈ 176px），超出部分在卡片内滚动
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 176),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
              // 操作按钮：复制 / 编辑 / 删除
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _messageAction(
                      context,
                      icon: Icons.copy_outlined,
                      tooltip: '复制',
                      onTap: () => _copySystemPrompt(),
                    ),
                    _messageAction(
                      context,
                      icon: Icons.edit_outlined,
                      tooltip: '编辑',
                      onTap: () => setState(() => _editingSystem = true),
                    ),
                    _messageAction(
                      context,
                      icon: Icons.delete_outline,
                      tooltip: '删除',
                      // 颜色与其他按钮相同，按下才浅红（与消息气泡一致）
                      pressedColor: Colors.red.withValues(alpha: 0.18),
                      onTap: () => _deleteSystemPrompt(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 复制系统提示词
  Future<void> _copySystemPrompt() async {
    final text = _prompt ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 保存系统提示词（会话级，内联编辑保存）
  Future<void> _saveSystemPrompt(String text) async {
    final conv = _currentConversation;
    if (conv == null) return;
    final prompt = text.trim();
    setState(() {
      conv.systemPrompt = prompt.isEmpty ? null : prompt;
      _editingSystem = false;
    });
    await _persist(conv);
  }

  /// 删除系统提示词（清空当前会话的）
  Future<void> _deleteSystemPrompt() async {
    final conv = _currentConversation;
    if (conv == null) return;
    setState(() {
      conv.systemPrompt = null;
      _editingSystem = false;
    });
    await _persist(conv);
  }

  /// 消息气泡（llama.cpp 风格：user 靠右、assistant 靠左，思考与回复分割）
  Widget _messageBubble(BuildContext context, Message m, int index) {
    final isUser = m.role == Role.user;
    final align = isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    // 是否有正式内容（正文/图片/文件；思考在气泡外独立显示）。
    // 无内容仅工具调用记录时，不渲染气泡本体，只显示工具分割块
    final hasBubbleContent =
        m.content.isNotEmpty ||
        (m.imageParts?.isNotEmpty ?? false) ||
        (m.fileParts?.isNotEmpty ?? false);
    // 正在流式接收的气泡（响应中 + 会话最后一条助手消息）：
    // 内容为空时显示打字点；其余已完成请求的中间轮气泡不显示占位
    final conv = _currentConversation;
    final isStreamingTarget =
        _isResponding && !isUser && conv != null && conv.messages.last == m;
    // 分支导航数据源：本消息自己的分支优先；工具轮次的分支挂在轮首
    // 工具轮气泡上，而工具轮不显示工具栏，所以在同轮次内向前找最近的
    // 带分支消息（工具轮锚点），把分支导航显示在轮次末尾的最终回答
    // 气泡上（轮次结束于模型不再输出工具调用时）
    Message? navOwner;
    var navOwnerIndex = index;
    if (!isUser && (m.branches?.length ?? 0) <= 1 && conv != null) {
      for (
        var j = index - 1;
        j >= 0 && conv.messages[j].role != Role.user;
        j--
      ) {
        final a = conv.messages[j];
        if (a.role == Role.assistant && (a.branches?.length ?? 0) > 1) {
          navOwner = a;
          navOwnerIndex = j;
          break;
        }
      }
    }
    final hasOwnNav = (m.branches?.length ?? 0) > 1;
    final navTotal = hasOwnNav
        ? m.branches!.length
        : (navOwner?.branches?.length ?? 0);
    final navPos = hasOwnNav ? m.viewPos : (navOwner?.viewPos ?? 0);
    // 内联编辑模式（llama-ui 风格：原地变 textarea + Cancel/Save）
    if (_editingIndex == index) {
      return _InlineMessageEditor(
        message: m,
        index: index,
        isUser: isUser,
        replaceRules: _replaceRules,
        branchMode: _branchIndex == index,
        onCancel: _cancelEditing,
        onSave: _saveEditedMessage,
        onBranch: _branchMessage,
        onPickAttachments: _pickEditAttachments,
      );
    }
    return RepaintBoundary(
      // 流式期间正在更新的气泡频繁重绘；RepaintBoundary 隔离各气泡，
      // 静态气泡不随之重绘（整列表只有一个脏区域）
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.82,
          ),
          child: Column(
            crossAxisAlignment: align,
            children: [
              // 思考过程区（仅 assistant 且有 thinking 时显示，折叠/展开）。
              // 思考深度关闭（0）时隐藏思考块——切换思考模式的实际可见效果；
              // 例外：输出被截断/停止时显示（未完成的过程需可见）
              // 文字替换：显示层应用规则（模型文本 → 显示文本）
              if (!isUser &&
                  (_thinkingDepth > 0 || m.truncated) &&
                  (m.displayThinking?.isNotEmpty ?? false))
                _thinkingBlock(context, _displayCached(m.displayThinking!)),
              // 气泡本体（无阴影；助手灰色、用户品牌蓝）。
              // 无正式内容（仅工具调用）时不渲染；正在流式接收（打字点）除外
              if (hasBubbleContent || isStreamingTarget)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isUser
                        ? kBrandColorLight
                        : (m.error
                              ? Colors.red.withValues(alpha: 0.1)
                              : Theme.of(context).brightness == Brightness.dark
                              ? Colors.white.withValues(alpha: 0.10)
                              : Colors.grey.withValues(alpha: 0.20)),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                  ),
                  child: Column(
                    // 气泡内容直接渲染（无 AnimatedSize——内容渐变增高会与
                    // 滚动跟随时序错位导致底部闪烁；闪烁由滚动动画抵消）
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: isUser
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      // 文件块（llama.cpp 风格）：文本附件以文件卡片显示。
                      // 删除入口在编辑模式（编辑时可增删文件），平时不显示删除键
                      if (m.fileParts != null && m.fileParts!.isNotEmpty)
                        ...m.fileParts!.map(
                          (f) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _fileBlock(context, f),
                          ),
                        ),
                      // 图片网格（多模态：用户发送的图片，撑满气泡宽度，
                      // 不受文字对齐影响——文字靠右但图片满宽）
                      if (m.imageParts != null && m.imageParts!.isNotEmpty)
                        SizedBox(
                          width: double.infinity,
                          child: _imageGrid(context, m.imageParts!),
                        ),
                      // 文本内容：正在流式接收且为空 → 打字点；否则渲染。
                      // 已完成请求的中间轮（content 空）不显示占位
                      m.content.isEmpty && isStreamingTarget
                          ? _typingDots(context)
                          : _general.markdownEnabled
                          ? MarkdownView(
                              // 文字替换：显示层应用规则（模型文本 → 显示文本），
                              // 再按 Markdown 渲染（代码高亮/表格/可点链接）
                              text: _displayCached(m.displayContent),
                              isUser: isUser,
                              latexEnabled: _general.latexEnabled,
                              mermaidEnabled: _general.mermaidEnabled,
                              artifactsEnabled: _general.artifactsEnabled,
                            )
                          : SelectableText(
                              _displayCached(m.displayContent),
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                    ],
                  ),
                ),
              // 工具调用分割块（Claude 风格）：独立于气泡的灰底卡片，
              // 位于工具调用轮气泡之后、下一轮气泡之前，作为 ReAct 轮次分割
              if (!isUser && m.toolCalls != null && m.toolCalls!.isNotEmpty)
                _toolCallDivider(context, m),
              // 消息操作按钮行（工具栏：分支导航 + 复制/编辑/重新生成/删除）。
              // 分支导航 < n/N > 在工具栏行首。工具栏显示规则：
              // 仅在没有任何工具调用的轮次显示——工具调用轮只保留
              // 工具卡片分割块，不产生工具栏（避免一轮出现两个工具栏）；
              // 例外：输出被截断时强制显示（含思考阶段截断——
              // 只有 thinking 没有正式内容也显示，截断后需可直接操作/继续）
              if ((hasBubbleContent || m.truncated) &&
                  (isUser ||
                      (m.toolCalls == null || m.toolCalls!.isEmpty) ||
                      m.truncated))
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 分支导航（llama.cpp 树状分支）：< n/N >，最新分支 = N/N，
                      // 左 = 上一个（旧分支），右 = 下一个（新分支）。
                      // 数据源见上方 navOwner/navTotal/navPos 计算：
                      // 工具轮次的分支导航显示在轮次末尾的最终回答气泡上
                      if (navTotal > 1) ...[
                        _messageAction(
                          context,
                          icon: Icons.chevron_left,
                          tooltip: '上一个分支',
                          onTap: navPos > 0
                              ? () => _switchBranch(navOwnerIndex, -1)
                              : null,
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Text(
                            '${navPos + 1}/$navTotal',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ),
                        _messageAction(
                          context,
                          icon: Icons.chevron_right,
                          tooltip: '下一个分支',
                          onTap: navPos < navTotal - 1
                              ? () => _switchBranch(navOwnerIndex, 1)
                              : null,
                        ),
                        const SizedBox(width: 4),
                      ],
                      _messageAction(
                        context,
                        icon: Icons.copy_outlined,
                        tooltip: '复制',
                        onTap: () => _copyMessage(m),
                      ),
                      _messageAction(
                        context,
                        icon: Icons.edit_outlined,
                        tooltip: '编辑',
                        onTap: () => setState(() {
                          _editingIndex = index;
                          _branchIndex = null; // 普通编辑会退出分支模式
                        }),
                      ),
                      // 用户消息可开启分支对话（确认后截断并重新生成）
                      if (isUser)
                        _messageAction(
                          context,
                          icon: Icons.call_split,
                          tooltip: '分支',
                          onTap: () => setState(() {
                            _branchIndex = index;
                            _editingIndex = index;
                          }),
                        ),
                      // 仅助手消息可重新生成
                      if (!isUser)
                        _messageAction(
                          context,
                          icon: Icons.refresh,
                          tooltip: '重新生成',
                          onTap: () => _regenerate(index),
                        ),
                      _messageAction(
                        context,
                        icon: Icons.delete_outline,
                        tooltip: '删除',
                        // 颜色与其他按钮相同，按下才浅红
                        pressedColor: Colors.red.withValues(alpha: 0.18),
                        onTap: () => _deleteMessage(index),
                      ),
                      // 输出气泡工具栏最右边：上下文占用圆环
                      if (!isUser) ...[
                        const SizedBox(width: 8),
                        _contextRing(context),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 编辑消息时添加附件（同 llama-ui）：
  /// 图片 → 图片部件（imageParts）；文本 → 文件部件（fileParts）
  Future<void> _pickEditAttachments(
    void Function(VoidCallback fn) setEditorState,
    List<MessageFilePart> editFiles,
    List<ImagePart> editImages,
  ) async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null) return;
    for (final f in result.files) {
      final att = _Attachment(
        isImage: false,
        name: f.name,
        path: f.path,
        size: f.size,
      );
      // 图片：读取字节为多模态部件
      if (isImageFileName(att.name)) {
        try {
          final bytes = await att.readBytes();
          if (bytes.isNotEmpty) {
            final mime = _mimeFromName(att.name);
            setEditorState(
              () => editImages.add(
                ImagePart(
                  name: att.name,
                  mimeType: mime,
                  dataUrl: 'data:$mime;base64,${base64Encode(bytes)}',
                ),
              ),
            );
          }
        } catch (_) {}
        continue;
      }
      // 文本附件：读取内容加入文件部件
      if (!isTextAttachmentName(att.name)) continue;
      try {
        final (content, truncated) = await att.readText();
        if (content.trim().isNotEmpty) {
          setEditorState(
            () => editFiles.add(
              MessageFilePart(
                name: att.name,
                size: att.size ?? 0,
                content: content,
                truncated: truncated,
              ),
            ),
          );
        }
      } catch (_) {}
    }
  }

  /// 落库前同步各消息「当前分支」的锚点快照与后续链（分支尾随实际消息列表），
  /// 再写入本地存储。所有会话级改动统一走这里
  Future<void> _persist(Conversation conv) async {
    for (var i = 0; i < conv.messages.length; i++) {
      final m = conv.messages[i];
      final b = m.branches;
      if (b != null && b.isNotEmpty) {
        final live = b[m.viewPos.clamp(0, b.length - 1)];
        live.anchor = _snapshot(m);
        live.tail = conv.messages.sublist(i + 1);
      }
    }
    try {
      await _store?.save(conv);
    } catch (_) {
      // 存储失败（web localStorage 超限/磁盘满，含原图 base64 大消息）：
      // 提示但不崩溃
      _toast('存储空间不足，消息未能保存');
    }
  }

  /// 消息快照（分支锚点用）：复制内容/思考/错误/历史版本/图片/文件/工具记录，
  /// 不含分支与视图位
  Message _snapshot(Message m) =>
      Message(
          role: m.role,
          content: m.content,
          thinking: m.thinking,
          ts: m.ts,
          error: m.error,
        )
        ..versions = m.versions == null ? null : [...m.versions!]
        ..imageParts = m.imageParts == null ? null : [...m.imageParts!]
        ..fileParts = m.fileParts == null ? null : [...m.fileParts!]
        ..toolCalls = m.toolCalls == null ? null : [...m.toolCalls!];

  /// 保存内联编辑：仅更新内容与思考，保留后续消息
  /// （不触发重新生成——只有按"重新生成"按钮才重新生成，与 llama.cpp 一致）
  /// [fileParts] / [imageParts] 编辑后的附件（用户消息写回）
  Future<void> _saveEditedMessage(
    int index,
    TextEditingController contentCtrl,
    TextEditingController thinkingCtrl, {
    List<MessageFilePart>? fileParts,
    List<ImagePart>? imageParts,
  }) async {
    final conv = _currentConversation;
    if (conv == null) return;
    final msg = conv.messages[index];
    // 保存为模型文本（模型收到的仍是替换前文本）。
    // 用户消息允许文字为空（仅附件场景：删光文字/只保留附件）
    final newText = applyModelRules(contentCtrl.text.trim(), _replaceRules);
    if (newText.isEmpty && msg.role != Role.user) return;
    setState(() {
      msg.content = newText;
      if (msg.role == Role.assistant) {
        final t = applyModelRules(thinkingCtrl.text.trim(), _replaceRules);
        msg.thinking = t.isEmpty ? null : t;
        msg.viewPos = 0; // 编辑后回到最新版本视图
      }
      // 用户消息：写回编辑后的附件（含增删）
      if (msg.role == Role.user) {
        if (fileParts != null) {
          msg.fileParts = fileParts.isEmpty ? null : fileParts;
        }
        if (imageParts != null) {
          msg.imageParts = imageParts.isEmpty ? null : imageParts;
        }
      }
      msg.error = false;
      _editingIndex = null;
    });
    await _persist(conv);
  }

  /// 退出内联编辑/分支编辑（Cancel 按钮）
  void _cancelEditing() {
    setState(() {
      _editingIndex = null;
      _branchIndex = null;
    });
  }

  /// 分支对话（用户消息，llama.cpp 树状分支）：修改内容 → 截断其后消息 →
  /// 重新生成。旧状态（内容快照 + 后续链）保留为历史分支，新状态成为最新分支。
  /// 分支始终挂在用户消息上（分支对话分叉的是用户提问本身）；
  /// LLM 轮次的分支由「重新生成」按钮挂载（见 _regenerateFromUser）
  /// [fileParts] / [imageParts] 编辑后的附件（写回分支后的消息）
  void _branchMessage(
    int index,
    TextEditingController contentCtrl, {
    List<MessageFilePart>? fileParts,
    List<ImagePart>? imageParts,
  }) {
    final conv = _currentConversation;
    if (conv == null || _isResponding) return;
    final msg = conv.messages[index];
    // 分支内容存为模型文本（模型收到的仍是替换前文本）。
    // 用户消息允许文字为空（仅附件场景）
    final newText = applyModelRules(contentCtrl.text.trim(), _replaceRules);
    if (newText.isEmpty && msg.role != Role.user) return;
    // 旧状态（内容快照 + 后续链）必须在修改/截断前捕获
    final oldTail = conv.messages.sublist(index + 1);
    final oldSnapshot = _snapshot(msg);
    setState(() {
      msg
        ..content = newText
        ..error = false;
      // 写回编辑后的附件（含增删）
      if (fileParts != null) {
        msg.fileParts = fileParts.isEmpty ? null : fileParts;
      }
      if (imageParts != null) {
        msg.imageParts = imageParts.isEmpty ? null : imageParts;
      }
      // 列表 = 旧->新：[历史..., 旧状态, 新 live 槽位]
      //（旧列表末尾的 live 槽位 = 当前状态，由旧状态取代，先去掉）
      final oldList = msg.branches ?? [];
      final history = oldList.isEmpty
          ? <MessageBranch>[]
          : oldList.sublist(0, oldList.length - 1);
      msg.branches = [
        ...history,
        MessageBranch(oldSnapshot, oldTail),
        MessageBranch(_snapshot(msg), <Message>[]),
      ];
      msg.viewPos = msg.branches!.length - 1;
      _editingIndex = null;
      _branchIndex = null;
      // 截断该消息之后的内容（新分支的后续将由新回复填充）
      conv.messages.removeRange(index + 1, conv.messages.length);
    });
    _persist(conv);
    _generate(conv);
  }

  /// 重新生成助手回复（llama.cpp 树状分支）：
  /// 旧回复（含思考/版本）与其后的消息链保留为历史分支，新回复流式写入当前消息
  void _regenerate(int index) {
    final conv = _currentConversation;
    if (conv == null || _isResponding) return;
    // 工具轮次检测：被点的消息之前（含本身）存在带 toolCalls 的助手消息
    // → 从用户最后一次输入开始整段重新生成（重新执行 ReAct 工具流程，
    //   否则新请求缺少工具上下文，模型无法基于工具结果回答）
    final hasToolRound = conv.messages
        .sublist(0, index + 1)
        .any(
          (m) =>
              m.role == Role.assistant &&
              m.toolCalls != null &&
              m.toolCalls!.isNotEmpty,
        );
    if (hasToolRound) {
      var userIdx = -1;
      for (var i = index; i >= 0; i--) {
        if (conv.messages[i].role == Role.user) {
          userIdx = i;
          break;
        }
      }
      if (userIdx >= 0) {
        _regenerateFromUser(conv, userIdx);
        return;
      }
    }
    final msg = conv.messages[index];
    // 旧状态（内容快照 + 后续链）必须在清空前捕获
    final oldTail = conv.messages.sublist(index + 1);
    final oldSnapshot = _snapshot(msg);
    setState(() {
      msg
        ..content = ''
        ..thinking = null
        ..error = false
        // 清空上次的工具调用卡片记录（重新生成时旧记录不再保留）
        ..toolCalls = null;
      // 列表 = 旧->新：[历史..., 旧状态, 新 live 槽位]
      final oldList = msg.branches ?? [];
      final history = oldList.isEmpty
          ? <MessageBranch>[]
          : oldList.sublist(0, oldList.length - 1);
      msg.branches = [
        ...history,
        MessageBranch(oldSnapshot, oldTail),
        MessageBranch(_snapshot(msg), <Message>[]),
      ];
      msg.viewPos = msg.branches!.length - 1;
      // 截断该消息之后的旧内容
      conv.messages.removeRange(index + 1, conv.messages.length);
    });
    _persist(conv);
    _generate(conv);
  }

  /// 从用户消息重新生成（工具轮次场景）：截断该用户消息之后的所有内容
  /// （含工具调用轮与后续回答），整段旧链作为分支保存到用户消息，
  /// 然后重新走完整生成流程（含 ReAct 工具调用）
  void _regenerateFromUser(Conversation conv, int userIdx) {
    // 分支挂在 LLM 输出上：找用户消息之后的第一条 assistant 消息
    // （工具调用轮的第一个气泡），而非用户消息本身
    var anchorIdx = -1;
    for (var i = userIdx + 1; i < conv.messages.length; i++) {
      if (conv.messages[i].role == Role.assistant) {
        anchorIdx = i;
        break;
      }
    }
    // 没有 assistant 输出（异常情况）：退化为只重生成用户消息后的内容
    if (anchorIdx < 0) return;
    final anchorMsg = conv.messages[anchorIdx];
    // 旧链（锚点之后的后续：最终回答轮等）作为分支 tail 保存
    final oldTail = conv.messages.sublist(anchorIdx + 1);
    final oldSnapshot = _snapshot(anchorMsg);
    setState(() {
      // 清空锚点内容：保留在列表中，复用为重新生成的第一轮气泡
      // （不能删除——branches 挂在这个消息对象上，删了分支就丢了）
      anchorMsg
        ..content = ''
        ..thinking = null
        ..error = false
        ..toolCalls = null;
      final oldList = anchorMsg.branches ?? [];
      final history = oldList.isEmpty
          ? <MessageBranch>[]
          : oldList.sublist(0, oldList.length - 1);
      anchorMsg.branches = [
        ...history,
        MessageBranch(oldSnapshot, oldTail),
        MessageBranch(_snapshot(anchorMsg), <Message>[]),
      ];
      anchorMsg.viewPos = anchorMsg.branches!.length - 1;
      // 截断：保留 [0..userIdx] + 锚点，删除其余（重新生成 = 从用户输入重新开始）
      conv.messages
        ..removeRange(userIdx + 1, conv.messages.length)
        ..insert(userIdx + 1, anchorMsg);
    });
    _persist(conv);
    _generate(conv);
  }

  /// 分支切换（llama.cpp 树状分支，用户/助手消息通用）：
  /// 保存当前分支（锚点快照 + 后续链），换入目标分支的内容与后续链。
  /// delta -1 = 上一个（旧分支），+1 = 下一个（新分支）
  void _switchBranch(int index, int delta) {
    final conv = _currentConversation;
    if (conv == null || _isResponding) return;
    final msg = conv.messages[index];
    final b = msg.branches;
    if (b == null || b.length < 2) return;
    final target = (msg.viewPos + delta).clamp(0, b.length - 1);
    if (target == msg.viewPos) return;
    // 当前显示分支写回（锚点快照 + 后续链）
    b[msg.viewPos]
      ..anchor = _snapshot(msg)
      ..tail = conv.messages.sublist(index + 1);
    final t = b[target];
    setState(() {
      msg
        ..content = t.anchor.content
        ..thinking = t.anchor.thinking
        ..error = t.anchor.error
        // 恢复工具调用记录（工具轮气泡分支切换时保留工具卡片）
        ..toolCalls = t.anchor.toolCalls == null
            ? null
            : [...t.anchor.toolCalls!]
        ..viewPos = target;
      // 换入目标分支的后续链
      conv.messages.removeRange(index + 1, conv.messages.length);
      conv.messages.addAll(t.tail);
      // 切换分支时退出该条上的编辑态，避免用旧文本覆盖新分支
      if (_editingIndex == index) _editingIndex = null;
      if (_branchIndex == index) _branchIndex = null;
    });
    _persist(conv);
  }

  /// 上下文占用圆环（输出气泡工具栏最右侧）：当前对话估算 token 与
  /// 当前模型上下文窗口之比；模型未设置上下文时按命名默认（ds 1M/其他 128k）。
  /// 默认只显示圆环；通用设置开启后百分比显示在圆环左侧
  Widget _contextRing(BuildContext context) {
    final total =
        _currentModel?.contextWindow ?? defaultContextWindowFor(_modelName);
    if (total <= 0) return const SizedBox.shrink();
    final used = _currentContextTokens;
    if (used <= 0) return const SizedBox.shrink();
    final ratio = (used / total).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    // 占用色：<70% 灰；70-90% 橙；>90% 红
    final color = ratio >= 0.9
        ? Colors.red.shade600
        : ratio >= 0.7
        ? Colors.orange.shade700
        : scheme.onSurfaceVariant;
    final ring = SizedBox(
      width: 16,
      height: 16,
      child: CustomPaint(
        painter: _ContextRingPainter(
          progress: ratio,
          color: color,
          trackColor: scheme.onSurfaceVariant.withValues(alpha: 0.15),
        ),
      ),
    );
    final tip = Tooltip(
      message: '上下文占用 ${formatTokenCount(used)} / ${formatTokenCount(total)}',
      child: ring,
    );
    if (!_general.contextPercent) return tip;
    // 百分比显示在圆环左侧
    return Tooltip(
      message: '上下文占用 ${formatTokenCount(used)} / ${formatTokenCount(total)}',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${(ratio * 100).round()}%',
            style: TextStyle(fontSize: 13, height: 1, color: color),
          ),
          const SizedBox(width: 12),
          ring,
        ],
      ),
    );
  }

  /// 上下文 token 缓存（API /tokenize 获取真实计数；失败/超时降级估算）
  int _contextTokens = 0;
  String _contextTokensKey = '';

  /// 估算值缓存：key 变化时同步算一次，流式期间每帧 build 直接命中
  ///（此前流式中 key 被短路、每次 build 都全量遍历消息估算）
  int _estTokens = 0;

  /// 当前对话 token 总数：优先 API tokenize（缓存 + 消息变化时异步刷新），
  /// 未获取到时先用估算值显示
  int get _currentContextTokens {
    final conv = _currentConversation;
    if (conv == null) return 0;
    final last = conv.messages.isEmpty ? null : conv.messages.last;
    final key = '${conv.id}:${conv.messages.length}:${last?.content.length}';
    // 响应中不刷新（内容逐帧变化，等流式结束后再取真实值）
    if (!_isResponding && key != _contextTokensKey) {
      _contextTokensKey = key;
      _contextTokens = 0; // 立即失效，先用估算显示
      _estTokens = _estimateContextTokens(conv);
      _refreshContextTokens(conv);
    }
    if (_contextTokens > 0) return _contextTokens;
    return _estTokens;
  }

  /// 文本中/英估算 + 图片每张约 1000（仅在 key 变化时调用一次）
  int _estimateContextTokens(Conversation conv) {
    var t = 0;
    for (final m in conv.messages) {
      t += estimateTokens(m.modelContent);
      t += estimateTokens(m.thinking ?? '');
      t += (m.imageParts?.length ?? 0) * 1000;
    }
    return t;
  }

  /// 异步获取真实 token 数（整个对话文本一次 /tokenize 请求）；
  /// 端点不可用则用估算结果
  Future<void> _refreshContextTokens(Conversation conv) async {
    final llm = _buildLlm();
    if (llm == null) return;
    final text = conv.messages
        .map((m) => '${m.modelContent}\n${m.thinking ?? ''}')
        .join('\n');
    final n = await llm.tokenize(text, model: _modelName);
    if (!mounted) return;
    final imgTokens = conv.messages.fold(
      0,
      (sum, m) => sum + (m.imageParts?.length ?? 0) * 1000,
    );
    setState(() {
      _contextTokens = (n ?? estimateTokens(text)) + imgTokens;
    });
  }

  Widget _messageAction(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    VoidCallback? onTap,
    Color? color,
    Color? pressedColor,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        // 按下反馈色（默认主题涟漪；删除按钮传浅红）
        highlightColor: pressedColor,
        splashColor: pressedColor,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 16,
            color: (color ?? Theme.of(context).colorScheme.onSurfaceVariant)
                .withValues(alpha: onTap == null ? 0.3 : 1),
          ),
        ),
      ),
    );
  }

  /// 文件块（llama.cpp 风格）：圆角卡片，左文件图标 + 右文件名/大小两行。
  /// 文本附件的展示形态（内容随消息发送，模型可阅读）
  /// 文件块（llama.cpp 风格）：圆角卡片，左文件图标 + 右文件名/大小两行。
  /// 删除入口在编辑模式（见 _inlineMessageEditor 文件管理区）
  Widget _fileBlock(BuildContext context, MessageFilePart f) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.description_outlined,
            size: 20,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                '${formatFileSize(f.size)}${f.truncated ? ' · 已截断' : ''}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 图片网格（用户消息里的多模态图片，原图 data URL 显示）
  /// 1 张满宽（限高避免过大），2 张并排，3+ 三列；点击任一张全屏查看。
  /// 用 MemoryImage 缓存解码结果 + cacheWidth 限制解码尺寸，
  /// 避免列表项重建/移入屏幕时重复解码闪烁
  Widget _imageGrid(BuildContext context, List<ImagePart> images) {
    final count = images.length;
    // 单图：限高显示（保持比例）；多图：正方形网格
    if (count == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: ConstrainedBox(
          // 单图最高 240，宽度满；BoxFit.cover 裁剪填充
          constraints: const BoxConstraints(maxHeight: 240),
          child: _cachedImageThumb(context, images.first),
        ),
      );
    }
    final crossCount = count == 2 ? 2 : 3;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossCount,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: 1, // 多图正方形
        ),
        itemCount: count,
        itemBuilder: (context, i) => _cachedImageThumb(context, images[i]),
      ),
    );
  }

  /// 单张图片缩略图（缓存 provider 复用 + ResizeImage 限宽解码，
  /// 避免重复加载闪烁与解码内存开销）
  Widget _cachedImageThumb(BuildContext context, ImagePart img) {
    return GestureDetector(
      onTap: () => _showImageFullscreen(context, img),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image(
          // 缩略图限宽 600 解码（内存与耗时大幅降低）
          image: ResizeImage.resizeIfNeeded(
            600,
            null,
            _imageProviderFor(img.dataUrl),
          ),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Container(
            color: Colors.black26,
            alignment: Alignment.center,
            child: const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
            ),
          ),
        ),
      ),
    );
  }

  /// 全屏查看图片：黑色背景 + 双指/双击缩放 + 点击关闭。
  /// 用 MaterialPageRoute（全屏不透明，无 barrier 遮罩层，避免遮罩问题）
  void _showImageFullscreen(BuildContext context, ImagePart img) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _ImageFullscreen(image: _imageProviderFor(img.dataUrl)),
      ),
    );
  }

  /// 图片实例缓存：同一 dataUrl 复用同一 MemoryImage。
  /// 列表项移出/移入屏幕重建时，ImageCache 按 provider 实例命中，
  /// 不再重复 base64 解码 + 图片解码（这是"每次加载"的根因）
  static final Map<String, MemoryImage> _imageCache = {};

  /// 从 data URL 取（或创建并缓存）图片 provider
  MemoryImage _imageProviderFor(String dataUrl) =>
      _imageCache.putIfAbsent(dataUrl, () {
        final comma = dataUrl.indexOf(',');
        final b64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
        return MemoryImage(base64Decode(b64));
      });

  /// MCP 工具调用分割块（Claude 风格）：独立于消息气泡的灰底卡片，
  /// 位于工具调用轮气泡之后、下一轮气泡之前，作为 ReAct 轮次的分割元素。
  /// 顶部标签行（「工具调用」+ 状态汇总），每个工具一行（名称 + 参数 + 状态）
  Widget _toolCallDivider(BuildContext context, Message m) {
    final tcs = m.toolCalls ?? const <ToolCallRecord>[];
    if (tcs.isEmpty) return const SizedBox.shrink();
    final grey = Colors.grey.shade700;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 状态汇总：任一工具仍在执行（resultCount == null）→ 调用中
    final running = tcs.any((t) => t.resultCount == null);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          // 独立底色（与气泡区分）：暗色更亮一档、亮色更暗一档
          color: dark ? const Color(0xFF262626) : const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标签行
            Row(
              children: [
                Icon(Icons.hub_outlined, size: 13, color: Colors.grey.shade700),
                const SizedBox(width: 4),
                Text(
                  '工具调用',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: grey,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (running)
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                      SizedBox(width: 4),
                    ],
                  ),
                Text(
                  running ? '调用中…' : '完成 ${tcs.length} 个工具',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: running ? grey : Colors.green.shade600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 每个工具一行
            for (final tc in tcs) _toolRow(context, tc),
          ],
        ),
      ),
    );
  }

  /// 工具调用单行：状态图标 + 名称/参数 + 结果
  Widget _toolRow(BuildContext context, ToolCallRecord tc) {
    final grey = Colors.grey.shade700;
    final running = tc.resultCount == null;
    final failed = tc.resultCount != null && tc.resultCount! < 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (running)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          else
            Icon(
              failed ? Icons.error_outline : Icons.check_circle_outline,
              size: 14,
              color: failed ? Colors.redAccent : Colors.green.shade600,
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tc.query.isEmpty ? tc.name : '${tc.name}：${tc.query}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: grey),
            ),
          ),
          if (!running && !failed)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                '${tc.resultCount} 字符',
                style: Theme.of(
                  context,
                ).textTheme.labelSmall?.copyWith(color: grey),
              ),
            ),
        ],
      ),
    );
  }

  /// 思考过程折叠块（llama.cpp 风格：灰色小字 + 展开/收起）。
  /// 展开时思考区增高：上翻补偿/贴底保持由 ChatScrollPosition 在
  /// 布局阶段统一处理（correctForNewDimensions），无需额外干预
  Widget _thinkingBlock(BuildContext context, String thinking) {
    return _ThinkingBlock(thinking: thinking);
  }

  /// 流式等待占位（三个点）
  Widget _typingDots(BuildContext context) {
    return _TypingDots(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
    );
  }

  /// 抽屉页面：并排按钮（思考深度 / 提示词模板）+ 历史对话滚动栏
  Widget _buildDrawer({required double topPad}) {
    const depthLabels = ['关闭', '开启', '最高'];
    return Container(
      // 抽屉页面：亮色浅灰 / 暗色深灰
      color: Theme.of(context).brightness == Brightness.dark
          ? kSheetBgDark
          : const Color(0xFFE8E8E8),
      // 内容宽度基准 = 主页面收纳后的实际最左侧
      //（右移 300 + 缩放 88% 居中产生的左右留白的一半），左右各留 16 等距
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            // 容器右缘 = 主页面收纳后的实际最左侧 - 16（右间距 16，
            // 容器宽度含内部左右 padding，无需再减）
            maxWidth:
                (_drawerShift +
                    (MediaQuery.sizeOf(context).width -
                            MediaQuery.sizeOf(context).width * 0.88) /
                        2) -
                16,
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, topPad + 16, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部标题行：LLM_Chat + 右侧新建对话按钮
                Row(
                  children: [
                    Text(
                      'LLM_Chat',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    // 新建对话（按下后关闭抽屉回到主页面）
                    _smallButton(
                      icon: Icons.add,
                      label: null,
                      onTap: () {
                        _newConversation();
                        _drawerController.animateTo(
                          0,
                          curve: Curves.easeOutQuart,
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 两个并排按钮（固定等高对齐；左右等间距）
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: _drawerButton(
                          icon: Icons.lightbulb_outline, // 与思考过程块图标统一
                          label: '思考深度',
                          value: depthLabels[_thinkingDepth],
                          onTap: () {
                            setState(
                              () => _thinkingDepth = (_thinkingDepth + 1) % 3,
                            );
                            // 固化到存档：重启后保持
                            _store?.saveThinkingDepth(_thinkingDepth);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SizedBox(
                        height: 64,
                        child: _drawerButton(
                          icon: Icons.auto_awesome,
                          label: '提示词模板',
                          // 不显示副标题（与思考深度按钮的信息密度一致）
                          onTap: _showPromptTemplateSheet,
                        ),
                      ),
                    ),
                  ],
                ),
                // 按钮组与历史对话区域之间留出间距
                const SizedBox(height: 16),
                // 历史对话区域：左右等间距（撑满可用宽度）
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 标题行：历史对话 + 右侧搜索/批量管理按钮
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Text(
                              '历史对话',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const Spacer(),
                            // 搜索（聚焦时显示搜索框）
                            _smallButton(
                              icon: Icons.search,
                              label: null,
                              onTap: () => setState(() {
                                _historySearching = !_historySearching;
                                if (!_historySearching) {
                                  _historyQuery = '';
                                  _batchMode = false;
                                }
                              }),
                            ),
                            const SizedBox(width: 4),
                            // 批量管理（多选归档/删除）
                            _smallButton(
                              icon: Icons.checklist,
                              label: null,
                              onTap: () => setState(() {
                                _batchMode = !_batchMode;
                                if (!_batchMode) _batchSelected.clear();
                              }),
                            ),
                          ],
                        ),
                      ),
                      // 搜索框（搜索模式）：出现/消失高度展开 + 淡入过渡
                      AnimatedSize(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        alignment: Alignment.topCenter,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 160),
                          transitionBuilder: (child, anim) =>
                              FadeTransition(opacity: anim, child: child),
                          child: _historySearching
                              ? Padding(
                                  key: const ValueKey('searchField'),
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: TextField(
                                    autofocus: true,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                    onChanged: (v) => setState(
                                      () => _historyQuery = v.trim(),
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '搜索对话标题…',
                                      isDense: true,
                                      filled: true,
                                      fillColor: Colors.grey.withValues(
                                        alpha: 0.15,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide.none,
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey('searchNone'),
                                ),
                        ),
                      ),
                      // 批量操作条（批量管理模式）
                      // 圆角容器，条目间用线分割。
                      // 批量管理模式：操作条（全选/归档）在容器内顶部
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(
                              alpha:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? 0.12
                                  : 0.5,
                            ),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          clipBehavior: Clip.antiAlias, // 圆角裁剪列表内容
                          child: Column(
                            children: [
                              // 批量操作条（容器内顶部，与列表一体）
                              // 批量操作条：出现/消失带过渡动画（高度展开 + 从上滑入）
                              AnimatedSize(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                                alignment: Alignment.topCenter,
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 220),
                                  // 移动动画：从上方滑入/滑出（不用淡入淡出）
                                  transitionBuilder: (child, anim) =>
                                      SlideTransition(
                                        position: Tween<Offset>(
                                          begin: const Offset(0, -1),
                                          end: Offset.zero,
                                        ).animate(anim),
                                        child: child,
                                      ),
                                  child: _batchMode
                                      ? Column(
                                          key: const ValueKey('batchBar'),
                                          children: [
                                            Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                    vertical: 6,
                                                  ),
                                              child: Row(
                                                children: [
                                                  _batchBarButton(
                                                    label:
                                                        _batchSelected.length ==
                                                            _visibleHistoryCount
                                                        ? '取消全选'
                                                        : '全选',
                                                    onPressed: () => setState(() {
                                                      if (_batchSelected
                                                              .length ==
                                                          _visibleHistoryCount) {
                                                        _batchSelected.clear();
                                                      } else {
                                                        _batchSelected
                                                          ..clear()
                                                          ..addAll(
                                                            _visibleHistory.map(
                                                              (c) => c.id,
                                                            ),
                                                          );
                                                      }
                                                    }),
                                                  ),
                                                  const Spacer(),
                                                  _batchBarButton(
                                                    label:
                                                        '归档 ${_batchSelected.isEmpty ? '' : _batchSelected.length}',
                                                    onPressed:
                                                        _batchSelected.isEmpty
                                                        ? null
                                                        : () => _batchArchive(),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            // 实线分隔（与列表明显区分，不用渐变）
                                            Container(
                                              height: 1,
                                              color: Colors.grey.withValues(
                                                alpha: 0.3,
                                              ),
                                            ),
                                          ],
                                        )
                                      : const SizedBox.shrink(
                                          key: ValueKey('none'),
                                        ),
                                ),
                              ),
                              Expanded(
                                child: ListView.separated(
                                  // 顶部/底部都不留白：条目贴住滚动栏头尾
                                  padding: EdgeInsets.zero,
                                  itemCount: _visibleHistory.length,
                                  // 分割线：中间实、向两边渐隐
                                  separatorBuilder: (_, _) => Container(
                                    height: 1,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Color(0x00000000), // 透明
                                          Color(0x1A000000), // 中间 10% 黑
                                          Color(0x00000000), // 透明
                                        ],
                                      ),
                                    ),
                                  ),
                                  itemBuilder: (context, index) {
                                    final c = _visibleHistory[index];
                                    final isActive = c.id == _currentId;
                                    final showActions =
                                        _historyLongPressed == index;
                                    final selected = _batchSelected.contains(
                                      c.id,
                                    );
                                    // 内联重命名：条目原地变输入框（无独立窗口）
                                    if (_renamingIndex == index) {
                                      return _inlineRenameField(
                                        context,
                                        c,
                                        index,
                                      );
                                    }
                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () {
                                          // 批量模式：点击切换选中
                                          if (_batchMode) {
                                            setState(() {
                                              if (selected) {
                                                _batchSelected.remove(c.id);
                                              } else {
                                                _batchSelected.add(c.id);
                                              }
                                            });
                                            return;
                                          }
                                          if (showActions) {
                                            setState(
                                              () => _historyLongPressed = null,
                                            );
                                            return;
                                          }
                                          // 切换会话
                                          setState(() {
                                            _currentId = c.id;
                                            _historyLongPressed = null;
                                          });
                                          _drawerController.animateTo(
                                            0,
                                            curve: Curves.easeOutQuart,
                                          );
                                          // 切换后贴底看最新消息
                                          _scrollToBottom();
                                        },
                                        onLongPress: _batchMode
                                            ? null
                                            : () => setState(
                                                () =>
                                                    _historyLongPressed = index,
                                              ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                          ),
                                          child: SizedBox(
                                            height: 44,
                                            child: Row(
                                              children: [
                                                // 批量模式：复选框（出现/消失宽度展开过渡）
                                                AnimatedSize(
                                                  duration: const Duration(
                                                    milliseconds: 180,
                                                  ),
                                                  curve: Curves.easeOut,
                                                  alignment:
                                                      Alignment.centerLeft,
                                                  child: AnimatedSwitcher(
                                                    duration: const Duration(
                                                      milliseconds: 150,
                                                    ),
                                                    transitionBuilder:
                                                        (child, anim) =>
                                                            FadeTransition(
                                                              opacity: anim,
                                                              child: child,
                                                            ),
                                                    child: _batchMode
                                                        ? Row(
                                                            key: const ValueKey(
                                                              'batchCheck',
                                                            ),
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            children: [
                                                              Checkbox(
                                                                value: selected,
                                                                onChanged: (v) => setState(() {
                                                                  if (v ==
                                                                      true) {
                                                                    _batchSelected
                                                                        .add(
                                                                          c.id,
                                                                        );
                                                                  } else {
                                                                    _batchSelected
                                                                        .remove(
                                                                          c.id,
                                                                        );
                                                                  }
                                                                }),
                                                                // 打勾底色统一灰白体系（深灰）
                                                                activeColor:
                                                                    Colors
                                                                        .grey
                                                                        .shade700,
                                                                checkColor:
                                                                    Colors
                                                                        .white,
                                                                materialTapTargetSize:
                                                                    MaterialTapTargetSize
                                                                        .shrinkWrap,
                                                                visualDensity:
                                                                    VisualDensity
                                                                        .compact,
                                                              ),
                                                              const SizedBox(
                                                                width: 2,
                                                              ),
                                                            ],
                                                          )
                                                        : const SizedBox.shrink(
                                                            key: ValueKey(
                                                              'batchCheckNone',
                                                            ),
                                                          ),
                                                  ),
                                                ),
                                                // 锁定徽标
                                                if (c.locked) ...[
                                                  Icon(
                                                    Icons.lock_outline,
                                                    size: 12,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                  const SizedBox(width: 4),
                                                ],
                                                Expanded(
                                                  child: Text(
                                                    c.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: Theme.of(context)
                                                        .textTheme
                                                        .bodyMedium
                                                        ?.copyWith(
                                                          fontWeight: isActive
                                                              ? FontWeight.w600
                                                              : null,
                                                        ),
                                                  ),
                                                ),
                                                // 长按后右侧浮现：重命名 + 锁定 + 归档
                                                if (showActions) ...[
                                                  InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                    onTap: () => setState(() {
                                                      _renamingIndex = index;
                                                      _historyLongPressed =
                                                          null;
                                                    }),
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 6,
                                                          ),
                                                      child: Icon(
                                                        Icons.edit_outlined,
                                                        size: 18,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                  // 锁定/解锁（锁定的对话不自动归档）
                                                  InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                    onTap: () => _toggleLock(c),
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 6,
                                                          ),
                                                      child: Icon(
                                                        c.locked
                                                            ? Icons.lock_open
                                                            : Icons
                                                                  .lock_outline,
                                                        size: 18,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                  // 归档（替代删除：可恢复）
                                                  InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          10,
                                                        ),
                                                    onTap: () =>
                                                        _archiveConversation(
                                                          index,
                                                        ),
                                                    child: Padding(
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 10,
                                                            vertical: 6,
                                                          ),
                                                      child: Icon(
                                                        Icons.archive_outlined,
                                                        size: 18,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurfaceVariant,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 等间距：区块之间统一 8
                const SizedBox(height: 8),
                // 底部按钮行：设置 + 主题模式（跟随系统/浅色/深色 循环切换）
                Align(
                  alignment: Alignment.centerLeft,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _smallButton(
                        icon: Icons.settings_outlined,
                        label: '设置',
                        onTap: _openSettings,
                      ),
                      const SizedBox(width: 8),
                      _smallButton(
                        icon: switch (widget.themeMode) {
                          ThemeMode.dark => Icons.dark_mode_outlined,
                          ThemeMode.light => Icons.light_mode_outlined,
                          ThemeMode.system => Icons.brightness_auto_outlined,
                        },
                        label: switch (widget.themeMode) {
                          ThemeMode.dark => '深色',
                          ThemeMode.light => '浅色',
                          ThemeMode.system => '系统',
                        },
                        onTap: widget.onToggleTheme,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 左对齐小按钮（设置 / 主题切换）
  Widget _smallButton({
    required IconData icon,
    String? label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? 0.15 : 0.6,
      ),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: label == null ? 10 : 14,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16),
              if (label != null) ...[const SizedBox(width: 8), Text(label)],
            ],
          ),
        ),
      ),
    );
  }

  /// 抽屉按钮（并排样式）
  Widget _drawerButton({
    required IconData icon,
    required String label,
    String? value,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white.withValues(
        alpha: Theme.of(context).brightness == Brightness.dark ? 0.15 : 0.6,
      ),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              if (value != null) ...[
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    // 浅灰色（原为主题蓝，统一为项目灰）
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 附件：图片或文件
class _Attachment {
  const _Attachment({
    required this.isImage,
    required this.name,
    this.path,
    this.size,
  });

  final bool isImage;
  final String name;

  /// 本地路径（web 上图片为 blob URL）
  final String? path;

  /// 文件字节数（文件选择器提供；图片/未知时为 null）
  final int? size;

  /// 读取文件字节（XFile 跨平台：本地路径与 web blob URL 通吃）
  Future<Uint8List> readBytes() async {
    final p = path;
    if (p == null || p.isEmpty) return Uint8List(0);
    return XFile(p).readAsBytes();
  }

  /// 读取文本内容（utf8 容错解码）。返回 (内容, 是否截断)：
  /// 超过 kMaxTextAttachmentBytes 时截断读取，避免超大文件打爆请求
  Future<(String, bool)> readText() async {
    final bytes = await readBytes();
    if (bytes.isEmpty) return ('', false);
    final truncated = bytes.length > kMaxTextAttachmentBytes;
    final chunk = truncated ? bytes.sublist(0, kMaxTextAttachmentBytes) : bytes;
    return (utf8.decode(chunk, allowMalformed: true), truncated);
  }
}

/// 附件条：独立容器（悬浮于输入栏上方，z 最高），
/// 横向滚动与角标删除点击统一由本容器处理，不受其他层干扰
class _AttachmentBar extends StatelessWidget {
  const _AttachmentBar({required this.attachments, required this.onDelete});

  final List<_Attachment> attachments;
  final ValueChanged<int> onDelete;

  @override
  Widget build(BuildContext context) {
    // ShaderMask + dstIn：附件条内容自身按渐变透明度显示——
    // 两侧边缘附件真实渐隐（透明），露出背后内容，而非被背景色遮盖
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color(0x00000000), // 左缘透明
          Color(0xFFFFFFFF), // 不透明
          Color(0xFFFFFFFF), // 不透明
          Color(0x00000000), // 右缘透明
        ],
        stops: [0.0, 0.05, 0.95, 1.0],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        // 左右空行程：首尾附件可滚到距边缘留白处
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final att = attachments[index];
          return SizedBox(
            // 文件附件：llama.cpp 风格横排卡片（图标 + 文件名 + 大小）
            width: att.isImage ? 68 : 150,
            height: 68,
            child: Stack(
              fit: StackFit.expand,
              // 阴影需超出卡片边界，不裁剪
              clipBehavior: Clip.none,
              children: [
                // 内容：图片缩略图 / 文件图标（悬浮阴影）
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: att.isImage
                        ? _imageThumb(context, att)
                        : _fileIcon(context, att),
                  ),
                ),
                // 常态角标关闭按钮（右上角）
                Positioned(
                  top: 2,
                  right: 2,
                  child: Material(
                    color: Colors.black54,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => onDelete(index),
                      child: const SizedBox(
                        width: 20,
                        height: 20,
                        child: Icon(Icons.close, size: 14, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 图片缩略图
  Widget _imageThumb(BuildContext context, _Attachment att) {
    final path = att.path;
    if (path == null) return const SizedBox.shrink();
    return kIsWeb
        ? Image.network(path, fit: BoxFit.cover)
        : Image.file(File(path), fit: BoxFit.cover);
  }

  /// 文件卡片（llama.cpp 风格横排）：文件图标 + 文件名 + 大小两行
  Widget _fileIcon(BuildContext context, _Attachment att) {
    final isText = isTextAttachmentName(att.name);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Icon(
            isText ? Icons.text_snippet_outlined : Icons.insert_drive_file,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  att.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  formatFileSize(att.size),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部 Liquid Glass 输入栏：
/// 圆角容器（初始高度 = 圆角直径）+ 左右下角与圆角同心的圆形按钮 +
/// 居中输入栏（点击/有字时上移一个边长、拉长至全宽，容器随之增高）
class _GlassInputBar extends StatefulWidget {
  const _GlassInputBar({
    required this.onAddImage,
    required this.onAddFile,
    required this.containerTopNotifier,
    required this.onSend,
    required this.isResponding,
    required this.onStop,
    required this.onEditPrompt,
    required this.onFocusChanged,
    required this.onManageMcp,
    required this.onLongPressMcp,
    required this.onLongPressBuiltin,
    required this.builtinToolsOn,
    required this.onToggleBuiltinTools,
    required this.onPasteAsFile,
    required this.pasteLongTextAsFile,
    required this.pasteThreshold,
    required this.thinkingDepth,
    required this.onThinkingDepthChanged,
    required this.modelSupportsMultimodal,
    required this.modelSupportsTools,
    required this.modelSupportsThinking,
    required this.hasAttachments,
  });

  /// 加号面板：选择图片 / 文件（由 HomePage 统一处理附件）
  final VoidCallback onAddImage;
  final VoidCallback onAddFile;

  /// 上报输入栏容器顶边位置（附件条绑定其上方）
  final ValueNotifier<double> containerTopNotifier;

  /// 发送消息（文本 + 附件名列表）；由 HomePage 处理实际对话逻辑
  final void Function(String text, List<String> attachmentNames) onSend;

  /// 是否正在流式响应（true 时发送按钮变停止按钮）
  final bool isResponding;

  /// 停止流式
  final VoidCallback onStop;

  /// 编辑提示词（加号面板"提示词"按钮）
  final VoidCallback onEditPrompt;

  /// 输入栏聚焦/失焦回调（聚焦时列表滚动到底）
  final ValueChanged<bool> onFocusChanged;

  /// 打开当前对话的 MCP 管理（加号面板"MCP"按钮）
  final VoidCallback onManageMcp;

  /// 长按加号面板 MCP 按钮：直达 MCP 设置页
  final VoidCallback onLongPressMcp;

  /// 长按加号面板内置工具按钮：直达通用设置页
  final VoidCallback onLongPressBuiltin;

  /// 内置工具开关状态（当前对话生效值）
  final bool builtinToolsOn;

  /// 切换当前对话的内置工具（时间/位置）
  final VoidCallback onToggleBuiltinTools;

  /// 粘贴长文本转文件回调（HomePage 写入 _attachments）
  final void Function(String text) onPasteAsFile;

  /// 是否启用粘贴长文本转文件
  final bool pasteLongTextAsFile;

  /// 粘贴阈值字符数
  final int pasteThreshold;

  /// 思考深度（0 关闭 / 1 开启 / 2 最高；与抽屉栏同步）
  final int thinkingDepth;

  /// 思考深度变更回调（主页面 setState + 持久化）
  final ValueChanged<int> onThinkingDepthChanged;

  /// 当前模型能力（false = 不支持，面板对应选项降亮度禁用）
  final bool modelSupportsMultimodal;
  final bool modelSupportsTools;
  final bool modelSupportsThinking;

  /// 是否有附件（有附件时即使无文字也可发送）
  final bool hasAttachments;

  @override
  State<_GlassInputBar> createState() => _GlassInputBarState();
}

class _GlassInputBarState extends State<_GlassInputBar> {
  static const double _radius = 28; // 圆角半径 R（锁定不变）
  static const double _side = _radius * 2; // 圆角直径（容器初始高度）
  static const double _buttonGap = 6; // 按钮与圆角边缘的间隙
  static const double _buttonSize = (_radius - _buttonGap) * 2; // 按钮直径（小于圆角直径）
  static const double _topPad = 8; // 输入栏上方边距
  static const double _edgePadding = 12; // 激活时输入栏左右边距
  static const double _hMargin = 12; // 容器左右边距

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _active = false;

  /// 上一帧文本（粘贴检测：单次增量超阈值视为粘贴）
  String _prevText = '';

  /// 加号面板内思考深度本地值（bottomSheet builder 是闭包、
  /// 捕获旧 widget；用本地状态驱动滑条避免拖动被锁死）
  int _sheetDepth = 0;

  /// 加号面板内内置工具开关本地值（bottomSheet 闭包捕获旧 widget，用本地状态驱动）
  bool _sheetBuiltinTools = false;

  /// 输入栏当前高度：按键时用 TextPainter 同步估算（无布局、无卡顿）
  double _inputHeight = 48;

  /// 上一帧键盘 inset（键盘动画进行中检测用）
  double _lastInset = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_syncActive);
  }

  /// 文本变化：同步激活态 + 粘贴长文本检测
  void _onTextChanged() {
    _syncActive();
    _detectPasteLongText();
  }

  /// 粘贴检测：单次增量超过阈值且功能开启时，回滚输入文本并转成文件附件。
  /// 用 controller listener 监听文本突变（移动端粘贴经输入法/长按菜单，
  /// 拿不到 onPaste 回调；阈值通常 2000 字符，打字误判率极低）
  void _detectPasteLongText() {
    if (!widget.pasteLongTextAsFile || widget.pasteThreshold <= 0) {
      _prevText = _controller.text;
      return;
    }
    final cur = _controller.text;
    // 增量 = 当前文本长度 - 上一帧；超过阈值视为粘贴
    final delta = cur.length - _prevText.length;
    if (delta > widget.pasteThreshold) {
      // 提取粘贴的内容：取末尾 delta 字符（最常见场景：在末尾粘贴）
      final inserted = cur.substring(cur.length - delta);
      // 回滚到粘贴前
      final before = cur.substring(0, cur.length - delta);
      _controller
        ..text = before
        // 光标移到末尾
        ..selection = TextSelection.collapsed(offset: before.length);
      widget.onPasteAsFile(inserted);
    }
    _prevText = _controller.text;
  }

  void _syncActive() {
    final active = _focusNode.hasFocus || _controller.text.isNotEmpty;
    // 聚焦时通知 HomePage 把滚动内容滚到底（输入栏/键盘上方可见）
    if (_focusNode.hasFocus) widget.onFocusChanged(true);
    final style = Theme.of(context).textTheme.bodyLarge;

    // 同步估算行数（1~5 行）：TextPainter 纯计算，不触发布局。
    // 宽度与激活态输入框内容宽度一致；行高取实际排版度量，
    // 避免估算偏差导致文字在框内被截断
    final containerWidth = (MediaQuery.sizeOf(context).width - _hMargin * 2)
        .clamp(0.0, double.infinity);
    final fieldWidth = (containerWidth - _edgePadding * 2).clamp(
      0.0,
      double.infinity,
    );
    final painter =
        TextPainter(
          text: TextSpan(text: _controller.text, style: style),
          textDirection: TextDirection.ltr,
        )..layout(
          maxWidth: (fieldWidth - 32).clamp(
            0.0,
            double.infinity,
          ), // 32=左右 contentPadding
        );
    final metrics = painter.computeLineMetrics();
    final lineCount = metrics.length.clamp(1, 5);
    final lineHeight = metrics.isEmpty
        ? (style?.fontSize ?? 16) * (style?.height ?? 1.5)
        : metrics.first.height;

    setState(() {
      _active = active;
      _inputHeight = 24 + lineCount * lineHeight; // 内容 padding 24 + 行高×行数
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.paddingOf(context).bottom;
    // 仅当输入栏自身触发输入时随键盘升起；编辑消息/提示词等其他输入场景
    // 下输入栏保持在底部（键盘由别的输入框触发，不顶起输入栏）
    final rawInset = _focusNode.hasFocus
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    // 键盘动画进行中（inset 逐帧变化）→ 零时长直接跟随，精确贴键盘；
    // 稳定后（含失焦瞬间目标归零）→ 走平滑过渡
    final insetAnimating =
        _focusNode.hasFocus && (rawInset - _lastInset).abs() > 0.5;
    _lastInset = rawInset;
    final keyboardInset = rawInset;
    // 宽度保护：布局早期 MediaQuery 宽度可能为 0，防止负宽度崩溃
    final containerWidth = (MediaQuery.sizeOf(context).width - _hMargin * 2)
        .clamp(0.0, double.infinity);

    // 输入栏水平：初始长度 = 按钮圆心距离 - 圆角直径；激活拉满（留边距）
    final initWidth = (containerWidth - _side * 2).clamp(
      0.0,
      double.infinity,
    ); // (W-2R) - 2R
    final inputWidth = _active
        ? (containerWidth - _edgePadding * 2).clamp(0.0, double.infinity)
        : initWidth;

    // 输入栏垂直：初始垂直居中于按钮行；激活后贴容器顶部（y 基准 = 容器顶部）
    final initTop = (_side - _inputHeight) / 2;
    final inputTop = _active ? _topPad : initTop;

    // 输入栏容器总高（占位 + 按钮行）——上报给附件条绑定
    final containerHeight = (_active ? _topPad + _inputHeight : 0) + _side;
    widget.containerTopNotifier.value = containerHeight + 8;

    return Align(
      alignment: Alignment.bottomCenter,
      // AnimatedPadding：键盘动画期间零时长直接跟随（精确贴键盘）；
      // 失焦时 keyboardInset 瞬间归零，用 300ms 隐式动画平滑下移，
      // 避免输入栏直接跳到底部、大小过渡动画被跳位掩盖
      child: AnimatedPadding(
        duration: insetAnimating
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: bottomPad + 8 + keyboardInset,
          left: _hMargin,
          right: _hMargin,
        ),
        // 输入栏容器
        child: CupertinoLiquidGlass(
          blurSigma: 10, // 更模糊一点
          // tint 透明度：亮色 0.28（默认）、暗色 0.12——保持玻璃半透明，
          // 过高（0.6）会变成白色实色
          tintOpacity: Theme.of(context).brightness == Brightness.dark
              ? 0.12
              : 0.28,
          borderRadius: BorderRadius.circular(_radius),
          glowRadius: 10,
          specularGradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xCCFFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)],
          ),
          child: Stack(
            children: [
              // 非定位占位：决定容器尺寸（激活时顶部让出输入栏空间 + 底部按钮行）
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutBack, // 非线性：先快后缓 + 轻微回弹
                    height: _active ? _topPad + _inputHeight : 0,
                  ),
                  SizedBox(width: containerWidth, height: _side),
                ],
              ),
              // 输入栏：位置跟随容器（top 无独立动画，由容器增高带动上移），
              // 只保留拉长动画——整体一致，无顺序感
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack, // 非线性：与容器增高同曲线同步
                left: (containerWidth - inputWidth) / 2,
                top: inputTop,
                width: inputWidth,
                child: _buildInput(),
              ),
              // 左圆按钮：与左下圆角同心（比圆角小，留边缘间隙）
              // 点击弹出底部面板
              Positioned(
                left: _buttonGap,
                bottom: _buttonGap,
                child: _roundButton(Icons.add, onPressed: _showAddPanel),
              ),
              // 右圆按钮：发送 / 响应中变停止
              // 深色模式：按钮用白底黑图标（黑底在暗色玻璃上不可见）
              Positioned(
                right: _buttonGap,
                bottom: _buttonGap,
                child: widget.isResponding
                    ? _roundButton(
                        Icons.stop, // 响应中：停止
                        // 与发送键同款灰玻璃风格（仅图标不同）
                        backgroundColor: Colors.grey.withValues(alpha: 0.5),
                        iconColor: Theme.of(context).colorScheme.onSurface,
                        onPressed: widget.onStop,
                      )
                    : _roundButton(
                        Icons.arrow_upward, // 小箭头发送
                        // 苹果玻璃风格（与输入栏容器一致）：激活时灰玻璃更实、
                        // 图标清晰；未激活时灰玻璃更淡、图标半透明
                        backgroundColor: _canSend
                            ? Colors.grey.withValues(alpha: 0.5)
                            : Colors.grey.withValues(
                                alpha:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? 0.35
                                    : 0.25,
                              ),
                        iconColor: _canSend
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.45),
                        // 激活时玻璃 tint 更实（玻璃质感），未激活自动淡
                        tintOpacity: _canSend ? 0.4 : null,
                        onPressed: _canSend ? _sendMessage : null,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 发送消息：把文本通过 onSend 上抛给 HomePage，清空输入框。
  /// 可单独发送附件（无文字）
  void _sendMessage() {
    final text = _controller.text.trim();
    if (text.isEmpty && !widget.hasAttachments) return;
    widget.onSend(text, const []);
    _controller.clear();
    _syncActive();
  }

  /// 发送可用：有文字或有附件（可单独发送文件，同 llama.cpp）
  bool get _canSend => _controller.text.isNotEmpty || widget.hasAttachments;

  /// 加号按钮：弹出底部面板（主界面变暗，面板占屏幕 2/5，
  /// 圆角、顶部居中小横条、下拉关闭、内部为空）
  void _showAddPanel() {
    // 打开面板时同步当前思考深度到本地状态（滑条初始位置）
    _sheetDepth = widget.thinkingDepth;
    // 打开面板时同步内置工具开关状态（bottomSheet 闭包捕获旧值，本地驱动）
    _sheetBuiltinTools = widget.builtinToolsOn;
    // 背景跟随全局 bottomSheetTheme（亮色纯白/暗色 1C1C1E，无 surface tint 杂色）
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? kSheetBgDark
          : Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.4), // 主界面变暗
      isScrollControlled: true,
      showDragHandle: true, // 顶部居中小横条
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          // 高度自适应内容（不再固定 2/5 屏），上下边距等距
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 思考深度滑动条（三档，与抽屉栏同步）──
              // 当前模型不支持思考：整块降亮度 + 滑条禁用
              Opacity(
                opacity: widget.modelSupportsThinking ? 1 : 0.4,
                child: Row(
                  children: [
                    Icon(
                      Icons.lightbulb_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '思考深度',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      const ['关闭', '开启', '最高'][_sheetDepth],
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              // 槽型滑条（细轨道 + 圆钮，项目灰白风格）。
              // 值用面板本地状态 _sheetDepth 驱动——bottomSheet 的 builder 是
              // 闭包（捕获旧 widget），直接用 widget.thinkingDepth 会锁死拖动
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 10,
                    activeTrackColor: Colors.grey.shade700,
                    inactiveTrackColor: Colors.grey.withValues(alpha: 0.25),
                    thumbColor: Theme.of(context).brightness == Brightness.dark
                        ? Colors.white
                        : Colors.white,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 0,
                    ),
                    tickMarkShape: SliderTickMarkShape.noTickMark,
                  ),
                  child: Slider(
                    value: _sheetDepth.toDouble(),
                    min: 0,
                    max: 2,
                    divisions: 2,
                    // 拖动中：本地状态驱动滑条位置 + 回调主页面（抽屉同步）。
                    // 模型不支持思考时禁用
                    onChanged: widget.modelSupportsThinking
                        ? (v) {
                            setSheetState(() => _sheetDepth = v.round());
                            widget.onThinkingDepthChanged(v.round());
                          }
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 三个并排按钮：图片 / 文件 / 提示词
              Row(
                children: [
                  Expanded(
                    // 当前模型不支持多模态：变暗 + 图标斜杠 + 不可点
                    child: _panelButton(
                      icon: Icons.image_outlined,
                      label: '图片',
                      onTap: widget.modelSupportsMultimodal
                          ? widget.onAddImage
                          : null,
                      disabled: !widget.modelSupportsMultimodal,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _panelButton(
                      icon: Icons.folder_outlined,
                      label: '文件',
                      onTap: widget.onAddFile,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _panelButton(
                      icon: Icons.auto_awesome,
                      label: '提示词',
                      onTap: () {
                        Navigator.of(context).pop(); // 关面板
                        widget.onEditPrompt();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 大按钮行：MCP 工具管理（全宽）+ 右侧内置工具开关（时间/位置）
              Row(
                children: [
                  Expanded(
                    // 当前模型不支持工具调用：变暗 + 图标斜杠 + 不可点
                    child: _panelButton(
                      icon: Icons.hub_outlined,
                      label: 'MCP 工具',
                      large: true,
                      onTap: widget.modelSupportsTools
                          ? () {
                              Navigator.of(context).pop(); // 关面板
                              widget.onManageMcp();
                            }
                          : null,
                      // 长按：直达 MCP 设置页
                      onLongPress: () {
                        Navigator.of(context).pop(); // 关面板
                        widget.onLongPressMcp();
                      },
                      disabled: !widget.modelSupportsTools,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 内置工具开关：三态——开启（正常）/ 关闭（内容降亮度 + 斜杠）/
                  // 不可用（模型不支持工具：整体含背景变暗 + 斜杠 + 不可点，
                  // 与图片/MCP 禁用按钮一致）
                  Opacity(
                    opacity: widget.modelSupportsTools ? 1 : 0.4,
                    child: Material(
                      color: Colors.grey.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: widget.modelSupportsTools
                            ? () {
                                // 面板内即时刷新（bottomSheet 闭包捕获旧值，
                                // 本地状态驱动，避免点击后状态不更新）
                                setSheetState(
                                  () =>
                                      _sheetBuiltinTools = !_sheetBuiltinTools,
                                );
                                widget.onToggleBuiltinTools();
                              }
                            : null,
                        // 长按：直达通用设置页（工具明细开关/循环上限）
                        onLongPress: () {
                          Navigator.of(context).pop(); // 关面板
                          widget.onLongPressBuiltin();
                        },
                        child: Padding(
                          // 与 large 按钮同高（28×2 + 内容）
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 28,
                          ),
                          child: Opacity(
                            // 关闭时内容降亮度（背景不变）；
                            // 不可用时外层已整体 0.4，内容保持 1——
                            // 避免双重变暗导致比图片/MCP 禁用更淡
                            opacity: widget.modelSupportsTools
                                ? (_sheetBuiltinTools ? 1 : 0.55)
                                : 1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 扳手图标：开启且可用 = 默认色（与其他按钮一致）；
                                // 关闭/不可用时灰色 + 反斜杠（统一禁用色）
                                SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Icon(
                                        Icons.build,
                                        size: 24,
                                        color:
                                            _sheetBuiltinTools &&
                                                widget.modelSupportsTools
                                            ? null
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                      ),
                                      if (!_sheetBuiltinTools ||
                                          !widget.modelSupportsTools)
                                        Transform.rotate(
                                          angle: -math.pi / 4,
                                          child: Container(
                                            width: 31,
                                            // 与图片/MCP 禁用按钮的斜杠一致（粗版）
                                            height: 3,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '内置',
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(
                                        // 开启且可用 = 默认色；否则统一灰色
                                        color:
                                            _sheetBuiltinTools &&
                                                widget.modelSupportsTools
                                            ? null
                                            : Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 面板按钮（图标 + 文字，圆角水波纹；large = 全宽大按钮）
  /// 面板按钮；[disabled] = 模型能力不支持：整体变暗 + 图标加斜杠 +
  /// 不可点击
  Widget _panelButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    bool large = false,
    bool disabled = false,
  }) {
    return Opacity(
      opacity: disabled ? 0.4 : 1,
      child: Material(
        color: Colors.grey.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: disabled ? null : (onTap ?? () {}),
          onLongPress: disabled ? null : onLongPress,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: large ? 28 : 22),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // 图标：禁用时叠加反斜杠（禁止）
                SizedBox(
                  width: large ? 24 : 20,
                  height: large ? 24 : 20,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        icon,
                        size: large ? 24 : 20,
                        // 禁用时图标用灰色（与内置工具等禁用按钮统一）
                        color: disabled
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : null,
                      ),
                      if (disabled)
                        Transform.rotate(
                          angle: -math.pi / 4,
                          child: Container(
                            width: large ? 32 : 28,
                            height: 3,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  // 禁用时文字用灰色（与内置工具等禁用按钮统一）
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: disabled
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 与圆角同心的圆形按钮（灰色玻璃风格 + 投影阴影，与页眉胶囊一致）
  /// 注意：点击 InkWell 必须放在 glass 内部（外层 GestureDetector 会被
  /// CupertinoLiquidGlass 的命中区域吞掉）——与页眉左侧胶囊同理
  Widget _roundButton(
    IconData icon, {
    VoidCallback? onPressed,
    Color? backgroundColor,
    Color? iconColor,
    double? tintOpacity,
  }) {
    final size = _buttonSize;
    final bg = backgroundColor ?? Colors.grey.withValues(alpha: 0.25);
    final ic = iconColor ?? Theme.of(context).colorScheme.onSurface;
    final isDarkBg = bg.computeLuminance() < 0.3; // 深色背景时提高 tint
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size / 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: CupertinoLiquidGlass(
        theme: LiquidGlassThemeData(
          tintColor: bg,
          // 显式 tint 优先（深色模式的白底按钮需高 tint 才可见）；
          // 否则按底色明暗：深色底 0.55 / 浅色底 0.1
          tintOpacity: tintOpacity ?? (isDarkBg ? 0.55 : 0.1),
        ),
        blurSigma: 8,
        borderRadius: BorderRadius.circular(size / 2),
        glowRadius: 10,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(size / 2),
          child: InkWell(
            borderRadius: BorderRadius.circular(size / 2),
            // onPressed 为 null 时不可点（发送按钮无文字时禁用）
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: 22, color: ic),
            ),
          ),
        ),
      ),
    );
  }

  /// 输入栏：最多 5 行，超过滚动显示
  Widget _buildInput() {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      minLines: 1,
      maxLines: 5,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: '输入消息…',
        isDense: true,
        filled: true,
        fillColor: Colors.transparent, // 输入栏透明
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class _VoicePulseIcon extends StatefulWidget {
  const _VoicePulseIcon();

  @override
  State<_VoicePulseIcon> createState() => _VoicePulseIconState();
}

class _VoicePulseIconState extends State<_VoicePulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.5,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)),
      child: Icon(
        Icons.keyboard_voice,
        size: 18,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

/// 流式等待三点动画：三个点依次跳动 + 渐隐（打字指示器）。
/// 用 CustomPaint 单层绘制（一个 RenderObject 画三个圆），
/// 比三个 Icon + 动画每帧重建轻量，动画层与消息气泡隔离
class _TypingDots extends StatefulWidget {
  const _TypingDots({required this.color});

  final Color color;

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  /// 循环动画（1.2s 一个周期）；流式开始后组件销毁自动停止
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          size: const Size(30, 12),
          painter: _TypingDotsPainter(
            color: widget.color,
            t: _controller.value,
          ),
        ),
      ),
    );
  }
}

/// 三点绘制：i 相位差 1/3 周期，sin 曲线控制跳动（scale）与渐隐（opacity）
class _TypingDotsPainter extends CustomPainter {
  _TypingDotsPainter({required this.color, required this.t});

  final Color color;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const dotRadius = 3.5;
    final spacing = size.width / 3;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final wave = math.sin(phase * 2 * math.pi).abs();
      // 跳动幅度 + 透明度联动
      final radius = dotRadius * (0.55 + 0.45 * wave);
      final opacity = 0.25 + 0.75 * wave;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(
        Offset(spacing * (i + 0.5), size.height / 2),
        radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_TypingDotsPainter old) =>
      old.t != t || old.color != color;
}

/// 思考过程折叠块（llama.cpp 风格：灰色小字 + 展开/收起箭头）
class _ThinkingBlock extends StatefulWidget {
  const _ThinkingBlock({required this.thinking});

  final String thinking;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  // 默认收起：只显示「思考过程」标签行，点击展开
  bool _expanded = false;

  /// 展开内容滚动控制器（流式时钉在底部）
  final ScrollController _scroll = ScrollController();

  /// 用户是否在底部（上翻查看时不强制拉回）
  bool _stickToBottom = true;

  /// 用户是否正在手指拖动（拖动期间不跟随，与主列表同一逻辑）
  bool _dragging = false;

  /// 滚动通知：跟踪手指拖动开始/结束
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _dragging = true;
    } else if (n is ScrollEndNotification && n.dragDetails != null) {
      _dragging = false;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final pos = _scroll.position;
      _stickToBottom = pos.pixels >= pos.maxScrollExtent - 8;
    });
  }

  @override
  void didUpdateWidget(_ThinkingBlock old) {
    super.didUpdateWidget(old);
    // 原生流式：贴底且未拖动时跟随滚动到底（拖动/上翻即暂停）
    if (widget.thinking != old.thinking && _stickToBottom && !_dragging) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients && _stickToBottom && !_dragging) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.grey.withValues(alpha: 0.15), // 中性灰底，不偏蓝
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 灯泡图标（参考 llama-ui 的 Reasoning 图标）
                    Icon(
                      Icons.lightbulb_outline,
                      size: 14,
                      color: Colors.grey.shade700, // 中性灰，不偏蓝
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '思考过程',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Colors.grey.shade700,
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 16,
                      color: Colors.grey.shade700,
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  // 展开内容：最大高度限制（llama.cpp 28rem 的移动端折中），
                  // 超出部分在块内滚动；拖动状态由 NotificationListener 跟踪
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: SizedBox(
                      width: double.infinity,
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScrollNotification,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          child: SelectableText(
                            widget.thinking,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey.shade700,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 页眉玻璃胶囊按钮：按压缩放反馈 + 自定义水波纹（扩散圆）。
/// 反馈动画都在按钮自身 State 内——父级重建（如新建对话清空内容）
/// 不会打断动画，动作可立即执行（无需延迟法）
/// 页眉（玻璃区 + 模型胶囊 + 下拉菜单）：独立 StatefulWidget——
/// 主页面 setState 只更新构造参数，页眉内部状态与动画（喇叭/菜单/
/// 波纹）完全独立，页面刷新不会打断页眉动画
class _ChatHeader extends StatefulWidget {
  const _ChatHeader({
    super.key,
    required this.topPad,
    required this.modelLabel,
    required this.visibleModels,
    required this.modelDisplay,
    required this.onModelSelected,
    required this.onNewConversation,
    required this.onOpenProvidersSettings,
  });

  final double topPad;
  final String modelLabel;
  final List<String> visibleModels;
  final String Function(String id) modelDisplay;
  final ValueChanged<String> onModelSelected;
  final VoidCallback onNewConversation;
  final VoidCallback onOpenProvidersSettings;

  @override
  State<_ChatHeader> createState() => _ChatHeaderState();
}

class _ChatHeaderState extends State<_ChatHeader>
    with SingleTickerProviderStateMixin {
  /// 页眉体高度（玻璃区域，不含状态栏）
  static const _headerBodyHeight = 54;

  bool _muted = false;
  bool _modelMenuOpen = false;

  /// 菜单展开/收起动画：forward=展开（fastOutSlowIn），reverse=收起（easeInCubic）
  late final AnimationController _menuController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  /// 展开/收起模型下拉菜单（显式动画）
  void _toggleMenu() {
    setState(() {
      _modelMenuOpen = !_modelMenuOpen;
      if (_modelMenuOpen) {
        _menuController.forward();
      } else {
        _menuController.reverse();
      }
    });
  }

  /// 关闭模型下拉菜单（选模型/点击遮罩时调用，带收起动画）
  void _closeMenu() {
    setState(() {
      _modelMenuOpen = false;
      _menuController.reverse();
    });
  }

  /// 测量模型名文本宽度（TextPainter 纯计算），供胶囊宽度动画使用
  double _measureModelText() {
    final painter = TextPainter(
      text: TextSpan(
        text: widget.modelLabel,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  @override
  void dispose() {
    _menuController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = widget.topPad;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // 页眉玻璃区
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: topPad + _headerBodyHeight,
          child: CupertinoLiquidGlass(
            blurSigma: 5,
            tintOpacity: 0.15,
            borderRadius: BorderRadius.zero,
            glowRadius: 10,
            specularGradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xCCFFFFFF), // 白 80%
                Color(0x66FFFFFF), // 白 40%
                Color(0x00FFFFFF), // 全透明
              ],
            ),
            child: Stack(
              // 允许胶囊阴影溢出到列表上方（hardEdge 会裁掉底部阴影）
              clipBehavior: Clip.none,
              children: [
                const IgnorePointer(child: SizedBox.expand()),
                // 透明度渐变层：顶部实色（与状态栏无缝）→ 渐隐
                // Builder 内部实时读取主题，缓存树内也随主题切换更新
                IgnorePointer(
                  child: Builder(
                    builder: (context) {
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      final topPad = MediaQuery.paddingOf(context).top;
                      final headerTop = isDark
                          ? const Color(0xFF161616)
                          : const Color(0xFFFFFFFF);
                      final gStart = topPad / (topPad + _headerBodyHeight);
                      return Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.0, gStart, 1.0],
                            colors: [
                              headerTop, // 状态栏段：实色
                              headerTop, // 页眉起点：100%
                              headerTop.withValues(alpha: 0), // 全透明
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                // 页眉右侧：胶囊按钮（灰色玻璃风格 + 外部投影）
                Positioned(
                  right: 12,
                  bottom: 10, // 略微上移
                  child: Container(
                    // 圆角与胶囊一致，阴影贴合形状；
                    // 偏移向下（0,4）+ 模糊 8：阴影主体在下方，内部干净
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: CupertinoLiquidGlass(
                      theme: LiquidGlassThemeData(
                        tintColor: Colors.grey, // 灰 tint
                        tintOpacity: 0.06, // 灰度浓度 0.06（更淡）
                      ),
                      blurSigma: 8,
                      borderRadius: BorderRadius.circular(24),
                      glowRadius: 10,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 喇叭/静音切换（按下缩放 + 图标切换动画）
                          GlassIconButton(
                            icon: _muted ? Icons.volume_off : Icons.volume_up,
                            onTap: () => setState(() => _muted = !_muted),
                          ),
                          // 分割线：中间深、向上下两边渐变透明
                          Container(
                            width: 1,
                            height: 30,
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Color(0x00000000),
                                  Color(0x4D000000),
                                  Color(0x00000000),
                                ],
                              ),
                            ),
                          ),
                          // 创建新对话（按下缩放反馈）
                          GlassIconButton(
                            icon: Icons.add_comment_outlined,
                            onTap: widget.onNewConversation, // 新对话
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 页眉左侧：模型选择（灰色玻璃胶囊，样式与右侧一致，> 转 90° 展开菜单）
                // 注意：点击 InkWell 必须放在 glass 内部（外层 GestureDetector 会被
                // CupertinoLiquidGlass 的命中区域吞掉，导致点不动——这正是当初
                // “DEBUG: 玻璃去掉，测命中” 的根因）
                Positioned(
                  left: 16,
                  bottom: 10, // 与右侧胶囊同高（26 + 上下 6 = 38）同底，中线对齐
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.15),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    // 灰色玻璃胶囊：与右侧胶囊样式一致
                    child: CupertinoLiquidGlass(
                      theme: LiquidGlassThemeData(
                        tintColor: Colors.grey, // 灰 tint
                        tintOpacity: 0.06, // 灰度浓度 0.06（更淡）
                      ),
                      blurSigma: 8,
                      borderRadius: BorderRadius.circular(24),
                      glowRadius: 10,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(24),
                          onTap: _toggleMenu,
                          // 长按：直达模型提供方设置页
                          onLongPress: widget.onOpenProvidersSettings,
                          child: AnimatedContainer(
                            // 宽度 = 预测量文字宽 + 间隙 + 图标宽 + 左右 padding（12×2），
                            // 显式动画参数：Flutter 内部平滑过渡，无跳变；
                            // 漏加 padding 会导致内容溢出、> 被裁剪
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.fastOutSlowIn,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            width:
                                _measureModelText() +
                                2 +
                                26 +
                                24 +
                                6, // +6 防测量误差溢出
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // 模型名切换：文字直接切换字形（无动画），
                                // 仅胶囊宽度由 AnimatedContainer 平滑过渡
                                Text(
                                  widget.modelLabel,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                AnimatedRotation(
                                  turns: _modelMenuOpen ? 0.25 : 0,
                                  duration: const Duration(milliseconds: 220),
                                  curve: Curves.easeOutBack, // 非线性：快速转 + 轻微回弹
                                  child: Icon(
                                    Icons.chevron_right_rounded, // 圆角变体：线条更粗
                                    size: 26,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 菜单遮罩
        if (_modelMenuOpen)
          Positioned(
            top: topPad + _headerBodyHeight,
            left: 0,
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeMenu, // 收起动画由 _menuController.reverse() 驱动
              // 空白：仅用作命中区域，不绘制任何内容
              child: const ColoredBox(color: Color(0x00000000)),
            ),
          ),
        // 模型下拉菜单
        Positioned(
          top: topPad + _headerBodyHeight + 4,
          left: 12,
          child: IgnorePointer(
            // 关闭中不响应点击（抽屉全开时由点击关闭遮罩拦截）
            ignoring: !_modelMenuOpen,
            child: SizeTransition(
              // 官方展开/收起组件：axisAlignment -1 = 从顶部向下展开/收起，
              // 内部自带裁剪与布局，动画丝滑
              axis: Axis.vertical,
              alignment: Alignment.topCenter,
              sizeFactor: CurvedAnimation(
                parent: _menuController,
                curve: Curves.fastOutSlowIn,
                reverseCurve: Curves.easeInCubic,
              ),
              child: SizedBox(
                width: 240,
                child: Card(
                  // 背景由内部 BackdropFilter 半透明模糊提供，Card 本体透明
                  color: Colors.transparent,
                  elevation: 3,
                  shadowColor: Colors.black.withValues(alpha: 0.15),
                  // 浅灰细边框（与工具调用块一致）
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: ClipRect(
                    // 毛玻璃：背景模糊 + 半透明底色（亮色白 75% / 暗色 1C1C1E 75%）
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        color: Theme.of(context).brightness == Brightness.dark
                            ? kSheetBgDark.withValues(alpha: 0.75)
                            : Colors.white.withValues(alpha: 0.75),
                        // 一次最多显示 4 项：固定高度 + ListView 滚动，超出部分可滚动
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: 4 * 44 + 3, // 4 项行（44）+ 3 条分割线
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            // 过滤掉当前已选模型
                            itemCount: widget.visibleModels.length,
                            separatorBuilder: (_, _) => Container(
                              height: 1,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  colors: [
                                    Color(0x00000000),
                                    Color(0x33000000),
                                    Color(0x00000000),
                                  ],
                                ),
                              ),
                            ),
                            itemBuilder: (context, i) {
                              final model = widget.visibleModels[i];
                              return InkWell(
                                onTap: () {
                                  widget.onModelSelected(model);
                                  _closeMenu(); // 收起动画由 _menuController.reverse() 驱动
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.modelDisplay(model),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w500,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class GlassIconButton extends StatefulWidget {
  const GlassIconButton({super.key, required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<GlassIconButton> createState() => _GlassIconButtonState();
}

class _GlassIconButtonState extends State<GlassIconButton>
    with SingleTickerProviderStateMixin {
  /// 是否按下（按压缩放反馈）
  bool _pressed = false;

  /// 波纹扩散动画（350ms：放大 + 淡出）
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  /// 波纹起点（按钮内局部坐标）
  Offset _rippleAt = Offset.zero;

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  /// 按下：缩放 + 从点击位置开始波纹扩散
  void _onDown(Offset local) {
    setState(() {
      _pressed = true;
      _rippleAt = local;
    });
    _ripple.forward(from: 0);
  }

  /// 抬起/取消：复位缩放
  void _onUp() {
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = Theme.of(context).colorScheme.onSurface;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _onDown(d.localPosition),
      onTapUp: (_) => _onUp(),
      onTapCancel: () => _onUp(),
      // 动作立即执行（反馈在 State 内持续，不依赖父级重建）
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: SizedBox(
          width: 46,
          height: 38,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 图标（按压缩放 + 切换动画）
              Center(
                child: AnimatedScale(
                  scale: _pressed ? 0.85 : 1.0,
                  duration: const Duration(milliseconds: 120),
                  curve: Curves.easeOut,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: Icon(
                      widget.icon,
                      key: ValueKey(widget.icon),
                      size: 22,
                      color: baseColor,
                    ),
                  ),
                ),
              ),
              // 波纹扩散圆：叠在图标之上（Material 波纹风格，不会被图标盖住）。
              // 半透明扩散渐隐（不遮白）；仅 forward 期间渲染，静止时无残留。
              // 注意：Positioned 必须在 Stack 直接子级——builder 内包一层 Stack
              // 再放 Positioned（直接返回 Positioned 是非法的）
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _ripple,
                  builder: (context, _) {
                    if (_ripple.status != AnimationStatus.forward) {
                      return const SizedBox.shrink();
                    }
                    final t = Curves.easeOut.transform(_ripple.value);
                    // 扩散半径随进度增大（超越按钮边界被圆角裁剪）、透明度渐隐
                    final radius = 6 + 34 * t;
                    return Stack(
                      children: [
                        Positioned(
                          left: _rippleAt.dx - radius,
                          top: _rippleAt.dy - radius,
                          child: Container(
                            width: radius * 2,
                            height: radius * 2,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: baseColor.withValues(alpha: 0.3 * (1 - t)),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 图片全屏查看：黑色背景 + 捏合/双击自由缩放 + 放大后平移 + 点击/按钮关闭。
/// 双击：未放大 → 放大 3 倍；已放大 → 复原。
/// 关键：child 尺寸 = 图片实际显示尺寸（contain 无黑边参与），
/// 放大即图片本体放大，不被原始盒子区域限制
/// 图片全屏查看（photo_view）：黑色背景 + 捏合缩放（最高 8 倍）+
/// 双击缩放（带动画、以点击位置为中心，微信/系统相册风格）+
/// 放大后自由平移（不被图片边界锁死）+ 点按/右上角按钮关闭。
/// 相比手写 InteractiveViewer：缩放动画顺滑、不瞬跳、不卡边界
class _ImageFullscreen extends StatefulWidget {
  const _ImageFullscreen({required this.image});

  /// 复用聊天里的缓存 provider（原图全分辨率，不重复解码）
  final ImageProvider image;

  @override
  State<_ImageFullscreen> createState() => _ImageFullscreenState();
}

class _ImageFullscreenState extends State<_ImageFullscreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: PhotoView(
              imageProvider: widget.image,
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              // 初始 contain（整图可见，无黑边）；放大上限 8 倍
              initialScale: PhotoViewComputedScale.contained,
              minScale: PhotoViewComputedScale.contained,
              maxScale: 8.0,
              basePosition: Alignment.center,
              filterQuality: FilterQuality.medium,
              // 点按关闭（双击缩放由 PhotoView 内置处理，不影响单击）
              onTapUp: (_, _, _) => Navigator.of(context).pop(),
              loadingBuilder: (context, event) => const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
              errorBuilder: (context, error, stackTrace) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 64,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
          // 右上角关闭按钮（状态栏下方）
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: 12,
            child: Material(
              color: Colors.black45,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).pop(),
                child: const Padding(
                  padding: EdgeInsets.all(10),
                  child: Icon(Icons.close, color: Colors.white, size: 20),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 文本类附件扩展名：内容会随消息读取发送（模型可阅读全文）；
/// 其余文件仅把文件名作为附件占位发送
const Set<String> kTextAttachmentExts = {
  'txt',
  'text',
  'md',
  'markdown',
  'json',
  'csv',
  'tsv',
  'log',
  'yaml',
  'yml',
  'xml',
  'html',
  'htm',
  'css',
  'js',
  'jsx',
  'ts',
  'tsx',
  'py',
  'java',
  'c',
  'cpp',
  'h',
  'hpp',
  'cs',
  'go',
  'rs',
  'sh',
  'bat',
  'ps1',
  'ini',
  'conf',
  'toml',
  'env',
  'sql',
  'tex',
  'rst',
  'vtt',
};

/// 附件名是否为文本类（按扩展名判断，忽略大小写）
bool isTextAttachmentName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return kTextAttachmentExts.contains(name.substring(dot + 1).toLowerCase());
}

/// 文本附件读取上限（字节）：超出截断，避免超大文件打爆请求
const int kMaxTextAttachmentBytes = 1000000;

/// 文件大小格式化：B / KB / MB / GB（1 位小数）
String formatFileSize(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(1)} GB';
}

/// 文本 token 估算：汉字按 1 字/token，其余按 4 字符/token
int estimateTokens(String text) {
  var cjk = 0;
  for (final rune in text.runes) {
    if (rune >= 0x4E00 && rune <= 0x9FFF) cjk++;
  }
  final nonCjk = text.length - cjk;
  return cjk + (nonCjk / 4).ceil();
}

/// token 数格式化：≥1000 显示 k（如 12.3k）
String formatTokenCount(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// 内联消息编辑器（llama-ui 风格：text areas + Cancel/Save 按钮行）
/// 助手消息可同时编辑思考内容（thinking）。
/// 用户消息可增删文件（同 llama.cpp 编辑附件）。
/// 预填/保存都经过文字替换规则（显示层 ↔ 模型文本）
/// 控制器在 initState 创建一次、dispose 释放：父级重建（键盘弹出、
/// 上下文占用刷新等）不会重建控制器，光标/选区保持稳定；
/// 初始光标置于文本末尾（打开编辑时不会跳到开头）
class _InlineMessageEditor extends StatefulWidget {
  const _InlineMessageEditor({
    required this.message,
    required this.index,
    required this.isUser,
    required this.replaceRules,
    required this.branchMode,
    required this.onCancel,
    required this.onSave,
    required this.onBranch,
    required this.onPickAttachments,
  });

  final Message message;
  final int index;
  final bool isUser;
  final List<TextReplaceRule> replaceRules;
  final bool branchMode;
  final VoidCallback onCancel;
  final Future<void> Function(
    int index,
    TextEditingController contentCtrl,
    TextEditingController thinkingCtrl, {
    List<MessageFilePart>? fileParts,
    List<ImagePart>? imageParts,
  })
  onSave;
  final void Function(
    int index,
    TextEditingController contentCtrl, {
    List<MessageFilePart>? fileParts,
    List<ImagePart>? imageParts,
  })
  onBranch;
  final Future<void> Function(
    void Function(VoidCallback fn) setEditorState,
    List<MessageFilePart> editFiles,
    List<ImagePart> editImages,
  )
  onPickAttachments;

  @override
  State<_InlineMessageEditor> createState() => _InlineMessageEditorState();
}

class _InlineMessageEditorState extends State<_InlineMessageEditor> {
  late final TextEditingController contentCtrl;
  late final TextEditingController thinkingCtrl;
  late final List<MessageFilePart> editFiles;
  late final List<ImagePart> editImages;

  @override
  void initState() {
    super.initState();
    final rules = widget.replaceRules;
    // 预填当前查看版本的内容与思考（显示文本）
    contentCtrl = TextEditingController(
      text: applyDisplayRules(widget.message.displayContent, rules),
    );
    thinkingCtrl = TextEditingController(
      text: applyDisplayRules(widget.message.displayThinking ?? '', rules),
    );
    // 初始光标置于文本末尾：打开编辑时聚焦不跳到开头
    contentCtrl.selection = TextSelection.collapsed(
      offset: contentCtrl.text.length,
    );
    thinkingCtrl.selection = TextSelection.collapsed(
      offset: thinkingCtrl.text.length,
    );
    // 编辑中文件/图片部件副本（增删不落盘，保存时写回）
    editFiles = [...?widget.message.fileParts];
    editImages = [...?widget.message.imageParts];
  }

  @override
  void dispose() {
    contentCtrl.dispose();
    thinkingCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isUser = widget.isUser;
    final index = widget.index;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            // 编辑态：虚线感（用浅色边框 + 灰底，与 llama-ui 编辑框一致）
            color: Colors.grey.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.onSurface.withValues(alpha: 0.25)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分支模式提示（与编辑共用编辑器，确认后开启分支对话）
              if (widget.branchMode) ...[
                Text(
                  '分支对话：确认后将截断该消息之后的内容并重新生成',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
              ],
              // 用户消息：附件条在消息内容容器顶层（文字输入框上方），
              // 横向滑动，超出部分被容器截断，同 llama-ui
              if (isUser) ...[
                if (editImages.isNotEmpty || editFiles.isNotEmpty) ...[
                  SizedBox(
                    height: 62,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      // 顶部留出缩略图删除按钮的溢出空间（不被裁剪）
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          for (final img in editImages)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: _editImageThumb(
                                context,
                                img,
                                onDelete: () =>
                                    setState(() => editImages.remove(img)),
                              ),
                            ),
                          for (final f in editFiles)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: _editFileChip(
                                context,
                                f,
                                onDelete: () =>
                                    setState(() => editFiles.remove(f)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
              // 助手消息：思考内容在上，回复内容在下
              if (!isUser) ...[
                _inlineField(context, controller: thinkingCtrl, label: '思考内容'),
                const SizedBox(height: 8),
                _inlineField(context, controller: contentCtrl, label: '回复内容'),
              ] else ...[
                _inlineField(context, controller: contentCtrl, label: '消息内容'),
              ],
              // 按钮行（llama-ui：Cancel / Save）：圆形 + 在气泡左下角，
              // 与取消/保存平齐
              const SizedBox(height: 12),
              Row(
                children: [
                  // 圆形 + 添加附件（图片 → 图片部件；文本 → 文件部件）
                  Material(
                    color: Colors.grey.withValues(alpha: 0.15),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => widget.onPickAttachments(
                        setState,
                        editFiles,
                        editImages,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.add,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Cancel（灰底背景，与保存按钮一致）
                  Material(
                    color: Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: widget.onCancel,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.close,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '取消',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Save（分支模式下确认后开启分支对话）
                  Material(
                    color: Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () {
                        if (widget.branchMode) {
                          widget.onBranch(
                            index,
                            contentCtrl,
                            fileParts: editFiles,
                            imageParts: editImages,
                          );
                        } else {
                          widget.onSave(
                            index,
                            contentCtrl,
                            thinkingCtrl,
                            fileParts: editFiles,
                            imageParts: editImages,
                          );
                        }
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.check, size: 16),
                            const SizedBox(width: 8),
                            Text(
                              widget.branchMode ? '保存并分支' : '保存',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 编辑态文件 chip：文件名 + 删除（编辑消息时的文件管理）
Widget _editFileChip(
  BuildContext context,
  MessageFilePart f, {
  required VoidCallback onDelete,
}) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.grey.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.description_outlined,
          size: 14,
          color: scheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            f.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 8),
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onDelete,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(Icons.close, size: 14, color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );
}

/// 编辑态图片缩略图（小方块 + 右上角删除）
Widget _editImageThumb(
  BuildContext context,
  ImagePart img, {
  required VoidCallback onDelete,
}) {
  Uint8List? bytes;
  try {
    final idx = img.dataUrl.indexOf(',');
    if (idx >= 0) bytes = base64Decode(img.dataUrl.substring(idx + 1));
  } catch (_) {}
  return Stack(
    clipBehavior: Clip.none,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: bytes == null
            ? Container(
                width: 48,
                height: 48,
                color: Colors.grey.withValues(alpha: 0.2),
              )
            : Image.memory(bytes, width: 48, height: 48, fit: BoxFit.cover),
      ),
      Positioned(
        top: -6,
        right: -6,
        child: Material(
          color: Colors.black54,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onDelete,
            child: const SizedBox(
              width: 16,
              height: 16,
              child: Icon(Icons.close, size: 11, color: Colors.white),
            ),
          ),
        ),
      ),
    ],
  );
}

/// 内联编辑输入框（灰色圆角，多行）
Widget _inlineField(
  BuildContext context, {
  required TextEditingController controller,
  required String label,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 4),
      TextField(
        controller: controller,
        minLines: 2,
        // 行数上限：超过后字段内部滚动（isDense 已移除，滚动不再截断文字）
        maxLines: 6,
        // 显式文字样式：深色模式下亮字、亮色模式下暗字
        style: Theme.of(context).textTheme.bodyMedium,
        // 文本对齐顶部：多行内容不被紧凑装饰压切
        textAlignVertical: TextAlignVertical.top,
        decoration: InputDecoration(
          filled: true,
          // 深色模式：暗底（避免白底 + 亮字不可见）；亮色模式保持原样
          fillColor: Theme.of(context).brightness == Brightness.dark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.white.withValues(alpha: 0.6),
          // 垂直 padding 归零：滚动内容裁切与背景框边缘完全重合
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 0,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.3),
            ),
          ),
        ),
      ),
    ],
  );
}

/// 提示词模板（一键应用到当前会话的 System 提示词）
class PromptTemplate {
  const PromptTemplate(this.name, this.description, this.prompt);

  final String name;
  final String description;
  final String prompt;
}

/// 内置提示词模板
const List<PromptTemplate> kBuiltinPromptTemplates = [
  PromptTemplate(
    '通用助手',
    '乐于助人、准确可靠的通用 AI 助手',
    '你是一个乐于助人的 AI 助手。回答要准确、清晰、有条理，'
        '不确定时如实说明。',
  ),
  PromptTemplate(
    '代码审查',
    '从正确性、性能、可维护性、安全性审查代码',
    '你是资深代码审查专家。请从正确性、性能、可维护性、安全性等角度'
        '审查代码：先总结整体情况，再逐条列出问题（严重程度 + 原因 + '
        '改进建议 + 示例）。',
  ),
  PromptTemplate(
    '翻译助手',
    '专业翻译，只输出译文',
    '你是专业翻译。将用户输入翻译成目标语言（未指明时中文↔英文），'
        '保持原意、语气与格式，只输出译文，不添加任何解释。',
  ),
  PromptTemplate(
    '中文润色',
    '修正语病、优化表达，保持原意',
    '你是中文写作专家。请润色用户的文字：修正语病、消除冗余、优化'
        '表达与节奏，保持原意不变。输出润色后的完整文本。',
  ),
  PromptTemplate(
    '技术顾问',
    '清晰、准确、结构化地解答技术问题',
    '你是资深技术顾问。用清晰、准确、结构化的方式解答技术问题：先给'
        '结论，再展开原理与步骤；涉及代码时给出可直接使用的示例。',
  ),
  PromptTemplate(
    '英语老师',
    '用中文讲解，帮助学习英语',
    '你是英语老师。用中文讲解帮助用户学习英语：解释语法、词汇与用法，'
        '给出地道例句，指出常见错误，鼓励练习。',
  ),
  PromptTemplate(
    '文案撰写',
    '营销文案专家，吸引人的表达',
    '你是营销文案专家。撰写吸引人的文案：突出卖点与用户价值，语言'
        '简洁有感染力，符合目标受众与场景。',
  ),
  PromptTemplate(
    '心理倾听',
    '善解人意的倾听者，共情回应',
    '你是一个善解人意的倾听者。用共情、温和的方式回应，先理解情绪'
        '再提供支持；不评判、不建议堆砌，必要时温和地提出视角。',
  ),
];

/// 上下文占用圆环画笔：底环 + 进度弧（从 12 点方向顺时针）
class _ContextRingPainter extends CustomPainter {
  _ContextRingPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
  });

  final double progress;
  final Color color;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - 3) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    paint.color = trackColor;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint);
    if (progress > 0) {
      paint.color = color;
      canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * progress, false, paint);
    }
  }

  @override
  bool shouldRepaint(_ContextRingPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor;
}

/// 模型上下文窗口兜底：未设置时按命名默认（DeepSeek 系列 1M，其余 128k）
int defaultContextWindowFor(String modelId) {
  final s = modelId.toLowerCase();
  return s.contains('deepseek') || RegExp(r'(^|[-_])ds([-_]|$)').hasMatch(s)
      ? 1048576
      : 131072;
}

/// 图片文件名判断（扩展名，忽略大小写）
bool isImageFileName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return const {
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp',
    'bmp',
    'heic',
    'heif',
    'svg',
  }.contains(name.substring(dot + 1).toLowerCase());
}
