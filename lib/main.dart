import 'dart:async';
import 'dart:convert'
    show base64Decode, base64Encode, jsonDecode, jsonEncode, utf8;
import 'dart:io'
    show Directory, File, HttpServer, InternetAddress, HttpRequest;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui' show ImageFilter;

import 'package:cupertino_liquid_glass/cupertino_liquid_glass.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show SpringDescription, SpringSimulation;
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as im;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:inspire_blur/inspire_blur.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:screen_corner_radius/screen_corner_radius.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'chat.dart';
import 'doc_extract.dart';
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
/// 蓝灰种子（Blue-Grey）：fromSeed 的 M3 色调映射会把它映射到蓝灰 primary，
/// 加载转圈/光标等主题色不再是绿色
const Color kBrandColorLight = Color(0xFF455A64);

/// 用户消息气泡专用蓝（仅气泡，不参与全局主题种子）
const Color kUserBubbleColor = Color(0xFF3D5AFE);
const Color kBrandColorDark = Color(0xFF90A4AE);

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
  // 全局解码图片缓存限额（默认 1000 张/100MB 过大）：
  // 100 张 / 48MB——超出按 LRU 自动淘汰
  PaintingBinding.instance.imageCache
    ..maximumSize = 100
    ..maximumSizeBytes = 48 << 20;
  // 后台接收回复：前台服务（生成期间启动保活——系统冻结后台进程
  // 是切后台后流式中断的根源；服务挂常驻通知"正在接收回复"）
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'llm_chat_stream',
      channelName: '后台接收回复',
      channelDescription: '生成回复期间保持运行',
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      allowWifiLock: true,
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
    ),
  );
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

class _HomePageState extends State<HomePage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
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

  /// 思考深度状态（四档）：0 none / 1 low / 2 high / 3 max
  int _thinkingDepth = 0;

  /// 渲染纪元：影响消息显示但不在消息对象里的全局状态变化时自增
  /// （思考深度/渲染开关/替换规则/分支拓扑切换）——消息项签名计入，
  /// 变化即全列表失效缓存，杜绝「设置改了界面不动」类漏洞
  int _renderEpoch = 0;

  // ── 系统 TTS（朗读助手消息）──
  FlutterTts? _tts;

  /// 正在朗读的消息对象（null = 空闲）；同屏仅一条在播
  Message? _speakingMsg;

  /// 引擎可用（设备无 TTS 引擎时按钮置灰）
  bool _ttsReady = false;

  /// 懒初始化系统 TTS 引擎（首次点喇叭时）。
  /// 部分设备（如小米 mibrain）首帧初始化报 -1（瞬态失败）——
  /// 显式指定引擎 + 短暂重试；语言逐级回退（zh-CN → zh → 默认）
  Future<void> _initTts() async {
    if (_tts != null) return;
    final t = FlutterTts();
    try {
      // 语言逐级回退（zh-CN → zh）；探测失败也继续用默认语言
      await t.setLanguage('zh-CN');
      await t.setSpeechRate(0.5);
      t.setStartHandler(() {
        if (mounted) setState(() {}); // 播放态由 _speakingMsg 驱动
      });
      t.setCompletionHandler(() {
        _speakingMsg = null;
        if (mounted) setState(() {});
      });
      t.setErrorHandler((msg) {
        _speakingMsg = null;
        if (mounted) setState(() {});
      });
      // cancel/stop 也结束朗读态
      t.setCancelHandler(() {
        _speakingMsg = null;
        if (mounted) setState(() {});
      });
      _ttsReady = true;
      _tts = t;
    } catch (_) {
      _ttsReady = false;
      // init -1 常为瞬态：短暂等待后重试一次（重试仍失败则放弃本次）
      await Future.delayed(const Duration(milliseconds: 600));
      try {
        await t.setLanguage('zh-CN');
        _ttsReady = true;
      } catch (_) {
        _ttsReady = false;
      }
    }
    if (mounted) setState(() {});
  }

  /// 朗读/停止切换：同一条再点 = 停止；新消息点 = 换朗读对象
  Future<void> _toggleSpeak(Message m) async {
    await _initTts();
    final t = _tts;
    if (t == null || !_ttsReady) {
      _toast('设备无可用语音引擎');
      return;
    }
    if (identical(_speakingMsg, m)) {
      await t.stop();
      _speakingMsg = null;
      if (mounted) setState(() {});
      return;
    }
    // 在线 API 优先（配置了就云端合成；本机引擎多不可用）
    if (_general.ttsUseApi && _general.ttsBaseUrl.trim().isNotEmpty) {
      await _speakViaApi(m);
      return;
    }
    // 切换朗读对象：先停旧的
    await t.stop();
    final text = applyDisplayRules(m.content, _replaceRules).trim();
    // 长文截断：系统 TTS 队列过长易卡，3000 字足够听
    final speakText = text.length > 3000
        ? '${text.substring(0, 3000)}……'
        : text;
    if (speakText.isEmpty) return;
    setState(() => _speakingMsg = m);
    await t.speak(speakText);
  }

  /// 停止朗读（切换会话/删除消息等场景调用）
  Future<void> _stopSpeaking() async {
    if (_speakingMsg == null) return;
    _speakingMsg = null;
    _speakSession++; // 伪流式管道整体失效（在途合成/播放全部作废）
    await _tts?.stop();
    await _audioPlayer?.stop();
    if (mounted) setState(() {});
  }

  // ── 在线语音 API（OpenAI 兼容 /audio/speech；系统 TTS 引擎在
  // 部分国产 ROM 上不给第三方绑定，这是主朗读方案）──
  AudioPlayer? _audioPlayer;

  /// 朗读会话号：每次开始/停止自增——旧的分段管道据此自杀
  int _speakSession = 0;

  /// 伪流式朗读（Kimi 思路）：文本按语义切段，逐段合成 + 播放当前段时
  /// 预取下一段——首段几百毫秒即出声，段间几乎无感衔接。
  /// [_speakSession] 会话号：停止/切消息时自增使旧管道整体失效
  Future<void> _speakViaApi(Message m) async {
    final g = _general;
    if (g.ttsBaseUrl.trim().isEmpty) {
      _toast('未配置语音 API 地址（设置 → 语音朗读）');
      return;
    }
    final text = applyDisplayRules(m.content, _replaceRules).trim();
    if (text.isEmpty) return;
    final segs = _splitForTts(text, maxTotal: 3000);
    if (segs.isEmpty) return;
    final session = ++_speakSession;
    setState(() => _speakingMsg = m);
    final player = _audioPlayer ??= AudioPlayer();
    await player.stop();
    try {
      // 预取第 0 段；播放第 i 段期间预取第 i+1 段（流水线）
      var prefetch = _synthSegment(segs[0]);
      for (var i = 0; i < segs.length; i++) {
        if (session != _speakSession) return;
        final bytes = await prefetch;
        if (session != _speakSession) return;
        if (i + 1 < segs.length) {
          prefetch = _synthSegment(segs[i + 1]);
        }
        await player.setAudioSource(_BytesAudioSource(bytes));
        // play() 的 Future 在本段播完时完成（衔接下一段）
        await player.play();
      }
    } catch (e) {
      if (session == _speakSession) {
        _toast('语音合成失败：$e');
      }
    } finally {
      if (session == _speakSession) {
        _speakingMsg = null;
        if (mounted) setState(() {});
      }
    }
  }

  /// 合成一小段（OpenAI 兼容 /audio/speech → MP3 字节）
  Future<Uint8List> _synthSegment(String seg) async {
    final g = _general;
    final resp = await http
        .post(
          Uri.parse(g.ttsBaseUrl.trim()),
          headers: {
            'Authorization': 'Bearer ${g.ttsApiKey.trim()}',
            'content-type': 'application/json',
            'accept': 'audio/mpeg',
          },
          body: jsonEncode({
            if (g.ttsModel.trim().isNotEmpty) 'model': g.ttsModel.trim(),
            'input': seg,
            if (g.ttsVoice.trim().isNotEmpty) 'voice': g.ttsVoice.trim(),
            'response_format': 'mp3',
            'speed': g.ttsSpeed,
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  /// TTS 分段：换行/强标点（。！？；）优先断句，短句向后聚合到
  /// 足够长度（避免每句一请求的开销与顿挫），超长句在软标点回退切。
  /// 语义边界断开——不在词中间割裂
  List<String> _splitForTts(
    String text, {
    int minLen = 24,
    int maxTotal = 3000,
  }) {
    final out = <String>[];
    var buf = '';
    var total = 0;
    void flush() {
      final t = buf.trim();
      if (t.isNotEmpty && total < maxTotal) {
        out.add(t);
        total += t.length;
      }
      buf = '';
    }

    void addSentence(String s) {
      // 超长句（无强标点的长文本）：按软标点/空格回退切
      if (s.length > 120) {
        var rest = s;
        while (rest.length > 120) {
          var cut = rest.lastIndexOf(RegExp(r'[，,、　 ]'), 120);
          if (cut < 40) cut = 120;
          flush();
          out.add(rest.substring(0, cut).trim());
          total += cut;
          rest = rest.substring(cut);
        }
        buf = rest;
        flush();
        return;
      }
      buf += s;
      // 攒够最小段长（强标点结尾）→ 成段
      if (buf.length >= minLen && RegExp(r'[。！？!?；;]$').hasMatch(buf.trim())) {
        flush();
      }
    }

    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) {
        flush();
        continue;
      }
      for (final sent in line.split(RegExp(r'(?<=[。！？!?；;])'))) {
        addSentence(sent);
      }
      flush(); // 行末强制成段
    }
    flush();
    return out;
  }

  /// 页眉模型选择：当前模型名（裸 id，来自设置页提供方，默认无）
  String _modelName = '';

  /// 当前模型的归属提供方名（与 [_modelName] 合成模型唯一身份）
  String _currentProviderName = '';

  /// 当前模型复合键（provider + id 的编码串；空 = 未选模型）
  String get _currentKey => _modelName.isEmpty
      ? ''
      : _encodeModelKey(_currentProviderName, _modelName);

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
        if (m.id == k.id &&
            m.displayName != null &&
            m.displayName!.isNotEmpty) {
          return m.displayName!;
        }
      }
    }
    final dup =
        _modelIndex.keys.where((x) => _decodeModelKey(x)?.id == k.id).length >
        1;
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

  /// send_image 暂存图片：响应结束时统一挂到最终回答消息
  ///（与工具中间轮隔离）
  final List<ImagePart> _pendingToolImages = [];

  /// 正在后台加载的会话 id（非 null 时消息区显示居中转圈，
  /// 加载完成一次性贴上内容——首建长帧不落在抽屉动画里）
  String? _loadingConvId;

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

  /// 上滑快捷导航（ChatBox 式）。两类触发：
  /// · 回到底部：离开底部 >320px 持续显示，贴回隐藏（滞回）
  /// · 回到顶部/上一条消息：仅【快速上滑】（>1.2px/ms 向上）时浮现，
  ///   2.2s 静止自动隐去
  final ValueNotifier<bool> _awayFromBottom = ValueNotifier(false);

  /// 用户消息的布局锚点（GlobalKey，惰性创建）：上一条消息跳转的
  /// 真实位置精修用——纯比例估算在消息高度不均时偏差大（会跳到顶）
  final Map<Message, GlobalKey> _userMsgKeys = {};
  final ValueNotifier<bool> _fastNavVisible = ValueNotifier(false);
  Timer? _fastNavTimer;
  double _qnLastPixels = 0;
  DateTime _qnLastTs = DateTime.now();

  bool _onScrollNotification(ScrollNotification n) {
    if (n.depth == 0 &&
        (n is ScrollUpdateNotification || n is ScrollEndNotification)) {
      // 滞回：远离底部 >320px 显示；贴回底部 <60px 隐藏
      final ext = n.metrics.extentAfter;
      final away = _awayFromBottom.value;
      if (!away && ext > 320) {
        _awayFromBottom.value = true;
      } else if (away && ext < 60) {
        _awayFromBottom.value = false;
      }
    }
    // 快速上滑检测（向上 + 高速）→ 顶部/上一条按钮浮现
    if (n.depth == 0 && n is ScrollUpdateNotification) {
      final now = DateTime.now();
      final dt = now.difference(_qnLastTs).inMicroseconds;
      if (dt > 0) {
        final d = n.metrics.pixels - _qnLastPixels;
        final speed = d.abs() / (dt / 1000);
        if (d < 0 && speed > 1.2 && n.metrics.pixels > 60) {
          if (!_fastNavVisible.value) _fastNavVisible.value = true;
          _fastNavTimer?.cancel();
          _fastNavTimer = Timer(const Duration(milliseconds: 2200), () {
            _fastNavVisible.value = false;
          });
        } else if (n.metrics.pixels <= 60 && _fastNavVisible.value) {
          // 已到顶部：向上箭头失去意义，立即隐藏
          _fastNavTimer?.cancel();
          _fastNavVisible.value = false;
        }
      }
      _qnLastPixels = n.metrics.pixels;
      _qnLastTs = now;
    }
    return false;
  }

  /// 动画滚动到指定偏移（回到顶部/底部/上一条都用，420ms easeOutCubic）
  void _animatedJumpTo(double offset) {
    if (!_chatScroll.hasClients) return;
    final pos = _chatScroll.position;
    _chatScroll.animateTo(
      offset.clamp(pos.minScrollExtent, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  /// 当前可视位置最近的问题（用户消息索引）；-1 = 在第一个问题之前
  int _currentUserMsgIndex() {
    if (!_chatScroll.hasClients) return -1;
    final msgs = _currentConversation?.messages;
    if (msgs == null || msgs.isEmpty) return -1;
    final pos = _chatScroll.position;
    final f = (pos.pixels / math.max(1.0, pos.maxScrollExtent)).clamp(
      0.0,
      1.0,
    );
    final est = (f * (msgs.length - 1)).round().clamp(0, msgs.length - 1);
    var cur = -1;
    for (var i = 0; i < msgs.length; i++) {
      if (msgs[i].role != Role.user) continue;
      if (i <= est) {
        cur = i;
      } else {
        break;
      }
    }
    return cur;
  }

  /// 跳到上一条用户消息（没有更早的 → 顶部）
  void _jumpToPrevUserMessage() {
    final msgs = _currentConversation?.messages;
    if (msgs == null || msgs.isEmpty || !_chatScroll.hasClients) return;
    final cur = _currentUserMsgIndex();
    var target = -1;
    for (var i = (cur < 0 ? msgs.length - 1 : cur - 1); i >= 0; i--) {
      if (msgs[i].role == Role.user) {
        target = i;
        break;
      }
    }
    if (target < 0) {
      _animatedJumpTo(0);
      return;
    }
    final m = msgs[target];
    // 一阶段：比例估算拉近（把目标带进构建范围）
    final f = target / math.max(1, msgs.length - 1);
    _chatScroll.jumpTo(
      (f * _chatScroll.position.maxScrollExtent).clamp(
        _chatScroll.position.minScrollExtent,
        _chatScroll.position.maxScrollExtent,
      ),
    );
    // 二阶段：下一帧目标已构建 → 用真实布局位置精修（ensureVisible
    // 平滑滚到，问题停在视口 15% 处）；估算偏差大时以此为准
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _userMsgKeys[m]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.15,
        );
      }
    });
  }



  ChatStore? _store;

  /// 当前会话的 system 提示词（会话级，新建对话不继承）
  String? get _prompt => _currentConversation?.systemPrompt;

  /// 内联编辑中的消息索引（null = 无；llama-ui 风格原地编辑）
  Message? _editingMsg;

  /// 分支编辑中的用户消息索引（null = 无）。
  /// 与编辑共用内联编辑器，但确认后截断该消息之后的内容并重新生成（开启分支对话）
  Message? _branchMsg;

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
    // 图片编码任务（循环收集，循环后一次 isolate 批量编码）
    final imgJobs = <Object?>[];
    final nameParts = <String>[];
    for (final att in _attachments) {
      if (att.loading) continue; // 压缩占位不进消息
      if (!att.isImage) {
        // PDF：多模态模型 + 「PDF 转图」开启 → 渲染成图（模型直接看
        // 版面/图表）；否则提取文本层（扫描版无文本层 → 文件名占位）
        if (att.name.toLowerCase().endsWith('.pdf')) {
          if (_general.pdfAsImage && _modelSupportsMultimodal) {
            try {
              final parts = await _pdfToImages(att);
              if (parts.isNotEmpty) {
                imageParts.addAll(parts);
                continue;
              }
            } catch (_) {}
          }
          try {
            final (text, truncated) = await _pdfToText(att);
            if (text.trim().isNotEmpty) {
              fileParts.add(
                MessageFilePart(
                  name: att.name,
                  size: att.size ?? 0,
                  content: text,
                  truncated: truncated,
                ),
              );
              if (truncated) _toast('${att.name} 内容较长，已截断');
              continue;
            }
          } catch (_) {}
          nameParts.add(att.name);
          continue;
        }
        // Office 文档（docx/xlsx/pptx）：本地解包提取文本（compute
        // 隔离，Cherry Studio/ChatBox 同方案——OpenAI 兼容端点没有
        // 文件上传 API，只能文本注入）；解析失败 → 文件名占位
        if (isDocAttachmentName(att.name)) {
          try {
            final bytes = await att.readBytes();
            if (bytes.isNotEmpty) {
              final (content, truncated) = await parseDocumentAttachment(
                att.name,
                bytes,
              );
              fileParts.add(
                MessageFilePart(
                  name: att.name,
                  size: att.size ?? 0,
                  content: content,
                  truncated: truncated,
                ),
              );
              if (truncated) _toast('${att.name} 内容较长，已截断');
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
        // 双档压缩全部走原生（C 实现，快且稳——此前 compute 里的纯
        // Dart 解码对部分图抛异常 → catch 降级成文本附件
        // 「[附件: img_xxx.jpg]」，即图片变文本的根源）：
        // AI 档 = 1568px/80；前端档 = 320px/60。
        // base64 编码统一收集到循环外一次 compute 批量做（多图 MB 级
        // 编码不占主线程）
        final aiBytes = await compressSingleImageNative(
          bytes,
          maxSide: _imgMaxSide,
          quality: _imgQuality,
        );
        if (aiBytes.isEmpty) {
          // 压缩失败（原生 + Dart 回退都解不了，如 HEIC 变体）：
          // 走兜底路径，不能把空/伪 jpeg 发给端点
          throw StateError('image compress failed');
        }
        // 前端小图：从 AI 档再缩（原生，快）
        Uint8List thumbBytes;
        try {
          thumbBytes = await FlutterImageCompress.compressWithList(
            aiBytes,
            minWidth: 320,
            minHeight: 320,
            quality: 60,
            format: CompressFormat.jpeg,
          );
        } catch (_) {
          thumbBytes = aiBytes;
        }
        imgJobs.add(att.name);
        imgJobs.add(aiBytes);
        imgJobs.add(thumbBytes);
        imgJobs.add('image/jpeg'); // 原生压缩输出恒为 JPEG
      } catch (_) {
        // 兜底：原生压缩失败——仅端点支持的格式（webp/png/jpeg/gif）
        // 原图直传；其余（heic/bmp 等）直发会被整单 400，降级文件名
        // 占位并提示
        try {
          final bytes = await att.readBytes();
          if (bytes.isNotEmpty) {
            final mime = _mimeFromName(att.name);
            const supported = {'image/webp', 'image/png', 'image/jpeg', 'image/gif'};
            if (supported.contains(mime)) {
              imgJobs.add(att.name);
              imgJobs.add(bytes);
              imgJobs.add(null);
              imgJobs.add(mime);
              continue;
            }
            _toast('${att.name} 格式不受模型支持（HEIC 等），请转换为 JPG 后重试');
          }
        } catch (_) {}
        nameParts.add(att.name);
      }
    }
    // 批量 base64（isolate）：AI 档 + 前端缩略
    if (imgJobs.isNotEmpty) {
      final jobs = <(String, Uint8List)>[];
      final names = <String>[];
      final mimes = <String>[];
      // 定长 4 槽协议：name / AI 档字节 / 缩略字节(可空) / mime。
      //（此前按"第 4 项是否字符串"猜变长边界，多图时会把下一张图的
      // 文件名当成本张的 MIME = data:photo2.jpg → 端点 400，单图正常）
      var i = 0;
      while (i + 3 < imgJobs.length) {
        final name = imgJobs[i] as String;
        final ai = imgJobs[i + 1] as Uint8List;
        final thumb = imgJobs[i + 2] as Uint8List?;
        final mime = imgJobs[i + 3] as String;
        names.add(name);
        mimes.add(mime);
        jobs.add((mime, ai));
        jobs.add((mime, thumb ?? ai)); // 无缩略：显示兜底用 AI 档
        i += 4;
      }
      final urls = await compute(_bytesToDataUrls, jobs);
      for (var k = 0; k < names.length; k++) {
        imageParts.add(
          ImagePart(
            name: names[k],
            mimeType: mimes[k],
            dataUrl: urls[k * 2],
            thumbUrl: urls[k * 2 + 1],
          ),
        );
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
      final names = <String>[];
      final pngs = <Uint8List>[];
      final count = math.min(doc.pages.length, 10);
      for (var i = 0; i < count; i++) {
        // 渲染宽 1024（高度按页面比例自动）
        final img = await doc.pages[i].render(width: 1024);
        if (img == null) continue;
        try {
          final raster = await img.createImage();
          final data = await raster.toByteData(format: ui.ImageByteFormat.png);
          if (data != null) {
            names.add('${att.name} 第${i + 1}页');
            pngs.add(data.buffer.asUint8List());
          }
        } finally {
          img.dispose();
        }
      }
      // 整页 PNG（1-2MB/页 ×10）base64 编码放 isolate
      if (pngs.isEmpty) return const <ImagePart>[];
      final urls = await compute(
        _bytesToDataUrls,
        [for (final b in pngs) ('image/png', b)],
      );
      return [
        for (var i = 0; i < names.length; i++)
          ImagePart(
            name: names[i],
            mimeType: 'image/png',
            dataUrl: urls[i],
          ),
      ];
    } finally {
      doc.dispose();
    }
  }

  /// 将 PDF 附件提取为文本（pdfrx 文本层，最多前 50 页，超长截断）。
  /// pdfium 对象不能跨 isolate，主 isolate 执行（常规文档速度可接受）；
  /// 扫描版 PDF 无文本层 → 返回空串，由调用方降级为文件名占位
  Future<(String, bool)> _pdfToText(_Attachment att) async {
    final p = att.path;
    if (p == null || p.isEmpty) return ('', false);
    final doc = await PdfDocument.openFile(p);
    try {
      final count = math.min(doc.pages.length, 50);
      final sb = StringBuffer();
      for (var i = 0; i < count; i++) {
        final t = await doc.pages[i].loadText();
        sb.writeln(t.fullText);
        if (sb.length > kMaxDocExtractChars) break;
      }
      var text = sb.toString().trim();
      var truncated = false;
      if (text.length > kMaxDocExtractChars) {
        text = text.substring(0, kMaxDocExtractChars);
        truncated = true;
      }
      return (text, truncated);
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
  static const kBuiltinPythonTool = 'builtin__run_python';
  static const kBuiltinSendImageTool = 'builtin__send_image';
  static const kBuiltinReadWebTool = 'builtin__read_webpage';

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
        // 读网页：联网能力，与搜索同一开关
        if (_general.builtinSearchEnabled) _builtinToolDefs[5],
        // 查看图片：仅多模态模型（图片作为视觉输入）
        if (_general.builtinSearchEnabled && _modelSupportsMultimodal)
          _builtinToolDefs[6],
        if (_general.builtinPythonEnabled) _builtinToolDefs[3],
        // 发图工具依赖 Python 内核产文件，同一开关
        if (_general.builtinPythonEnabled) _builtinToolDefs[4],
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
  /// - 运行 Python（本地 Pyodide 沙箱，支持 matplotlib 产图）
  /// - 发送图片给用户（读取 Python 保存的文件，显示在聊天气泡）
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
    {
      'type': 'function',
      'function': {
        'name': kBuiltinPythonTool,
        'description':
            '在设备本地沙箱中运行 Python 代码（Pyodide，含 numpy/pandas/matplotlib/'
            'scipy/sympy 等科学计算包，无需网络即可用）。代码的 stdout 输出和最后 '
            '表达式结果会返回给你。变量在多次调用间保留。'
            '注意：生成的图表不会自动展示给用户——需要用户看到图片时，'
            '先把图保存为文件（如 plt.savefig("out.png", dpi=110)），'
            '再调用 send_image 工具发送。',
        'parameters': {
          'type': 'object',
          'properties': {
            'code': {
              'type': 'string',
              'description': '要执行的完整 Python 代码（可直接运行的完整脚本）',
            },
          },
          'required': ['code'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': kBuiltinSendImageTool,
        'description':
            '把一张图片发送给用户（显示在聊天中）。图片来源：① run_python '
            '生成并保存的图片文件（如 plt.savefig("out.png")）；② 网页里的'
            '图片地址（read_webpage 返回的 URL，path 直接传 URL 即可）。'
            '当用户要你画图/生成图片/输出图像、或要把网页里的图片给用户'
            '看时调用。每次发送一张，多张图多次调用。',
        'parameters': {
          'type': 'object',
          'properties': {
            'path': {
              'type': 'string',
              'description': 'Python 里保存的图片文件路径（如 out.png）',
            },
            'caption': {
              'type': 'string',
              'description': '图片说明（可选，简短一句话）',
            },
          },
          'required': ['path'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': kBuiltinReadWebTool,
        'description':
            '读取一个网页的正文内容（文章/文档/博客等）。返回提取后的'
            '文本（优先正文，去除导航/脚本等噪音，上限约 2 万字符）。'
            '当用户给出链接让你看、总结、翻译网页，或搜索结果需要打开'
            '某个网页深入了解时调用。',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {'type': 'string', 'description': '要读取的网页地址'},
          },
          'required': ['url'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': kBuiltinViewImageTool,
        'description':
            '查看一张图片：把图片作为视觉输入提供给你（你可以直接看到'
            '图片内容）。来源可以是网页里的图片地址（read_webpage 返回的'
            ' URL），也可以是 run_python 保存的图片文件路径。需要识别/'
            '理解图片内容时调用。',
        'parameters': {
          'type': 'object',
          'properties': {
            'url': {
              'type': 'string',
              'description': '图片地址（http/https）或 Python 保存的文件路径',
            },
          },
          'required': ['url'],
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

  // ──────────────────────────────────────────────────────────────
  // Python 执行内核（Pyodide in WebView，本地环回 HTTP 服务）
  //
  // appassets 协议给 .js 返回 application/octet-stream，Pyodide 的
  // 动态 import() 因 MIME 不合法拒绝加载——改由 127.0.0.1 环回
  // HttpServer 以正确 MIME 提供 assets/pyodide/ 预捆绑运行时与
  // kernel 页面；未捆绑的包文件（numpy 等由 loadPackagesFromImports
  // 按需拉取）回源 jsdelivr CDN 并落盘缓存，二次使用零流量
  // ──────────────────────────────────────────────────────────────
  HttpServer? _pyServer;
  WebViewController? _pyKernel;
  Future<void>? _pyKernelBoot;
  int _nextPyId = 1;
  final Map<int, Completer<({String text, List<String> images})>> _pyPending =
      {};

  static const Map<String, String> _pyMimes = {
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.wasm': 'application/wasm',
    '.zip': 'application/zip',
    '.json': 'application/json; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.data': 'application/octet-stream',
    '.whl': 'application/octet-stream',
  };

  Future<void> _ensurePyServer() async {
    if (_pyServer != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _pyServer = server;
    server.listen((req) async {
      await _pyServeAsset(req);
    });
  }

  Future<void> _pyServeAsset(HttpRequest req) async {
    try {
      var path = req.uri.path;
      if (path == '/' || path == '/kernel.html') path = '/python_kernel.html';
      if (path.contains('..')) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      // 1. 预捆绑资产（核心运行时 + kernel 页）：本地即时返回
      try {
        final data = await rootBundle.load('assets$path');
        _pyReply(req, data.buffer.asUint8List(
            data.offsetInBytes, data.lengthInBytes), path);
        return;
      } catch (_) {}
      // 2. 磁盘缓存（此前回源过的包文件）
      final cacheDir = Directory(
        '${(await getApplicationDocumentsDirectory()).path}/pyodide_cache',
      );
      final cached = File('${cacheDir.path}$path');
      if (await cached.exists()) {
        _pyReply(req, await cached.readAsBytes(), path);
        return;
      }
      // 3. 回源 CDN（仅 /pyodide/ 下的包文件）→ 落盘缓存。
      // 多 CDN 依次尝试：jsdelivr 主站在国内常不可达（大包 numpy/
      // matplotlib 超时、小包偶发成功），fastly/gcore 镜像是国内
      // 常用替代；单 CDN 60s 超时（大包十几 MB，慢网需要余量），
      // 成功即落盘，二次使用零流量
      if (path.startsWith('/pyodide/')) {
        const cdns = [
          'https://cdn.jsdelivr.net/pyodide/v0.28.3/full',
          'https://fastly.jsdelivr.net/pyodide/v0.28.3/full',
          'https://gcore.jsdelivr.net/pyodide/v0.28.3/full',
        ];
        final sub = path.substring('/pyodide'.length);
        for (final cdn in cdns) {
          try {
            final res = await http
                .get(Uri.parse('$cdn$sub'))
                .timeout(const Duration(seconds: 60));
            if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
              await cached.create(recursive: true);
              await cached.writeAsBytes(res.bodyBytes, flush: true);
              _pyReply(req, res.bodyBytes, path);
              return;
            }
          } catch (_) {}
        }
      }
      req.response.statusCode = 404;
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = 404;
        await req.response.close();
      } catch (_) {}
    }
  }

  void _pyReply(HttpRequest req, List<int> bytes, String path) {
    final dot = path.lastIndexOf('.');
    req.response.headers.set(
      'Content-Type',
      dot < 0 ? 'application/octet-stream' : (_pyMimes[path.substring(dot)] ?? 'application/octet-stream'),
    );
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.add(bytes);
    req.response.close();
  }

  /// 启动（或复用）隐藏 WebView 中的 Python 内核。Pyodide 运行时
  /// 在首次 runPython 时才真正加载（冷启动约 10 秒），页面就绪即可。
  /// 失败时清空引导锁，下次调用重试
  Future<void> _ensurePyKernel() => _pyKernelBoot ??= () async {
    try {
      await _ensurePyServer();
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('pyDone', onMessageReceived: (m) {
          Map<String, dynamic> j;
          try {
            j = jsonDecode(m.message) as Map<String, dynamic>;
          } catch (_) {
            return;
          }
          final done = _pyPending.remove(j['id'] as int? ?? -1);
          if (done == null || done.isCompleted) return;
          final ok = j['ok'] as bool? ?? false;
          final aborted = j['aborted'] as bool? ?? false;
          final out = (j['stdout'] as String? ?? '').trimRight();
          final err = (j['stderr'] as String? ?? '').trimRight();
          final res = (j['result'] as String? ?? '').trimRight();
          final error = (j['error'] as String? ?? '').trim();
          // matplotlib 图：kernel 回传裸 base64（PNG）
          final imgs = (j['images'] as List? ?? const [])
              .whereType<String>()
              .toList();
          var text = <String>[
            if (out.isNotEmpty) out,
            if (res.isNotEmpty) '[结果] $res',
            if (err.isNotEmpty) '[stderr] $err',
            if (!ok && error.isNotEmpty) '[错误] $error',
            if (aborted) '[已中止]',
          ].join('\n');
          if (imgs.isNotEmpty) {
            text +=
                '${text.isEmpty ? '' : '\n'}[已生成 ${imgs.length} 张图表；'
                '要展示给用户请先 plt.savefig 保存，再调 send_image 发送]';
          }
          if (text.isEmpty) text = '(无输出)';
          done.complete((text: text, images: imgs));
        });
      // 先挂树（setState → 隐藏 WebViewWidget 进入 Stack，渲染出原生
      // 视图），再加载页面——未挂树直接 load 会静默不执行
      _pyKernel = c;
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await c.loadRequest(
        Uri.parse('http://127.0.0.1:${_pyServer!.port}/kernel.html'),
      );
      // 等页面脚本就绪（最多 15 秒；runPython 定义即回 true）
      for (var i = 0; i < 150; i++) {
        try {
          final r = await c.runJavaScriptReturningResult(
            'typeof runPython === "function"',
          );
          if (r.toString() == 'true') break;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } catch (_) {
      // 引导失败：允许下次重试
      _pyKernelBoot = null;
      _pyKernel = null;
      rethrow;
    }
  }();

  /// 执行 Python 代码：内核就绪 → 注入代码 → 等 pyDone 回传。
  /// 内部 105s 超时（外层调度 120s 兜底），超时经 __pyAbort 中断
  Future<({String text, List<String> images})> _runPythonCode(
    String code,
  ) async {
    await _ensurePyKernel();
    final k = _pyKernel;
    if (k == null) {
      return (text: 'Python 内核未就绪', images: const <String>[]);
    }
    final id = _nextPyId++;
    final done = Completer<({String text, List<String> images})>();
    _pyPending[id] = done;
    try {
      // jsonEncode 产出合法 JS 字符串字面量（转义引号/换行/反斜杠）
      await k.runJavaScript('runPython($id, ${jsonEncode(code)})');
      return await done.future.timeout(
        const Duration(seconds: 105),
        onTimeout: () {
          _pyPending.remove(id);
          try {
            k.runJavaScript('window.__pyAbort && window.__pyAbort($id)');
          } catch (_) {}
          return (
            text: 'Python 执行超时（105 秒），已中止；死循环代码请加合理出口',
            images: const <String>[],
          );
        },
      );
    } catch (e) {
      _pyPending.remove(id);
      if (!done.isCompleted) {
        done.complete((text: 'Python 内核错误：$e', images: const <String>[]));
      }
      return (text: 'Python 内核错误：$e', images: const <String>[]);
    }
  }

  /// 发图工具：读 Pyodide 虚拟文件系统里的图片文件（模型先用
  /// run_python 保存，如 plt.savefig）→ 暂存 _pendingToolImages，
  /// 响应结束时统一挂到【最后一轮正式输出】的消息上（与其余工具
  /// 的中间轮隔离——图片永远伴随最终回答出现）；
  /// 返回给模型的确认文本（成功以 [图片已发送 开头）
  Future<String> _sendImageTool(String path, {String caption = ''}) async {
    final p = path.trim();
    if (p.isEmpty) return '[发送失败：path 参数为空]';
    // http(s) URL：直接下载（网页图片发送）
    if (p.startsWith('http://') || p.startsWith('https://')) {
      try {
        final res = await http
            .get(Uri.parse(p))
            .timeout(const Duration(seconds: 15));
        final ct =
            (res.headers['content-type'] ?? '').split(';').first.trim();
        if (res.statusCode == 200 &&
            ct.startsWith('image/') &&
            res.bodyBytes.isNotEmpty &&
            res.bodyBytes.length <= 8 << 20) {
          final b64 = base64Encode(res.bodyBytes);
          _pendingToolImages.add(
            ImagePart(
              name: p.split('/').last.split('?').first,
              mimeType: ct,
              dataUrl: 'data:$ct;base64,$b64',
            ),
          );
          final kb = (res.bodyBytes.length / 1024).round();
          return '[图片已发送给用户：$p（$kb KB）'
              '${caption.isEmpty ? '' : '，说明：$caption'}]';
        }
        return '[发送失败：URL 不是有效图片（$p，类型 $ct）]';
      } catch (e) {
        return '[发送失败：$e]';
      }
    }
    try {
      await _ensurePyKernel();
      final k = _pyKernel;
      if (k == null) return '[发送失败：Python 内核未就绪]';
      final r = await k.runJavaScriptReturningResult(
        'window.readPyFile ? window.readPyFile(${jsonEncode(p)}) : ""',
      );
      var b64 = r.toString();
      // Android 侧返回带引号的字符串字面量
      if (b64.length >= 2 && b64.startsWith('"') && b64.endsWith('"')) {
        b64 = b64.substring(1, b64.length - 1);
      }
      if (b64.isEmpty) {
        return '[发送失败：文件不存在（$p）。请先用 run_python 保存图片，'
            '例如 plt.savefig("$p", dpi=110)]';
      }
      // 大小用 base64 长度估算（×3/4）——主线程解码 8MB 是卡顿源
      final estBytes = b64.length * 3 ~/ 4;
      if (estBytes > 8 << 20) return '[发送失败：图片超过 8MB，请压缩后重试]';
      if (estBytes == 0) return '[发送失败：文件为空]';
      final mime = _mimeFromName(p);
      final name = p.split('/').last;
      _pendingToolImages.add(
        ImagePart(
          name: name,
          mimeType: mime,
          dataUrl: 'data:$mime;base64,$b64',
        ),
      );
      final kb = (estBytes / 1024).round();
      return '[图片已发送给用户：$name（$kb KB）'
          '${caption.isEmpty ? '' : '，说明：$caption'}]';
    } catch (e) {
      return '[发送失败：$e]';
    }
  }

  /// 本地网页阅读器：隐藏 WebView（Python 内核同款宿主方式）。
  /// 渲染 JS 页面后取 innerText（可见文本，质量优于对原始 HTML 的
  /// 正则提取）；完全本地，不把网址发给第三方
  WebViewController? _webReader;

  Future<void> _ensureWebReader() async {
    if (_webReader != null) return;
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
      );
    _webReader = c;
    if (mounted) setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  /// WebView 渲染读取：load → 等 readyState complete → 取 innerText。
  /// 返回 null 表示失败（调用方降级）
  Future<({String title, String text, List<String> images})?> _readViaWebView(
    String url,
  ) async {
    try {
      await _ensureWebReader();
      final k = _webReader!;
      await k.loadRequest(Uri.parse(url));
      // 最多等 25s 至加载完成
      var ready = false;
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          final r = await k.runJavaScriptReturningResult('document.readyState');
          var v = r.toString();
          if (v.length >= 2 && v.startsWith('"')) v = v.substring(1, v.length - 1);
          if (v == 'complete') {
            ready = true;
            break;
          }
        } catch (_) {}
      }
      if (!ready) return null;
      // JS 渲染余量（骨架屏二次填充）
      await Future<void>.delayed(const Duration(milliseconds: 800));
      const js = r'''
(function(){
  try {
    var el = document.querySelector('article')
      || document.querySelector('main')
      || document.body;
    var text = (el ? (el.innerText || '') : '');
    if (text.length > 30000) text = text.slice(0, 30000);
    var imgs = [];
    var seen = {};
    var all = document.querySelectorAll('img');
    for (var k = 0; k < all.length && imgs.length < 8; k++) {
      var im = all[k];
      var u = im.currentSrc || im.src || '';
      if (!u || seen[u] || u.indexOf('http') !== 0) continue;
      var w = im.naturalWidth || im.width || 0;
      var h = im.naturalHeight || im.height || 0;
      if (w >= 200 && h >= 150) { seen[u] = 1; imgs.push(u); }
    }
    return JSON.stringify({ t: document.title || '', c: text, i: imgs });
  } catch (e) { return '{}'; }
})()
''';
      final raw = await k.runJavaScriptReturningResult(js);
      var str = raw.toString();
      if (str.length >= 2 && str.startsWith('"') && str.endsWith('"')) {
        // evaluateJavascript 返回 JSON 字符串字面量：去引号
        str = str.substring(1, str.length - 1);
      }
      final j = jsonDecode(str) as Map<String, dynamic>;
      final title = (j['t'] as String? ?? '').trim();
      final text = (j['c'] as String? ?? '').trim();
      if (text.isEmpty) return null;
      final imgs = (j['i'] as List? ?? const [])
          .whereType<String>()
          .toList();
      return (title: title, text: text, images: imgs);
    } catch (_) {
      return null;
    }
  }

  static const kBuiltinViewImageTool = 'builtin__view_image';

  /// 下载网页图片（并行，单张 ≤2MB、image/*）→ data URL 列表
  Future<List<String>> _downloadWebImages(List<String> urls) async {
    final out = await Future.wait(
      urls.take(6).map((u) async {
        try {
          final res = await http
              .get(Uri.parse(u))
              .timeout(const Duration(seconds: 12));
          final ct = (res.headers['content-type'] ?? '').split(';').first.trim();
          if (res.statusCode == 200 &&
              ct.startsWith('image/') &&
              res.bodyBytes.isNotEmpty &&
              res.bodyBytes.length <= 2 << 20) {
            return (ct, res.bodyBytes);
          }
        } catch (_) {}
        return null;
      }),
    );
    final jobs = out.whereType<(String, Uint8List)>().toList();
    if (jobs.isEmpty) return const <String>[];
    // base64 编码放 isolate（6×2MB 编码不占主线程）
    return compute(_bytesToDataUrls, jobs);
  }

  /// view_image：取图片（http(s) URL 下载，或 Pyodide 文件）→ dataUrl
  ///（给 tool 消息做视觉输入用）。失败返回 null
  Future<String?> _fetchImageForView(String urlOrPath) async {
    final p = urlOrPath.trim();
    if (p.isEmpty) return null;
    try {
      if (p.startsWith('http://') || p.startsWith('https://')) {
        final res = await http
            .get(Uri.parse(p))
            .timeout(const Duration(seconds: 15));
        final ct =
            (res.headers['content-type'] ?? '').split(';').first.trim();
        if (res.statusCode == 200 &&
            ct.startsWith('image/') &&
            res.bodyBytes.isNotEmpty &&
            res.bodyBytes.length <= 4 << 20) {
          return 'data:$ct;base64,${base64Encode(res.bodyBytes)}';
        }
        return null;
      }
      // Pyodide 文件（run_python 保存的图）
      await _ensurePyKernel();
      final k = _pyKernel;
      if (k == null) return null;
      final r = await k.runJavaScriptReturningResult(
        'window.readPyFile ? window.readPyFile(' +
            jsonEncode(p) +
            ') : ""',
      );
      var b64 = r.toString();
      if (b64.length >= 2 && b64.startsWith('"') && b64.endsWith('"')) {
        b64 = b64.substring(1, b64.length - 1);
      }
      if (b64.isEmpty) return null;
      final mime = _mimeFromName(p);
      return 'data:$mime;base64,$b64';
    } catch (_) {
      return null;
    }
  }

  /// 网页正文读取上限（字符）
  static const int _kMaxWebChars = 20000;

  /// 读网页（builtin__read_webpage）：Jina Reader 优先（服务端渲染 +
  /// 正文提取，返回干净的 Markdown——Cherry Studio 等客户端的默认方案），
  /// 失败回退本地抓取 + HTML 正文提取（compute 隔离，隐私不外发）。
  /// 返回给模型的文本；失败以 [读取失败 开头（调度侧据此判败）
  /// 读网页：返回 (给模型的文本, 网页图片 URL 列表)。
  /// 两级本地链路（不发第三方）：直接抓取+提取（快，静态页一步
  /// 到位，正则收集 img src）→ 本地 WebView 渲染（JS 页面，取
  /// innerText + JS 过滤收集图片）。失败以 [读取失败 开头
  Future<({String text, List<String> images})> _readWebpage(String url) async {
    var target = url.trim();
    if (target.isEmpty) {
      return (text: '[读取失败：url 为空]', images: const <String>[]);
    }
    if (!target.startsWith('http://') && !target.startsWith('https://')) {
      target = 'https://$target';
    }
    const ua = {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Mobile Safari/537.36',
      'Accept': 'text/html,application/xhtml+xml,text/plain,*/*',
    };
    String cap(String t) => t.length > _kMaxWebChars
        ? '${t.substring(0, _kMaxWebChars)}\n…[内容过长，已截断至 $_kMaxWebChars 字符]'
        : t;
    // 1) 直接抓取 + 本地提取（纯静态页一步到位）
    try {
      final res = await http
          .get(Uri.parse(target), headers: ua)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && res.bodyBytes.length <= 3 << 20) {
        final ct = (res.headers['content-type'] ?? '').toLowerCase();
        final raw = utf8.decode(res.bodyBytes, allowMalformed: true);
        final looksHtml =
            ct.contains('html') ||
            RegExp(
              r'<html|<!doctype',
              caseSensitive: false,
            ).hasMatch(raw.substring(0, raw.length.clamp(0, 2000)));
        if (!looksHtml) {
          // 纯文本类（json/xml/plain）直接返回
          return (
            text: '网页内容（$target）：\n${cap(raw.trim())}',
            images: const <String>[],
          );
        }
        final (title, body) = await compute(_extractWebHtml, raw);
        if (body.trim().length >= 500) {
          // 静态页图片：正则收集 article 段 img src（绝对化）
          final base = Uri.parse(target);
          final imgs = <String>[];
          for (final m in RegExp(r'<img[^>]+src="([^"]+)"').allMatches(raw)) {
            final src = m.group(1)!;
            if (src.startsWith('data:')) continue;
            final abs = base.resolve(src).toString();
            if (abs.startsWith('http') && !imgs.contains(abs)) imgs.add(abs);
            if (imgs.length >= 8) break;
          }
          return (
            text:
                '网页内容（$target，本地提取）：'
                '\n标题：$title'
                '\n${cap(body)}',
            images: imgs,
          );
        }
        // 提取过少（疑似 JS 渲染壳）→ 落到 WebView
      }
    } catch (_) {}
    // 2) 本地 WebView 渲染读取（JS 页面；完全本地）
    final wv = await _readViaWebView(target);
    if (wv != null && wv.text.trim().isNotEmpty) {
      return (
        text:
            '网页内容（$target，本地渲染）：'
            '${wv.title.isEmpty ? '' : '\n标题：${wv.title}'}'
            '\n${cap(wv.text)}',
        images: wv.images,
      );
    }
    return (
      text: '[读取失败：无法获取 $target 的内容（本地抓取与渲染均未得到正文）]',
      images: const <String>[],
    );
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
    // 仅用户图片进载荷（同 LlmService._contentPayload）：助手图片是
    // send_image 工具发给用户看的，回传会被端点 400
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
      _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
        _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
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
        // 连接中断自动重连（最多 5 次）：清本轮半截输出后重发同请求
        for (var retries = 0;; retries++) {
        try {
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
        } catch (e) {
          if (_isConnectionDrop(e) && retries < 5 && mounted && !_stopRequested) {
            await Future<void>.delayed(
              Duration(milliseconds: 500 + (retries + 1) * 400),
            );
            if (!mounted || _stopRequested) rethrow;
            // 清本轮半截输出，重发同请求
            _flushStreamBufferNow();
            setState(() {
              current
                ..content = ''
                ..thinking = null;
              _renderEpoch++;
            });
            _streamBufContent = '';
            _streamBufThinking = '';
            acc.clear();
            roundFinish = '';
            pendingCalls.clear();
            continue;
          }
          rethrow;
        }
        break; // 本轮流正常结束
        } // for retries

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
          // 内置工具名剥离 builtin__ 前缀。send_image 出静默卡片：
          // 不渲染（图片直接挂气泡），但标记该轮为工具轮——
          // 否则该轮 toolCalls 为空会被当普通消息显示工具栏，
          // 与最终回答的工具栏叠出两个
          final toolDef = toolMap[call.name];
          final displayName = call.name.startsWith('builtin__')
              ? call.name.substring('builtin__'.length)
              : (toolDef?.$2.name ?? call.name);
          final card = ToolCallRecord(
            name: displayName,
            query: _summarizeArgs(call.args),
            silent: call.name == kBuiltinSendImageTool,
          );
          setState(() => current.toolCalls!.add(card));

          // 执行工具：内置工具走本地执行，MCP 工具走远程调用
          String resultText;
          int resultCode;
          // view_image 的视觉输入（非空时 tool 消息 content 用多模态数组）
          String? viewImageDataUrl;
          try {
            if (call.name.startsWith('builtin__')) {
              final args = _parseArgs(call.args);
              if (call.name == kBuiltinPythonTool) {
                // Python：code 参数（兼容 query 槽位），120s 整体超时
                //（含首次 WASM 内核启动 ~10s 与自动装包）；产图挂卡片
                final r = await _runPythonCode(
                  (args['code'] as String?) ??
                      (args['query'] as String?) ??
                      '',
                ).timeout(
                  const Duration(seconds: 120),
                  onTimeout: () => (
                    text: 'Python 执行超时（120 秒，含内核启动/装包），已中止',
                    images: const <String>[],
                  ),
                );
                resultText = r.text.isEmpty ? '(空结果)' : r.text;
                card.output = resultText.length > 4000
                    ? '${resultText.substring(0, 4000)}…'
                    : resultText;
                // 图表不再挂卡片（与 send_image 发出的图重复）：
                // 需要用户看到时模型应 savefig + send_image
                card.images = null;
                resultCode = resultText.length;
              } else if (call.name == kBuiltinSendImageTool) {
                // 发图给用户：读 Python 保存的文件 → 挂到本条助手消息
                // 的 imageParts（聊天气泡显示）；60s 超时兜底
                final r = await _sendImageTool(
                  (args['path'] as String?) ?? '',
                  caption: (args['caption'] as String?) ?? '',
                ).timeout(
                  const Duration(seconds: 60),
                  onTimeout: () => '读取图片超时（60 秒），请重试',
                );
                resultText = r;
                resultCode = resultText.startsWith('[图片已发送') ? 1 : -1;
              } else if (call.name == kBuiltinReadWebTool) {
                // 读网页（本地两级链路）；60s 网络超时
                final r = await _readWebpage(
                  (args['url'] as String?) ?? (args['query'] as String?) ?? '',
                ).timeout(
                  const Duration(seconds: 60),
                  onTimeout: () => (
                    text: '[读取超时（60 秒），请稍后重试]',
                    images: const <String>[],
                  ),
                );
                resultText = r.text;
                if (r.images.isNotEmpty) {
                  // 图片 URL 列表告知模型（view_image 查看 / send_image 发送）
                  resultText +=
                      '\n[网页图片 ${r.images.length} 张，可用 view_image(url) 查看或 '
                      'send_image(path=url) 发送给用户：${r.images.take(8).join(' ')}]';
                  // 下载进工具卡（点开即可看）
                  final dl = await _downloadWebImages(r.images);
                  if (dl.isNotEmpty) card.images = dl;
                }
                card.output = resultText.length > 4000
                    ? '${resultText.substring(0, 4000)}…'
                    : resultText;
                resultCode = resultText.startsWith('[读取失败') ||
                        resultText.startsWith('[读取超时')
                    ? -1
                    : resultText.length;
              } else if (call.name == kBuiltinViewImageTool) {
                // 查看图片：下载 → 作为视觉输入注入 tool 消息
                final du = await _fetchImageForView(
                  (args['url'] as String?) ?? (args['path'] as String?) ?? '',
                ).timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => null,
                );
                if (du == null) {
                  resultText = '[查看失败：无法获取图片（URL 无效/超时/非图片）]';
                  resultCode = -1;
                } else {
                  viewImageDataUrl = du;
                  resultText = '[图片已提供给你查看，见本条工具消息的图片内容]';
                  resultCode = 1;
                }
                card.output = resultText;
              } else {
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
              }
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
            // view_image：图片作为视觉输入（content 多模态数组，
            // 兼容接受 image_url 的端点；纯文本模型不注册本工具）
            'content': viewImageDataUrl != null
                ? [
                    {'type': 'text', 'text': resultText},
                    {
                      'type': 'image_url',
                      'image_url': {'url': viewImageDataUrl},
                    },
                  ]
                : resultText,
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
          // 步进收纳：新一轮开气泡 = 上一轮不再是最后一条消息，
          // 立即收纳。epoch 让上一轮的缓存气泡失效刷新
          _renderEpoch++;
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
    _pendingToolImages.clear();
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
    _startStreamService();
    _scrollToBottom();

    // 模型名：跟随页眉下拉选择，直接发给服务器（测试服务为局域网模型）
    // 思考深度不再切换模型名，仅作为 UI 偏好——模型返回 reasoning_content 时显示思考块
    final model = _modelName;
    // system 提示词：会话级优先；未设置时用通用设置里的默认提示词
    //（默认提示词也为空 = 不发送）。思考深度不注入任何提示词，
    // 只通过请求参数控制（chat_template_kwargs / thinking / effort）
    final convPrompt = (conv.systemPrompt ?? '').trim();
    final finalPrompt = convPrompt.isNotEmpty
        ? convPrompt
        : _general.defaultSystemPrompt.trim();
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
      // 连接中断类错误自动重连（最多 5 次）：重试前清掉半截输出，
      // 新流从头填充，避免内容重复
      var retries = 0;
      void start() {
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
              onError: (e) async {
                if (_isConnectionDrop(e) && retries < 5 && mounted) {
                  retries++;
                  await Future<void>.delayed(
                    Duration(milliseconds: 500 + retries * 400),
                  );
                  if (!mounted || _stopRequested) {
                    _onRespondError(conv, assistantMsg, e);
                    return;
                  }
                  // 清半截输出与缓冲，重开流
                  _flushStreamBufferNow();
                  setState(() {
                  assistantMsg
                    ..content = ''
                    ..thinking = null;
                  _renderEpoch++;
                  });
                  _streamBufContent = '';
                  _streamBufThinking = '';
                  _lastTruncated = false;
                  start();
                  return;
                }
                _flushStreamBufferNow();
                _onRespondError(conv, assistantMsg, e);
              },
              cancelOnError: true,
            );
      }

      start();
    } catch (e) {
      _onRespondError(conv, assistantMsg, e);
    }
  }

  /// 连接中断类错误（可自动重连）：接收中断/连接重置/断管等。
  /// HTTP 4xx/5xx（鉴权/额度/服务端拒绝）不在此列
  bool _isConnectionDrop(Object e) {
    final t = e.toString();
    return e is http.ClientException ||
        t.contains('Connection closed') ||
        t.contains('Connection reset') ||
        t.contains('Broken pipe') ||
        t.contains('Software caused connection abort') ||
        t.contains('Connection terminated');
  }

  /// ── 流式节流：token 级 delta 合并到 ~30fps 才 setState。
  /// 整页 rebuild 是流式期间最大开销（此前每 token 一次）；
  /// 视觉无感知（~33ms 一帧），长回复 CPU/掉帧大幅下降。
  /// [_lastStreamFlushMs] 首帧为 0 → 首个 delta 立即上屏 ──
  String _streamBufThinking = '';
  String _streamBufContent = '';
  Timer? _streamFlushTimer;
  Message? _streamMsg;

  /// 流式帧通知：流式期间每 33ms 只 tick 一次，消息项各自比对签名
  /// 决定是否自刷新——HomePage 整树 build 不再逐帧执行
  ///（抽屉/页眉/输入栏等全部静态部分的重建是流式掉帧的大头）
  final ValueNotifier<int> _streamTick = ValueNotifier(0);
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
    // 直接改消息字段 + tick：各消息项监听 tick 比对签名自刷新，
    // 只有正在流式的那条重建（HomePage 零重建）
    if (t.isNotEmpty) msg.thinking = (msg.thinking ?? '') + t;
    if (c.isNotEmpty) msg.content += c;
    _streamTick.value++;
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
    final victim = conv.messages[index];
    setState(() {
      conv.messages.removeAt(index);
      // 该条正在编辑/分支编辑则一并退出（identity 判定）
      if (identical(_editingMsg, victim)) _editingMsg = null;
      if (identical(_branchMsg, victim)) _branchMsg = null;
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
        _editingMsg = null;
      });
      _persist(conv);
      return;
    }
    setState(() {
      _editingSystem = true;
      _editingMsg = null;
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
    // send_image 暂存图片：统一挂到最终输出消息（伴随正式回答）
    if (_pendingToolImages.isNotEmpty) {
      assistantMsg.imageParts = [
        ...?assistantMsg.imageParts,
        ..._pendingToolImages,
      ];
      _pendingToolImages.clear();
    }
    // 完全无内容（正文/思考/工具卡片/图片全空）的助手消息：删除，不留空气泡
    // （模型空回答 / ReAct 最终轮无输出等场景）
    if (assistantMsg.content.trim().isEmpty &&
        (assistantMsg.thinking?.trim().isEmpty ?? true) &&
        (assistantMsg.toolCalls?.isEmpty ?? true) &&
        (assistantMsg.imageParts?.isEmpty ?? true)) {
      setState(() {
        conv.messages.remove(assistantMsg);
        _isResponding = false;
      _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
        _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
        conv.updatedAt = DateTime.now();
      });
      await _persist(conv);
      return;
    }
    _stopStreamService();
    setState(() {
      _isResponding = false;
      _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
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
    // send_image 暂存图片：错误轮也保留（挂到错误消息上）
    if (_pendingToolImages.isNotEmpty) {
      assistantMsg.imageParts = [
        ...?assistantMsg.imageParts,
        ..._pendingToolImages,
      ];
      _pendingToolImages.clear();
    }
    _stopStreamService();
    if (!mounted) return;
    setState(() {
      _isResponding = false;
      _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
      assistantMsg
        ..content = '请求失败：$e'
        ..error = true;
    });
    await _persist(conv);
  }

  /// 停止流式（保留已收部分）。若停止时助手消息完全为空
  /// （还在思考/工具调用阶段，content 与 thinking 都没收到），删除该空气泡。
  /// ReAct 循环用 await-for 无法 cancel，置标志位由循环自行中断清理
  /// 生成期间前台服务：常驻通知保活（后台/息屏流式不断）
  Future<void> _startStreamService() async {
    if (await FlutterForegroundTask.isRunningService) return;
    await FlutterForegroundTask.startService(
      notificationTitle: 'LLM_Chat',
      notificationText: '正在接收回复…',
      serviceTypes: [ForegroundServiceTypes.dataSync],
    );
  }

  Future<void> _stopStreamService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  void _onStop() {
    _streamSub?.cancel();
    _stopStreamService();
    if (_isReactRunning) {
      _stopRequested = true;
      return;
    }
    final conv = _currentConversation;
    if (conv == null || conv.messages.isEmpty) {
      setState(() {
        _isResponding = false;
        _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding
      });
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
      _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
        _renderEpoch++; // 响应结束：工具轮折叠态依赖 _isResponding（不在签名内，需全局失效）
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
              if (_modelName.isNotEmpty &&
                  !_modelIndex.containsKey(_currentKey)) {
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
            _renderEpoch++;
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
            _renderEpoch++;
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

  /// 输入栏容器【动画中】的逐帧高度（_SizeReporter 布局回调上报；
  /// 仅附件条跟随用——列表留白/空状态仍用 _inputBarTop 的目标值）
  final ValueNotifier<double> _inputBarAnimatedTop = ValueNotifier(64);

  /// CustomScrollView center 锚点 key（消息列表顶部锚定）
  final GlobalKey _listCenterKey = GlobalKey();

  /// 选择图片（系统相册多选）。不带压缩参数——插件内建 resize 在
  /// Android Photo Picker 路径不生效/部分路径生效时也在返回前同步
  /// 逐张全尺寸解码（选大量图期间白屏的根源）。原图直接交给
  /// _compressAndAddImages 的 isolate 管道逐张压缩落盘
  Future<void> _pickImages() async {
    final picked = await ImagePicker().pickMultiImage();
    if (!mounted) return;
    Navigator.of(context).pop(); // 先关面板（压缩后台逐张进行）
    if (picked.isNotEmpty) {
      await _compressAndAddImages(picked.map((f) => f.path).toList());
    }
  }

  /// 图片规范化参数：限制最长边 1600 + 质量 80——image_picker 会
  /// 重新编码并把 EXIF 旋转烘焙进像素（模型端不解 EXIF，原图直传
  /// 竖拍会横躺）；相机/图库统一走这套。1600/80 对多模态识别足够，
  /// 且大幅降低多图时的内存峰值（选图解码位图 + base64 副本链）
  static const _imgMaxSide = 1568.0;
  static const _imgQuality = 80;

  /// 拍照（相机）：拍一张作为图片附件（与图片入口同链路同规格）
  Future<void> _takePhoto() async {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera);
    if (!mounted) return;
    Navigator.of(context).pop(); // 关面板后后台落盘
    if (shot != null) {
      await _compressAndAddImages([shot.path]);
    }
  }

  /// 选图后立即逐张落盘暂存（附件条持有压缩后的临时小文件副本）：
  /// 把 N 张原图同时驻留内存的峰值，平摊为逐张处理；
  /// 逐张追加到附件条，用户能看到进度
  Future<void> _compressAndAddImages(List<String> paths) async {
    final dir = await getTemporaryDirectory();
    final imgDir = Directory('${dir.path}/img_cache');
    if (!imgDir.existsSync()) imgDir.createSync(recursive: true);
    // 先铺满占位卡片（与选中数量一致）：用户立即看到全部格子转圈，
    // 而非空白等待——每张压缩完成后原位替换为真实缩略图
    final base = _attachments.length;
    setState(() {
      _attachments.addAll(
        paths
            .map(
              (p) => const _Attachment(
                isImage: true,
                name: 'loading',
                loading: true,
              ),
            )
            .toList(),
      );
    });
    for (var i = 0; i < paths.length; i++) {
      try {
        // 压缩在 isolate 逐张完成（原图 → 1568px/80 小文件）：
        // UI 线程全程零解码、零编码
        final raw = await File(paths[i]).readAsBytes();
        final compressed = await compressSingleImageNative(
          raw,
          maxSide: _imgMaxSide,
          quality: _imgQuality,
        );
        final name =
            'img_${DateTime.now().microsecondsSinceEpoch}_'
            '${paths[i].hashCode.abs()}.jpg';
        final dest = File('${imgDir.path}/$name');
        await dest.writeAsBytes(compressed, flush: true);
        if (!mounted) return;
        final idx = base + i;
        if (idx < _attachments.length) {
          setState(() {
            _attachments[idx] = _Attachment(
              isImage: true,
              name: name,
              path: dest.path,
            );
          });
        }
        // 帧间隔：让刚替换的缩略图有机会渲染
        await Future<void>.delayed(const Duration(milliseconds: 80));
      } catch (_) {
        // 单张失败：移除对应占位（不阻塞其余图片）
        if (mounted) {
          final idx = base + i;
          if (idx < _attachments.length) {
            setState(() => _attachments.removeAt(idx));
          }
        }
      }
    }
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
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 主题切换：消息项签名缓存不感知 Theme——不失效的话气泡里
    // 混着旧主题的颜色（浅色/深色混合的根源）
    if (oldWidget.isDark != widget.isDark) {
      _renderEpoch++;
    }
  }

  @override
  void initState() {
    super.initState();
    // 内存压力响应：系统内存紧张时清各级缓存
    WidgetsBinding.instance.addObserver(this);
    // 输入栏顶边高度变化（多行增高/收起）反映在列表 padding → 布局 →
    // ChatScrollPosition.correctForNewDimensions 统一处理（贴底/上翻补偿），
    // 无需额外监听器
    _warmUpDrawerShaders();
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
        // 索引壳：毫秒级（此前 loadAll×2 全量解析所有正文两遍）
        final allConvs = s.loadAll();
        _conversations = allConvs.where((c) => !c.archived).toList();
        // 归档会话列表（设置页归档管理直接用，零延迟进入）
        _archivedConversations = allConvs.where((c) => c.archived).toList()
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

  /// 按需加载会话完整正文：打开会话时把列表中的元数据壳替换为
  /// 完整对象。isolate 读文件 + 解析（带图会话几 MB 的 JSON 在
  /// 主线程同步解析卡顿数百毫秒——切对话卡顿的根源）；
  /// 防重入：同壳只加载一次。返回加载出的完整会话
  Conversation? _materializing;
  Future<Conversation?> _materialize(Conversation shell) async {
    if (shell.loaded) return shell;
    final store = _store;
    if (store == null) return null;
    if (identical(_materializing, shell)) return null;
    _materializing = shell;
    final full = await store.loadConversationAsync(shell.id);
    _materializing = null;
    if (full == null) return null;
    final i = _conversations.indexWhere((c) => c.id == shell.id);
    if (i >= 0 && mounted) {
      setState(() => _conversations[i] = full);
    }
    return full;
  }

  /// 连续点击不同会话时的防竞态标记：只应用最后一次点击的换入
  String? _openingConvId;

  /// 打开历史会话（抽屉列表点击）。时序与动画解耦：
  /// 1. 抽屉收起动画立即开始（纯动画，无重负载）
  /// 2. isolate 加载正文（后台）
  /// 3. 两者都完成后再一次性 setState 换入——消息列表首建是长帧
  ///    （几十个气泡 + markdown），避开动画窗口执行就不会掉帧；
  ///    期间页面保持旧会话内容，无空页转圈等待
  Future<void> _openConversation(Conversation c) async {
    _stopSpeaking();
    _springDrawerTo(0.0);
    if (c.loaded) {
      // 已物化：无重负载，直接切换
      setState(() {
        _currentId = c.id;
        _historyLongPressed = null;
      });
      _scrollToBottom();
      return;
    }
    _openingConvId = c.id;
    // 消息区立即转圈（后台 isolate 加载，主线程无负载），
    // 加载完成且抽屉动画完全结束后一次性贴上内容——
    // 列表首建的长帧不落在动画窗口里（动画卡顿的根源）
    setState(() => _loadingConvId = c.id);
    final full = await _materialize(c);
    if (!mounted || full == null || _openingConvId != c.id) {
      if (mounted && _openingConvId == c.id) {
        setState(() => _loadingConvId = null);
      }
      return;
    }
    // 等抽屉完全收起（转圈期间无感知延迟）
    if (_drawerController.isAnimating) {
      final ready = Completer<void>();
      void listener() {
        if (!_drawerController.isAnimating) {
          _drawerController.removeListener(listener);
          if (!ready.isCompleted) ready.complete();
        }
      }
      _drawerController.addListener(listener);
      await ready.future;
    }
    // 让出一帧再贴上：长帧发生在静止的转圈画面上
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _openingConvId != c.id) return;
    setState(() {
      _loadingConvId = null;
      _historyLongPressed = null;
      _currentId = c.id;
    });
    _scrollToBottom();
  }

  /// 设置页归档管理改动后：重载会话列表（恢复/删除归档对话）
  void _onArchivedChanged() {
    final store = _store;
    if (store == null) return;
    setState(() {
      final all = store.loadAll();
      _conversations = all.where((c) => !c.archived).toList();
      _archivedConversations = all.where((c) => c.archived).toList()
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

  /// 系统内存紧张（onTrimMemory / lowMemory）：释放三层缓存——
  /// 解码图片、消息图片 provider、显示层规则文本；数据本体
  /// （会话/消息）不受影响，需要时按需重建
  /// 抽屉动画 shader 预热：首帧后把控制器推到 ε 再归零——
  /// 离屏编译平移/裁剪/渐变合成的 shader 管线（Impeller 首次
  /// 执行新管线组合时的编译卡顿 = 首次开抽屉掉帧）
  void _warmUpDrawerShaders() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _drawerController.value = 0.001;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _drawerController.value = 0;
      });
    });
  }

  @override
  void didHaveMemoryPressure() {
    PaintingBinding.instance.imageCache.clear();
    _imageCache.clear();
    _imageCacheBytes = 0;
    _displayCache.clear();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamTick.dispose();
    _fastNavTimer?.cancel();
    _fastNavVisible.dispose();
    _awayFromBottom.dispose();
    _inputBarAnimatedTop.dispose();
    _tts?.stop();
    _streamSub?.cancel();
    _maintainTimer?.cancel();
    _chatScroll.dispose();
    _drawerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Insets 物理上限截断（小窗/悬浮窗防御）：MIUI 小窗会把
    // viewInsets/padding 上报为异常大的残留值（如全屏键盘高度），
    // 把列表、页眉、空状态整体推出视口——只剩不受 insets 影响的
    // 输入栏。真实键盘不会超过窗口高 60%，状态栏不超过 8%，
    // 手势条不超过 5%，按此截断
    final winH = MediaQuery.sizeOf(context).height;
    final topPad = math.min(MediaQuery.paddingOf(context).top, winH * 0.08);
    final bottomPad = math.min(
      MediaQuery.paddingOf(context).bottom,
      winH * 0.05,
    );
    // 输入栏随键盘升起（主界面不动）
    final keyboardInset = math.min(
      MediaQuery.viewInsetsOf(context).bottom,
      winH * 0.6,
    );
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
    final listView = _loadingConvId != null
        ? Center(
            child: SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
          )
        : NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: CustomScrollView(
        controller: _chatScroll,
        center: _listCenterKey, // 锚点：消息列表顶部
        // anchor 显式 0：锚点对齐视口顶（默认 0.5 是视口中心——
        // 小窗/悬浮窗模式视口小，锚点前空 sliver 的布局会把内容
        // 推到视口外导致「不显示对话内容」）
        anchor: 0.0,
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
                // _MessageItem：参数化组件——流式期间 HomePage setState
                // 触发列表重建时，静态消息项的构造参数完全相同，
                // Flutter 按参数相等跳过其子树 rebuild（此前每次 setState
                // 全列表所有气泡都重新 build，是流式滚动卡顿的大头）
                return _MessageItem(
                  key: m.role == Role.user
                      ? (_userMsgKeys.putIfAbsent(m, () => GlobalKey()))
                      : null,
                  message: m,
                  index: msgIndex,
                  editing: identical(_editingMsg, m),
                  branchEditing: identical(_branchMsg, m),
                  streaming:
                      _isResponding &&
                      m.role != Role.user &&
                      msgIndex == messages.length - 1,
                  epoch: _renderEpoch,
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
            if (messages.isEmpty && !showSystem && _loadingConvId == null)
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
                    onTap: () => _springDrawerTo(0.0),
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
            onTakePhoto: _takePhoto,
            onAddFile: _pickFiles,
            containerTopNotifier: _inputBarTop,
            animatedTopNotifier: _inputBarAnimatedTop,
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
              setState(() {
                _thinkingDepth = depth;
                _renderEpoch++;
              });
              _store?.saveThinkingDepth(depth);
            },
            modelSupportsMultimodal: _modelSupportsMultimodal,
            modelSupportsTools: _modelSupportsTools,
            modelSupportsThinking: _modelSupportsThinking,
            hasAttachments: _attachments.isNotEmpty,
            attachmentsAllLoading:
                _attachments.isNotEmpty && _attachments.every((a) => a.loading),
          ),
        ),
        // ── 上滑快捷导航（ChatBox 式，竖排；通用设置可关）──
        // 回到底部：离开底部持续显示；回到顶部/上一条：快速上滑
        // 才浮现（2.2s 隐去）。底部实时跟随输入栏真实高度
        //（_inputBarAnimatedTop = SizeReporter 逐帧上报，防干涉）
        if (_general.quickNavEnabled)
        Positioned(
          right: 12,
          bottom: keyboardInset,
          child: ValueListenableBuilder<double>(
            valueListenable: _inputBarAnimatedTop,
            builder: (context, inputTop, _) => Padding(
              padding: EdgeInsets.only(bottom: inputTop + 40),
              child: ValueListenableBuilder<bool>(
                valueListenable: _fastNavVisible,
                builder: (context, fast, _) => ValueListenableBuilder<bool>(
                  valueListenable: _awayFromBottom,
                  builder: (context, away, _) {
                    final showFast = fast && away;
                    return AnimatedScale(
                      scale: away ? 1.0 : 0.5,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: away ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 160),
                        child: IgnorePointer(
                          ignoring: !away,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 回到顶部 / 上一条：快速上滑浮现、
                              // 定时消失——FAB 菜单式交错缩放：以各自
                              // 底部中心为原点缩放 + 淡入，下一条先出、
                              // 回到顶部跟上（消失反向），不裁切玻璃
                              TweenAnimationBuilder<double>(
                                tween: Tween(end: showFast ? 1.0 : 0.0),
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                builder: (context, t, _) {
                                  Widget staggered(
                                    double a,
                                    IconData icon,
                                    String tooltip,
                                    VoidCallback onTap,
                                  ) {
                                    final v = a.clamp(0.0, 1.0);
                                    return Opacity(
                                      opacity: v,
                                      child: Transform.scale(
                                        scale: 0.4 + 0.6 * v,
                                        alignment: Alignment.bottomCenter,
                                        child: _glassNavBtn(
                                          icon: icon,
                                          tooltip: tooltip,
                                          onTap: onTap,
                                        ),
                                      ),
                                    );
                                  }

                                  return IgnorePointer(
                                    ignoring: t < 0.5,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        // 回到顶部（上方，稍后出现）
                                        staggered(
                                          (t - 0.18) * 1.6,
                                          Icons.vertical_align_top,
                                          '回到顶部',
                                          () => _animatedJumpTo(0),
                                        ),
                                        const SizedBox(height: 10),
                                        // 上一条消息（下方，先出现）
                                        staggered(
                                          t * 1.6,
                                          Icons.keyboard_double_arrow_up,
                                          '上一条消息',
                                          _jumpToPrevUserMessage,
                                        ),
                                        const SizedBox(height: 10),
                                      ],
                                    ),
                                  );
                                },
                              ),
                              // 回到底部：离开底部持续显示
                              _glassNavBtn(
                                icon: Icons.keyboard_double_arrow_down,
                                tooltip: '回到底部',
                                onTap: () {
  if (!_chatScroll.hasClients) return;
  _animatedJumpTo(_chatScroll.position.maxScrollExtent);
},
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        // ── Python 内核宿主：2×2 像素 WebView 负坐标移出视口 ──
        // WebView 必须挂树才会加载执行；零尺寸会挂起，故用最小尺寸 +
        // 移出可见区（不吃光栅资源，见启动 OOM 教训）
        if (_pyKernel != null)
          Positioned(
            left: -2,
            top: -2,
            child: SizedBox(
              width: 2,
              height: 2,
              child: IgnorePointer(child: WebViewWidget(controller: _pyKernel!)),
            ),
          ),
        // 本地网页阅读器宿主（read_webpage 的 WebView 渲染）
        if (_webReader != null)
          Positioned(
            left: -2,
            top: -2,
            child: SizedBox(
              width: 2,
              height: 2,
              child: IgnorePointer(child: WebViewWidget(controller: _webReader!)),
            ),
          ),
      ],
    );

    return _HomePageScope(
      state: this,
      child: Scaffold(
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
            // 抽屉右缘投影：挂在静止的抽屉层上——一次绘制、零逐帧开销，
            // 主页面滑动全程保持阴影（画在移动的主页面上则 blur 随位移
            // 每帧重算，是滑动掉帧主因）
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 28,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerRight,
                      end: Alignment.centerLeft,
                      colors: [
                        Colors.black.withValues(alpha: 0.30),
                        Colors.black.withValues(alpha: 0.12),
                        Colors.transparent,
                      ],
                      stops: const [0, 0.4, 1],
                    ),
                  ),
                ),
              ),
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
                  // 投影由抽屉右缘的静止渐变条提供（见根 Stack）——
                  // 移动的主页面上不画任何阴影（全屏 blur 随位移每帧
                  // 重算是滑动掉帧主因）
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: Stack(
                      children: [
                        // 主页面不透明底（缩放/圆角时不透出下层抽屉内容）
                        Container(
                          color: Theme.of(context).scaffoldBackgroundColor,
                        ),
                        child!,
                        // 半透明变暗遮罩（随进度渐变，无模糊）：
                        // 独立 RepaintBoundary——每帧只重画这块全屏色块
                        // 层，不脏主页面 Stack 的其他内容
                        RepaintBoundary(
                          child: IgnorePointer(
                            child: Container(
                              color: Colors.black.withValues(alpha: tt * 0.35),
                            ),
                          ),
                        ),
                      ],
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
                    // 附件条：主界面内（随 Transform 移动），位置绑定输入栏
                    // 容器顶边【动画中的逐帧高度】（_SizeReporter 布局回调），
                    // 跟随容器展开/收起动画；被变暗遮罩覆盖
                    ValueListenableBuilder<double>(
                      valueListenable: _inputBarAnimatedTop,
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
                  // 1:1 跟手（此前 ×1.25 放大 = 拖动手感奇怪的来源）
                  _drawerController.value =
                      (_drawerController.value + d.delta.dx / _drawerShift)
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
                  // 速度优先（轻扫 > 250px/s 按甩动方向），否则按位置
                  //（过半开/不到半关）；弹簧携带手指速度 → 无断裂
                  if (v < -250) {
                    _springDrawerTo(0.0, velocityPxPerSec: v);
                  } else if (v > 250) {
                    _springDrawerTo(1.0, velocityPxPerSec: v);
                  } else {
                    _springDrawerTo(_drawerController.value >= 0.5 ? 1.0 : 0.0);
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
      ),
    );
  }

  /// 抽屉收敛（所有手势结束路径统一走这里）：动画到就近端点，
  /// 并留一道帧后自检——若动画意外中断仍未到端点，再次收敛
  /// 抽屉弹簧开合（Kimi/iOS 手感）：从当前位置出发，携带手指速度
  /// （px/s → 控制器值/s），轻微回弹自然收敛——替代从静止起跑的
  /// easeOutQuart（速度断裂 = 手感奇怪的主因）
  void _springDrawerTo(double target, {double velocityPxPerSec = 0}) {
    _drawerController.animateWith(
      SpringSimulation(
        SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: 420,
          ratio: 0.88, // <1 轻微回弹（Kimi/iOS 手感）
        ),
        _drawerController.value.clamp(0.0, 1.0),
        target,
        velocityPxPerSec / _drawerShift,
      ),
    );
  }

  void _settleDrawer() {
    _springDrawerTo(_drawerController.value >= 0.5 ? 1.0 : 0.0);
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
            maxWidth: math.max(260, MediaQuery.sizeOf(context).width * 0.82),
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
          maxWidth: math.max(260, MediaQuery.sizeOf(context).width * 0.82),
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
  /// _MessageItem 等子组件的公开入口（见 HomePageStateScope）
  Widget buildMessageBubble(BuildContext context, Message m, int index) =>
      _messageBubble(context, m, index);

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
    if (identical(_editingMsg, m)) {
      return _InlineMessageEditor(
        message: m,
        index: index,
        isUser: isUser,
        replaceRules: _replaceRules,
        branchMode: identical(_branchMsg, m),
        onCancel: _cancelEditing,
        onSave: _saveEditedMessage,
        onBranch: _branchMessage,
        onPickAttachments: _pickEditAttachments,
      );
    }
    // 轮次收纳：新一轮开启后（不再是最后一条消息），本段响应的全部
    // 已完成轮次（含思考）收录为一张卡（组首渲染，其余组员为空）
    final isLastMsg = conv == null || conv.messages.last == m;
    final roundCollected =
        !isUser && !isLastMsg && (m.toolCalls?.isNotEmpty ?? false);
    List<Message> groupRounds = const [];
    if (roundCollected && conv != null) {
      var g = index;
      while (g > 0 &&
          conv.messages[g - 1].role != Role.user &&
          (conv.messages[g - 1].toolCalls?.isNotEmpty ?? false)) {
        g--;
      }
      final rounds = <Message>[];
      for (var k = g; k < conv.messages.length; k++) {
        final mk = conv.messages[k];
        if (mk.role == Role.user || (mk.toolCalls?.isEmpty ?? true)) break;
        rounds.add(mk);
      }
      groupRounds = rounds;
      if (g != index) return const SizedBox.shrink(); // 组内非首：为空
    }
    // 正文子项（气泡 / 工具卡 / 工具栏；思考块已提为全宽，见 return）
    final bodyChildren = <Widget>[
              // 轮次收纳卡：全部已完成轮次（含思考）收录一卡
              if (roundCollected)
                _roundsCollectedCard(context, groupRounds)
              // 气泡本体（无阴影；助手灰色、用户品牌蓝）。
              // 无正式内容（仅工具调用）时不渲染；正在流式接收（打字点）除外
              else if (hasBubbleContent || isStreamingTarget)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isUser
                        ? kUserBubbleColor
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
                          // 纯图片/附件消息：无正文不渲染空段落
                          //（空串 markdown 的空白块 = 气泡多余间距）
                          : m.content.isEmpty
                          ? const SizedBox.shrink()
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
              if (!roundCollected &&
                  !isUser &&
                  m.toolCalls != null &&
                  m.toolCalls!.isNotEmpty)
                _toolCallDivider(context, m),
              // 消息操作按钮行（工具栏：分支导航 + 复制/编辑/重新生成/删除）。
              // 分支导航 < n/N > 在工具栏行首。工具栏显示规则：
              // 仅在没有任何工具调用的轮次显示——工具调用轮只保留
              // 工具卡片分割块，不产生工具栏（避免一轮出现两个工具栏）；
              // 例外：输出被截断时强制显示（含思考阶段截断——
              // 只有 thinking 没有正式内容也显示，截断后需可直接操作/继续）。
              // 正在流式接收的消息不显示（此前模型先输出引导文字再调工具时，
              // 文字期间工具栏可见、工具卡片挂上后又消失 = 闪一下）
              if (!isStreamingTarget &&
                  (hasBubbleContent || m.truncated) &&
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
                          _editingMsg = m;
                          _branchMsg = null; // 普通编辑会退出分支模式
                        }),
                      ),
                      // 用户消息可开启分支对话（确认后截断并重新生成）
                      if (isUser)
                        _messageAction(
                          context,
                          icon: Icons.call_split,
                          tooltip: '分支',
                          onTap: () => setState(() {
                            _branchMsg = m;
                            _editingMsg = m;
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
                      // 朗读（系统 TTS，通用设置开关控制显隐）：
                      // 正在朗读的消息高亮、图标变停止
                      if (!isUser && _general.ttsEnabled)
                        _messageAction(
                          context,
                          icon: identical(_speakingMsg, m)
                              ? Icons.stop_circle_outlined
                              : Icons.volume_up_outlined,
                          tooltip: identical(_speakingMsg, m) ? '停止朗读' : '朗读',
                          color: identical(_speakingMsg, m)
                              ? Theme.of(context).colorScheme.onSurface
                              : null,
                          onTap: () => _toggleSpeak(m),
                        ),
                      // 输出气泡工具栏最右边：上下文占用圆环
                      if (!isUser) ...[
                        const SizedBox(width: 8),
                        _contextRing(context),
                      ],
                    ],
                  ),
                ),
    ];

    return RepaintBoundary(
      // 流式期间正在更新的气泡频繁重绘；RepaintBoundary 隔离各气泡，
      // 静态气泡不随之重绘（整列表只有一个脏区域）
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 思考过程区（仅 assistant 且有 thinking 时显示）：宽度上限与
          // 气泡一致（82%，最少 260），靠左填满——折叠/展开宽度统一
          if (!roundCollected &&
              !isUser &&
              (_thinkingDepth > 0 || m.truncated) &&
              (m.displayThinking?.isNotEmpty ?? false))
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(260, MediaQuery.sizeOf(context).width * 0.82),
              ),
              child: SizedBox(
                width: double.infinity,
                child: _thinkingBlock(
                  context,
                  _displayCached(m.displayThinking!),
                  streaming: isStreamingTarget,
                ),
              ),
            ),
          // 气泡区：用户消息靠右、助手靠左，宽度上限 82%
          Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(260, MediaQuery.sizeOf(context).width * 0.82),
              ),
              child: Column(
                crossAxisAlignment: align,
                children: bodyChildren,
              ),
            ),
          ),
        ],
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
  /// 落盘合并定时器：高频调用（流式尾帧/连续编辑）只触发一次写盘
  Timer? _persistTimer;
  Conversation? _pendingPersist;

  Future<void> _persist(Conversation conv) async {
    // 同步锚点快照（内存操作，必须立即）
    for (var i = 0; i < conv.messages.length; i++) {
      final m = conv.messages[i];
      final b = m.branches;
      if (b != null && b.isNotEmpty) {
        final live = b[m.viewPos.clamp(0, b.length - 1)];
        live.anchor = _snapshot(m);
        live.tail = conv.messages.sublist(i + 1);
      }
    }
    // 写盘防抖（800ms）：连续触发合并为一次——大对话 JSON 编码
    // （isolate）+ 文件写入不再高频重复
    _pendingPersist = conv;
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), () async {
      final c = _pendingPersist;
      _pendingPersist = null;
      if (c == null) return;
      // 串行链：上一次写盘（大对话 isolate 编码可能 > 防抖周期）完成前
      // 不并发写同一文件。then 同步注册——无交错窗口
      final op = _persistChain.then((_) async {
        try {
          await _store?.save(c);
        } catch (e) {
          // 真实异常带类型上报（此前一律"存储空间不足"误报）
          final msg = e.toString();
          _toast(
            msg.contains('No space')
                ? '存储空间不足，消息未能保存'
                : '保存失败：${msg.length > 60 ? '${msg.substring(0, 60)}…' : msg}',
          );
        }
      });
      _persistChain = op;
      await op;
    });
  }

  /// 落盘串行链（保证同一时刻只有一次写盘在执行）
  Future<void> _persistChain = Future.value();

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
      _editingMsg = null;
    });
    await _persist(conv);
  }

  /// 退出内联编辑/分支编辑（Cancel 按钮）
  void _cancelEditing() {
    setState(() {
      _editingMsg = null;
      _branchMsg = null;
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
    // 分支拓扑变化在方法体内 setState 前自增（见 _renderEpoch 注释）
    List<MessageFilePart>? fileParts,
    List<ImagePart>? imageParts,
  }) {
    final conv = _currentConversation;
    if (conv == null || _isResponding) return;
    _renderEpoch++;
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
      _editingMsg = null;
      _branchMsg = null;
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
    _renderEpoch++; // 分支拓扑变化：其他消息的导航显示随之刷新
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
    _renderEpoch++; // 分支拓扑变化（工具轮整段重生成挂到用户消息）
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
    _renderEpoch++; // 其他消息的分支导航显示（< n/N >）随之变化
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
        // 恢复该分支的图片/文件附件（用户消息分支各自携带自己的
        // 附件版本——漏掉这里会被其他分支的附件顶替）
        ..imageParts = t.anchor.imageParts == null
            ? null
            : [...t.anchor.imageParts!]
        ..fileParts = t.anchor.fileParts == null
            ? null
            : [...t.anchor.fileParts!]
        ..viewPos = target;
      // 换入目标分支的后续链
      conv.messages.removeRange(index + 1, conv.messages.length);
      conv.messages.addAll(t.tail);
      // 切换分支时退出该条上的编辑态，避免用旧文本覆盖新分支
      if (identical(_editingMsg, msg)) _editingMsg = null;
      if (identical(_branchMsg, msg)) _branchMsg = null;
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
    // 单图：固定高度（解码前后布局稳定——占位转圈与图片同尺寸，
    // 不会出现先小后大再裁剪的跳变动画）；多图：正方形网格
    if (count == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: SizedBox(
          height: 240,
          width: double.infinity,
          child: _cachedImageThumb(context, images.first),
        ),
      );
    }
    final crossCount = count == 2 ? 2 : 3;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      // Wrap + 固定方形格子：不用 GridView（滚动视口在气泡 Column 内
      // 的 shrinkWrap 尺寸计算会多出首行上方的空隙——多图气泡顶部
      // 大空白的根源）；Wrap 尺寸精确且无滚动语义
      child: LayoutBuilder(
        builder: (context, c) {
          final size = (c.maxWidth - 6 * (crossCount - 1)) / crossCount;
          return Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final img in images)
                SizedBox(
                  width: size,
                  height: size,
                  child: _cachedImageThumb(context, img),
                ),
            ],
          );
        },
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
        // 文件 provider：FileImage 解码在 Flutter 异步线程池（UI 线程
        // 零阻塞），磁盘缓存命中后接近零成本——彻底替代 UI 线程同步
        // base64Decode 的 MemoryImage 路径
        child: FutureBuilder<FileImage>(
          // future 缓存：同一张图的 Future 只创建一次（每次 build
          // 新建 Future 会让 FutureBuilder 回到 pending → 占位/图片
          // 交替闪烁——有图时动画奇怪的根源）
          future: _thumbFutures.putIfAbsent(
            img.displayUrl,
            () => _fileImageFor(img.displayUrl),
          ),
          builder: (context, snap) => snap.data == null
              ? Container(
                  color: Colors.black12,
                  child: const Center(
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  ),
                )
              : Image(
                  image: snap.data!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  frameBuilder: (context, child, frame, wasSync) {
                    if (frame == null && !wasSync) {
                      return Container(
                        color: Colors.black12,
                        alignment: Alignment.center,
                        child: const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      );
                    }
                    return wasSync
                        ? child
                        : AnimatedOpacity(
                            opacity: 1,
                            duration: const Duration(milliseconds: 120),
                            child: child,
                          );
                  },
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
      ),
    );
  }

  /// 全屏查看图片：黑色背景 + 双指/双击缩放 + 点击关闭，左右滑动
  /// 浏览当前会话的全部图片。
  /// 用 MaterialPageRoute（全屏不透明，无 barrier 遮罩层，避免遮罩问题）
  void _showImageFullscreen(BuildContext context, ImagePart img) {
    _openImageGallery(img.dataUrl);
  }

  /// 缩略图 Future 实例缓存（防 FutureBuilder 重复 pending 闪烁）
  static final Map<String, Future<FileImage>> _thumbFutures = {};

  /// 图片磁盘缓存目录（thumb/ai 档 dataUrl → 临时小文件）：
  /// FileImage 的解码在 Flutter 内部异步线程池执行，
  /// UI 线程零阻塞（此前 MemoryImage 路径每次重建都在 UI 线程
  /// 同步 base64Decode——多图消息滚动/流式时每帧 MB 级同步解码，
  /// 是显示卡顿的根源）
  static Directory? _imgDiskDir;
  static final Map<String, FileImage> _fileProviderCache = {};

  Future<FileImage> _fileImageFor(String dataUrl) async {
    final hit = _fileProviderCache[dataUrl];
    if (hit != null) return hit;
    final dir = _imgDiskDir ??= () {
      final d = Directory('${Directory.systemTemp.path}/llm_img_providers');
      d.createSync(recursive: true);
      return d;
    }();
    // 文件名 = dataUrl 的稳定 hash（同图同文件，天然去重）
    final name = 'img_${dataUrl.hashCode.abs()}.jpg';
    final f = File('${dir.path}/$name');
    if (!f.existsSync()) {
      // base64 解码 + 落盘在 isolate：UI 线程零卡顿
      final bytes = await compute(_b64ToBytes, dataUrl);
      await f.writeAsBytes(bytes, flush: true);
    }
    final img = FileImage(f);
    if (_fileProviderCache.length > 60) _fileProviderCache.clear();
    _fileProviderCache[dataUrl] = img;
    return img;
  }

  /// 图片实例缓存：同一 dataUrl 复用同一 MemoryImage。
  /// 列表项移出/移入屏幕重建时，ImageCache 按 provider 实例命中，
  /// 不再重复 base64 解码 + 图片解码（这是"每次加载"的根因）
  static final Map<String, MemoryImage> _imageCache = {};

  /// 图片缓存字节量（约）：原始图 ≤4MB/张，10 张 ≈ 40MB 封顶
  static int _imageCacheBytes = 0;

  /// 打开全屏图片画廊：收集当前会话全部图片（消息顺序），左右滑动
  /// 浏览；[dataUrl] 定位初始页
  void _openImageGallery(String dataUrl) {
    final urls = <String>[];
    for (final m in _currentConversation?.messages ?? const <Message>[]) {
      for (final img in m.imageParts ?? const <ImagePart>[]) {
        urls.add(img.dataUrl);
      }
    }
    if (urls.isEmpty) return;
    final idx = urls.indexOf(dataUrl);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ImageFullscreen(
          images: urls.map(_imageProviderFor).toList(),
          initialIndex: idx < 0 ? 0 : idx,
        ),
      ),
    );
  }

  /// 从 data URL 取（或创建并缓存）图片 provider。
  /// LRU 上限：10 张 / 约 40MB——超过时先访问序淘汰最旧条目
  ///（消息里的 dataUrl 字符串常驻，provider 缓存只是解码副本，
  /// 淘汰后再次显示会按需重建，功能无损）
  MemoryImage _imageProviderFor(String dataUrl) {
    final hit = _imageCache.remove(dataUrl);
    if (hit != null) {
      _imageCache[dataUrl] = hit; // 重新插入 = 刷新 LRU 顺序
      return hit;
    }
    final comma = dataUrl.indexOf(',');
    final b64 = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
    final img = MemoryImage(base64Decode(b64));
    // 淘汰：超条目数或超字节量（base64 长度 ×0.75 ≈ 原始字节）
    while (_imageCache.length >= 10 ||
        (_imageCacheBytes + b64.length * 3 ~/ 4 > 40 << 20 &&
            _imageCache.isNotEmpty)) {
      final oldestKey = _imageCache.keys.first;
      final old = _imageCache.remove(oldestKey)!;
      _imageCacheBytes -= old.bytes.length;
    }
    _imageCache[dataUrl] = img;
    _imageCacheBytes += img.bytes.length;
    return img;
  }

  /// MCP 工具调用分割块（Claude 风格）：独立于消息气泡的灰底卡片，
  /// 位于工具调用轮气泡之后、下一轮气泡之前，作为 ReAct 轮次的分割元素。
  /// 顶部标签行（「工具调用」+ 状态汇总），每个工具一行（名称 + 参数 + 状态）
  /// 快捷导航玻璃圆钮：与输入栏 _roundButton 同风格（液态玻璃 + 灰 tint）
  Widget _glassNavBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: CupertinoLiquidGlass(
        theme: LiquidGlassThemeData(
          shadows: Theme.of(context).brightness == Brightness.dark
              ? const <BoxShadow>[]
              : null,
        ),
        blurSigma: 5,
        tintOpacity: Theme.of(context).brightness == Brightness.dark
            ? 0.20
            : 0.35,
        borderRadius: BorderRadius.circular(22),
        // 暗色模式去光影（灰底上发光边像脏阴影）
        glowRadius: Theme.of(context).brightness == Brightness.dark
            ? 0
            : 6,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                icon,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 该消息是否为「已收纳轮次组的非首成员」（渲染为空 + 外边距归零；
  /// 卡片由组首渲染）。[index] 由调用方传入（消息项自带），免 O(n) 扫描
  bool isCollapsedToolMember(Message m, int index) {
    if ((m.toolCalls?.isEmpty ?? true)) return false;
    final conv = _currentConversation;
    if (conv == null) return false;
    if (conv.messages.last == m) return false; // 进行中的轮
    if (index <= 0) return false;
    final prev = conv.messages[index - 1];
    if (prev.role == Role.user || (prev.toolCalls?.isEmpty ?? true)) {
      return false; // 组首（渲染卡片）
    }
    return true;
  }

  Widget _toolCallDivider(BuildContext context, Message m) {
    // 静默卡片（send_image）不渲染——它只用于标记"这是工具轮"
    final tcs = (m.toolCalls ?? const <ToolCallRecord>[])
        .where((t) => !t.silent)
        .toList();
    if (tcs.isEmpty) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
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
        // 展开/收起动画：单一容器壳，内容切换由 AnimatedSize 平滑过渡
        child: AnimatedSize(
          alignment: Alignment.topLeft,
          duration: const Duration(milliseconds: 220),
          reverseDuration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: _toolDividerContent(context, m),
        ),
      ),
    );
  }

  /// 工具卡内容（收起一槽厚 ↔ 完整卡）：外壳由调用方提供
  ///（独立分隔块 / 轮次收纳卡两种宿主复用）
  Widget _toolDividerContent(BuildContext context, Message m) {
    final tcs = (m.toolCalls ?? const <ToolCallRecord>[])
        .where((t) => !t.silent)
        .toList();
    if (tcs.isEmpty) return const SizedBox.shrink();
    final grey = Colors.grey.shade700;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 状态汇总：任一工具仍在执行（resultCount == null）→ 调用中
    final running = tcs.any((t) => t.resultCount == null);
    // 「完成 X 个工具」的成功色（蓝，两态样式统一）
    final success = dark ? kSuccessColor : kSuccessColorLight;
    // 调用完成后收起到一槽厚；运行中/手动展开为完整卡
    final collapsed = !running && !m.toolCardExpanded;
    final labelSmall = Theme.of(context).textTheme.labelSmall;
    // 两态共用同一头部行构建（像素级一致，开合不跳动）：
    // 左标签文本不同，其余（图标/间距/右对齐完成数/箭头）完全相同
    Widget header(String left, VoidCallback? onTap) => InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Icon(Icons.hub_outlined, size: 13, color: grey),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                left,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: labelSmall?.copyWith(
                  color: grey,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (running) ...[
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              running ? '调用中…' : '完成 ${tcs.length} 个工具',
              style: labelSmall?.copyWith(color: running ? grey : success),
            ),
            const SizedBox(width: 2),
            Icon(
              collapsed ? Icons.expand_more : Icons.expand_less,
              size: 16,
              color: grey,
            ),
          ],
        ),
      ),
    );
    if (collapsed) {
      return header(
        '工具调用：${tcs.first.name}',
        () => setState(() {
          m.toolCardExpanded = true;
          _renderEpoch++;
        }),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        header(
          '工具调用',
          running
              ? null
              : () => setState(() {
                  m.toolCardExpanded = false;
                  _renderEpoch++;
                }),
        ),
        const SizedBox(height: 4),
        // 全量展开（高度限制 360，工具很多时内部滚动）
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final tc in tcs) _toolRow(context, tc)],
            ),
          ),
        ),
      ],
    );
  }

  /// 轮次收纳卡：本段响应的全部已完成轮次（含思考）收录为一张卡。
  /// 整卡默认收起为一槽厚（头部行：轮数 + 完成工具数），点击展开；
  /// 卡内条目（思考/正文/工具）以横线分割，思考为扁平形态（无嵌卡）。
  /// 由组首消息渲染，组内其余消息渲染为空
  Widget _roundsCollectedCard(BuildContext context, List<Message> rounds) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final grey = Colors.grey.shade700;
    final success = dark ? kSuccessColor : kSuccessColorLight;
    final labelSmall = Theme.of(context).textTheme.labelSmall;
    final total = rounds
        .map(
          (m) => (m.toolCalls ?? const <ToolCallRecord>[])
              .where((t) => !t.silent)
              .length,
        )
        .fold<int>(0, (a, b) => a + b);
    final first = rounds.first;
    final Widget header = Row(
      children: [
        Icon(Icons.hub_outlined, size: 13, color: grey),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '工具调用（${rounds.length} 轮）',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelSmall?.copyWith(
              color: grey,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text('完成 $total 个工具', style: labelSmall?.copyWith(color: success)),
        const SizedBox(width: 2),
        Icon(
          first.roundsExpanded ? Icons.expand_less : Icons.expand_more,
          size: 16,
          color: grey,
        ),
      ],
    );
    final children = <Widget>[];
    for (var i = 0; i < rounds.length; i++) {
      final m = rounds[i];
      if (i > 0) {
        // 轮与轮之间的横线分割
        children.add(
          Container(
            height: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 10),
            color: Colors.grey.withValues(alpha: 0.3),
          ),
        );
      }
      final tcs = (m.toolCalls ?? const <ToolCallRecord>[])
          .where((t) => !t.silent)
          .toList();
      final hasText = m.content.trim().isNotEmpty;
      final hasThinking = m.displayThinking?.trim().isNotEmpty ?? false;
      // 思考：扁平形态（无嵌卡），自带折叠交互
      if (hasThinking)
        children.add(
          _thinkingBlock(
            context,
            _displayCached(m.displayThinking!),
            streaming: false,
            flat: true,
          ),
        );
      // 思考与其余条目之间的横线
      if (hasThinking && (hasText || tcs.isNotEmpty))
        children.add(
          Container(
            height: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: Colors.grey.withValues(alpha: 0.3),
          ),
        );
      // 本轮正文（无壳直接渲染，与卡同底）
      if (hasText)
        children.add(
          _general.markdownEnabled
              ? MarkdownView(
                  text: _displayCached(m.displayContent),
                  latexEnabled: _general.latexEnabled,
                  mermaidEnabled: _general.mermaidEnabled,
                  artifactsEnabled: _general.artifactsEnabled,
                )
              : SelectableText(
                  _displayCached(m.displayContent),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
        );
      // 正文与工具之间的横线
      if (hasText && tcs.isNotEmpty)
        children.add(
          Container(
            height: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: Colors.grey.withValues(alpha: 0.3),
          ),
        );
      // 图片（如有）
      if (m.imageParts?.isNotEmpty ?? false)
        children.add(
          SizedBox(
            width: double.infinity,
            child: _imageGrid(context, m.imageParts!),
          ),
        );
      // 工具部分（收起/展开逻辑复用）
      if (tcs.isNotEmpty)
        children.add(
          AnimatedSize(
            alignment: Alignment.topLeft,
            duration: const Duration(milliseconds: 220),
            reverseDuration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: _toolDividerContent(context, m),
          ),
        );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF262626) : const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      // 整卡默认收起（一槽厚）↔ 展开全量；开合动画。开合点击只挂在
      // 头部行——内容区（思考标签/正文/工具）各有自己的交互，
      // 整卡级 InkWell 会抢走它们旁边的空白点击 = 误收整卡
      child: AnimatedSize(
        alignment: Alignment.topLeft,
        duration: const Duration(milliseconds: 220),
        reverseDuration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() {
                  first.roundsExpanded = !first.roundsExpanded;
                  _renderEpoch++;
                }),
                child: header,
              ),
              if (first.roundsExpanded) ...[
                // 标题头与内容之间的分界线
                Container(
                  height: 0.5,
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  color: Colors.grey.withValues(alpha: 0.3),
                ),
                ...children,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 工具调用单行：状态图标 + 名称/参数 + 结果字符数；
  /// 带输出/产图的工具（Python）可点击展开详情
  Widget _toolRow(BuildContext context, ToolCallRecord tc) {
    final grey = Colors.grey.shade700;
    final running = tc.resultCount == null;
    final failed = tc.resultCount != null && tc.resultCount! < 0;
    final imgs = tc.images ?? const <String>[];
    final hasDetail =
        (tc.output?.isNotEmpty ?? false) || imgs.isNotEmpty;
    final body = Padding(
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
              color: failed
                  ? Colors.redAccent
                  : (Theme.of(context).brightness == Brightness.dark
                        ? kSuccessColor
                        : kSuccessColorLight),
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
          if (imgs.isNotEmpty) ...[
            Icon(
              Icons.image_outlined,
              size: 13,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 2),
            Text(
              '${imgs.length}',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: grey),
            ),
          ],
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
          if (hasDetail)
            Icon(
              tc.expanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: grey,
            ),
        ],
      ),
    );
    if (!hasDetail) return body;
    // 展开/收起：HomePage.setState → _MessageItem 签名失效 → 真实重建
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => tc.expanded = !tc.expanded),
          borderRadius: BorderRadius.circular(kRadiusXs),
          child: body,
        ),
        if (tc.expanded) _toolDetail(context, tc),
      ],
    );
  }

  /// 工具详情（展开态）：完整输出（等宽可滚动可选择）+ 产图横滑列表
  Widget _toolDetail(BuildContext context, ToolCallRecord tc) {
    final imgs = tc.images ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.only(left: 22, top: 2, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tc.output?.isNotEmpty ?? false)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 240),
              margin: EdgeInsets.only(bottom: imgs.isEmpty ? 0 : 8),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(kRadiusSm),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  tc.output!,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.45,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          if (imgs.isNotEmpty)
            SizedBox(
              height: 165,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: imgs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) => GestureDetector(
                  // 点击产图 → 全屏查看（复用聊天图片缓存 provider）
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          _ImageFullscreen(
                            images: [_imageProviderFor(imgs[i])],
                          ),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(kRadiusSm),
                    child: Image(
                      image: _imageProviderFor(imgs[i]),
                      width: 220,
                      height: 165,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 思考过程折叠块（llama.cpp 风格：灰色小字 + 展开/收起）。
  /// 展开时思考区增高：上翻补偿/贴底保持由 ChatScrollPosition 在
  /// 布局阶段统一处理（correctForNewDimensions），无需额外干预。
  /// [streaming] 流式接收中：尾部窗口 + Text（见 _ThinkingBlock 注释）
  Widget _thinkingBlock(
    BuildContext context,
    String thinking, {
    bool streaming = false,
    bool flat = false,
  }) {
    return _ThinkingBlock(
      thinking: thinking,
      streaming: streaming,
      flat: flat,
    );
  }

  /// 流式等待占位（三个点）
  Widget _typingDots(BuildContext context) {
    return _TypingDots(
      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
    );
  }

  /// 抽屉页面：并排按钮（思考深度 / 提示词模板）+ 历史对话滚动栏
  Widget _buildDrawer({required double topPad}) {
    const depthLabels = ['关闭', '低', '高', '最高'];
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
                            setState(() {
                              _thinkingDepth = (_thinkingDepth + 1) % 4;
                              _renderEpoch++;
                            });
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
                                          // 切换会话（时序与动画解耦，
                                          // 见 _openConversation）
                                          _openConversation(c);
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
    this.loading = false,
  });

  final bool isImage;
  final String name;

  /// 压缩中占位：选图后立即以占位卡片形式出现（与选中数量一致），
  /// 压缩完成后替换为真实缩略图
  final bool loading;

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

/// 尺寸被动上报：布局阶段拿到子项真实尺寸（隐式动画期间每帧布局
/// 都会触发），microtask 里回调整避免布局期间同步通知监听者重建。
/// 用于附件条跟随输入栏容器的展开/收起动画
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, super.child});

  final void Function(double height) onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);

  final void Function(double height) onSize;
  double? _last;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (_last != h && h.isFinite) {
      _last = h;
      final cb = onSize;
      scheduleMicrotask(() => cb(h));
    }
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
                // 内容：图片缩略图 / 压缩占位 / 文件图标（悬浮阴影）
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
                    child: att.loading
                        ? Container(
                            color: Colors.black12,
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            ),
                          )
                        : att.isImage
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
    if (kIsWeb) {
      return Image.network(path, fit: BoxFit.cover);
    }
    // ResizeImage 限宽 400 解码：附件条格子只有 68×68，
    // 全尺寸解码会把 UI 线程与 GPU 内存同时打爆。
    // frameBuilder：解码未完成（frame==null）显示灰底转圈占位，
    // 完成后淡入图片——不再出现空白格子
    return Image(
      image: ResizeImage(
        FileImage(File(path)),
        width: 400,
        allowUpscaling: false,
      ),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSync) {
        if (frame == null && !wasSync) {
          // 解码中：灰色占位 + 小转圈
          return Container(
            color: Colors.black12,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          );
        }
        return wasSync
            ? child
            : AnimatedOpacity(
                opacity: 1,
                duration: const Duration(milliseconds: 150),
                child: child,
              );
      },
      errorBuilder: (_, _, _) => Container(
        color: Colors.black26,
        alignment: Alignment.center,
        child: Icon(
          Icons.broken_image_outlined,
          size: 18,
          color: Colors.white54,
        ),
      ),
    );
  }

  /// 文件卡片（llama.cpp 风格横排）：文件图标 + 文件名 + 大小两行
  Widget _fileIcon(BuildContext context, _Attachment att) {
    final isText = isTextAttachmentName(att.name);
    final lower = att.name.toLowerCase();
    final isDoc = isDocAttachmentName(att.name);
    // 文档按类型分图标：xlsx 表格 / pptx 幻灯片 / docx 文档
    final icon = isText
        ? Icons.text_snippet_outlined
        : lower.endsWith('.xlsx')
        ? Icons.table_chart_outlined
        : lower.endsWith('.pptx')
        ? Icons.slideshow_outlined
        : isDoc
        ? Icons.description_outlined
        : lower.endsWith('.pdf')
        ? Icons.picture_as_pdf_outlined
        : Icons.insert_drive_file;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
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
    required this.onTakePhoto,
    required this.onAddFile,
    required this.containerTopNotifier,
    required this.animatedTopNotifier,
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
    required this.attachmentsAllLoading,
  });

  /// 加号面板：选择图片 / 文件（由 HomePage 统一处理附件）
  final VoidCallback onAddImage;

  /// 加号面板：拍照（相机）
  final VoidCallback onTakePhoto;
  final VoidCallback onAddFile;

  /// 上报输入栏容器顶边位置（附件条绑定其上方）
  final ValueNotifier<double> containerTopNotifier;

  /// 上报输入栏容器【动画中】的真实高度（布局阶段被动逐帧测量；
  /// 附件条跟随容器动画用，与 containerTopNotifier 的目标值互不干扰）
  final ValueNotifier<double> animatedTopNotifier;

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

  /// 思考深度（0 none / 1 low / 2 high / 3 max；与抽屉栏同步）
  final int thinkingDepth;

  /// 思考深度变更回调（主页面 setState + 持久化）
  final ValueChanged<int> onThinkingDepthChanged;

  /// 当前模型能力（false = 不支持，面板对应选项降亮度禁用）
  final bool modelSupportsMultimodal;
  final bool modelSupportsTools;
  final bool modelSupportsThinking;

  /// 是否有附件（有附件时即使无文字也可发送）
  final bool hasAttachments;

  /// 附件是否全部仍在压缩中（占位状态：发送按钮禁用）
  final bool attachmentsAllLoading;

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
    // Insets 物理上限截断（小窗/悬浮窗防御，同 HomePage）：
    // 异常大的残留 insets 只会顶飞输入栏，按键盘真实上限截断
    final winH = MediaQuery.sizeOf(context).height;
    final bottomPad = math.min(
      MediaQuery.paddingOf(context).bottom,
      winH * 0.05,
    );
    // 仅当输入栏自身触发输入时随键盘升起；编辑消息/提示词等其他输入场景
    // 下输入栏保持在底部（键盘由别的输入框触发，不顶起输入栏）
    final rawInset = _focusNode.hasFocus
        ? math.min(MediaQuery.viewInsetsOf(context).bottom, winH * 0.6)
        : 0.0;
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

    // 目标总高：build 时一次性写入 containerTopNotifier——列表底部
    // 留白/空状态用（跳变一次，滚动补偿统一处理）。附件条的逐帧跟随
    // 不走这条链路：由 _SizeReporter 在布局阶段被动上报动画中的真实
    // 高度到 animatedTopNotifier（见占位处的包装），互不干扰
    final containerHeight = (_active ? _topPad + _inputHeight : 0) + _side;
    widget.containerTopNotifier.value = containerHeight + 8;

    return Align(
      alignment: Alignment.bottomCenter,
      // AnimatedPadding：键盘动画期间零时长直接跟随（精确贴键盘）；
      // 失焦时 keyboardInset 瞬间归零，用 300ms 隐式动画平滑下移，
      // 避免输入栏直接跳到底部、大小过渡动画被跳位掩盖
      child: AnimatedPadding(
        duration: _focusNode.hasFocus
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: bottomPad + 8 + keyboardInset,
          left: _hMargin,
          right: _hMargin,
        ),
        // 输入栏容器。阴影统一走玻璃 theme（此前外层 Container 阴影
        // 与玻璃自带阴影叠两层 = 阶梯感）：浅色单层柔影，暗色无影
        child: CupertinoLiquidGlass(
          theme: LiquidGlassThemeData(
            shadows: Theme.of(context).brightness == Brightness.dark
                ? const <BoxShadow>[
                    // 暗色：一层柔和阴影（深底上稍高不透明度才可见）
                    BoxShadow(
                      color: Color(0x42000000),
                      blurRadius: 16,
                      offset: Offset(0, 5),
                    ),
                  ]
                : const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x26000000),
                      blurRadius: 20,
                      offset: Offset(0, 6),
                    ),
                  ],
          ),
          blurSigma: 10, // 更模糊一点
          // tint 透明度：亮色 0.28、暗色 0.20（暗色 tint 为深灰，加浓
          // 让玻璃面更暗——此前 0.12 偏白）
          tintOpacity: Theme.of(context).brightness == Brightness.dark
              ? 0.20
              : 0.28,
          borderRadius: BorderRadius.circular(_radius),
          glowRadius: 10,
          // 高光斜面：暗色大幅减弱（白色 80% 高光在深底上 = 发白）
          specularGradient: Theme.of(context).brightness == Brightness.dark
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x33FFFFFF), Color(0x11FFFFFF), Color(0x00FFFFFF)],
                )
              : const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xCCFFFFFF), Color(0x66FFFFFF), Color(0x00FFFFFF)],
                ),
          child: Stack(
            children: [
              // 白色模式下玻璃面偏灰一档：默认白色 tint 在浅色背景上
              // 近纯白——垫一层极淡灰让输入框与背景拉开（暗色不动）
              if (Theme.of(context).brightness != Brightness.dark)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.grey.withValues(alpha: 0.10),
                    ),
                  ),
                ),
              // 非定位占位：决定容器尺寸（激活时顶部让出输入栏空间 + 底部按钮行）。
              // _SizeReporter：布局阶段把动画中的真实容器高度逐帧上报给
              // 附件条（AnimatedContainer 隐式动画只改布局不回调，被动测量
              // 是唯一逐帧来源）；microtask 上报避免布局期间改监听者
              _SizeReporter(
                onSize: (h) =>
                    widget.animatedTopNotifier.value = h + 8,
                child: Column(
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
  bool get _canSend =>
      _controller.text.isNotEmpty ||
      (widget.hasAttachments && !widget.attachmentsAllLoading);

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
                      const ['关闭', '低', '高', '最高'][_sheetDepth],
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
                    max: 3,
                    divisions: 3,
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
              // 四个并排按钮：拍照 / 图片 / 文件 / 提示词
              Row(
                children: [
                  Expanded(
                    // 拍照（相机）——与图片同受多模态能力限制
                    child: _panelButton(
                      icon: Icons.photo_camera_outlined,
                      onTap: widget.modelSupportsMultimodal
                          ? widget.onTakePhoto
                          : null,
                      disabled: !widget.modelSupportsMultimodal,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    // 当前模型不支持多模态：变暗 + 图标斜杠 + 不可点
                    child: _panelButton(
                      icon: Icons.image_outlined,
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
                      onTap: widget.onAddFile,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _panelButton(
                      icon: Icons.auto_awesome,
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
    String? label,
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
                if (label != null) ...[
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
        color: Theme.of(context).colorScheme.onSurface,
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
  const _ThinkingBlock({
    required this.thinking,
    this.streaming = false,
    this.flat = false,
  });

  final String thinking;

  /// 扁平形态（轮次收纳卡内用）：无灰底小卡外壳，直接分段内容——
  /// 与卡内其他条目一样以横线分割，不嵌卡中卡
  final bool flat;

  /// 流式接收中：尾部固定窗口 + 普通 Text——SelectableText 对大文本
  /// 是 O(n) 全量重排（含选择区域构建），每 33ms 一帧时是卡顿主因；
  /// 尾部窗口把每帧布局成本压成常数。完成后自动切回全文可选中
  final bool streaming;

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

/// 流式期间显示的思考尾部窗口（字符）：约一屏多的量，够看实时输出
const int _kStreamThinkWindow = 4000;

class _ThinkingBlockState extends State<_ThinkingBlock> {
  // 默认收起：只显示「思考过程」标签行，点击展开
  bool _expanded = false;

  /// 展开内容滚动控制器（流式时钉在底部）
  final ScrollController _scroll = ScrollController();

  /// 用户是否在底部（上翻查看时不强制拉回）
  bool _stickToBottom = true;

  /// 流式窗口冻结锚点：null = 跟随最新（尾部窗口）；非 null = 用户
  /// 上翻后冻结的窗口起点（字符偏移）——窗口不再前滑，内容稳定可读；
  /// 滚回底部自动恢复跟随
  int? _frozenHead;

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
      final atBottom = pos.pixels >= pos.maxScrollExtent - 8;
      _stickToBottom = atBottom;
      if (atBottom) {
        _frozenHead = null; // 滚回底部 = 恢复跟随最新
      } else if (_frozenHead == null &&
          widget.streaming &&
          widget.thinking.length > _kStreamThinkWindow) {
        // 离开底部的一瞬：冻结当前窗口起点（此后新内容不再推动窗口）
        _frozenHead = widget.thinking.length - _kStreamThinkWindow;
      }
    });
  }

  @override
  void didUpdateWidget(_ThinkingBlock old) {
    super.didUpdateWidget(old);
    // 流式结束/思考被清空（重新生成）：清除冻结锚点
    if (!widget.streaming && old.streaming) _frozenHead = null;
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
    // 流式窗口：跟随模式 = 尾部 _kStreamThinkWindow 字符（每帧布局成本
    // 恒定）；用户上翻后窗口冻结在 [_frozenHead, _frozenHead+窗口) ——
    // 新内容不再把窗口往前推，上翻阅读位置稳定；滚回底部恢复跟随。
    // 完成后切换全文
    final full = widget.thinking;
    var head = _frozenHead ?? full.length - _kStreamThinkWindow;
    if (head > full.length - _kStreamThinkWindow) {
      head = full.length - _kStreamThinkWindow; // 思考变短（重新生成）
    }
    final streamingWindow =
        widget.streaming && full.length > _kStreamThinkWindow;
    final String text;
    if (!streamingWindow) {
      text = full;
    } else {
      final end = math.min(head + _kStreamThinkWindow, full.length);
      text = '${head > 0 ? '…（前面 $head 字已折叠；滚回底部恢复跟随）\n' : ''}'
          '${full.substring(head, end)}'
          '${end < full.length ? '\n…（更新的内容已收起，滚回底部跟随最新）' : ''}';
    }
    final thinkStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.grey.shade700,
      height: 1.5,
    );
    // 内容体（两种外壳共用）；扁平形态（收纳卡内）无灰底小卡，
    // 条目由卡统一横线分割
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 扁平形态标签占满整行（扩大点击区，避免偏一点点到外层）
        SizedBox(
          width: widget.flat ? double.infinity : null,
          child: Row(
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
        ),
                // 展开/收起：AnimatedSize + 折叠态零尺寸（SizedBox.shrink）。
                // 不用 AnimatedCrossFade：它的折叠尺寸取两个子项的最大宽，
                // 收起后仍占满整行；shrink 让宽度随内容一起收缩。
                // 透明度单独 TweenAnimationBuilder 超前 1.4 倍速淡入
                //（220/1.4≈157ms）：内容先于尺寸到位，双轴动画观感更均匀
                AnimatedSize(
                  alignment: Alignment.topLeft,
                  duration: const Duration(milliseconds: 220),
                  reverseDuration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  child: _expanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          // 展开内容：最大高度限制（llama.cpp 28rem 的移动端
                          // 折中），超出部分在块内滚动；拖动状态由
                          // NotificationListener 跟踪
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0.0, end: 1.0),
                            duration: const Duration(milliseconds: 157),
                            builder: (context, opacity, child) => Opacity(
                              opacity: opacity,
                              child: child,
                            ),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxHeight: 320,
                              ),
                              // 上下边缘字符渐隐（ShaderMask dstIn，同附件条
                              // 横向渐隐的做法）：仅该方向有未滚到的内容时
                              // 才渐隐（顶部有上文/底部有下文），滚到尽头该端
                              // 渐隐消失；ListenableBuilder 随滚动位置刷新。
                              // 颜色/停靠点按需构造——不渐隐的端不引入
                              // 透明色（固定四段渐变在退化段 [0,0]/[1,1]
                              // 会在边缘残留一条半透明细缝）
                              child: ListenableBuilder(
                                listenable: _scroll,
                                builder: (context, child) {
                                  // 渐隐幅度（边缘 alpha，1=不渐隐）：
                                  // 随离边缘的滚动行程连续渐入（0~48px），
                                  // 消除阈值处整条渐隐带突然出现/消失的跳变
                                  var topEdge = 1.0;
                                  var bottomEdge = 1.0;
                                  var f = 0.0;
                                  if (_scroll.hasClients) {
                                    final pos = _scroll.position;
                                    if (pos.maxScrollExtent > 0.5) {
                                      f = 28 / pos.viewportDimension;
                                      topEdge =
                                          1.0 -
                                          (pos.pixels / 48).clamp(0.0, 1.0);
                                      bottomEdge =
                                          1.0 -
                                          ((pos.maxScrollExtent - pos.pixels) /
                                                  48)
                                              .clamp(0.0, 1.0);
                                    }
                                  }
                                  final topOn = topEdge < 1.0;
                                  final bottomOn = bottomEdge < 1.0;
                                  // 两端都在尽头（或不可滚动）：无渐隐，
                                  // 直接返回（也省掉一层 ShaderMask 图层）
                                  if (!topOn && !bottomOn) return child!;
                                  final colors = <Color>[];
                                  final stops = <double>[];
                                  if (topOn) {
                                    colors.add(
                                      Color.fromARGB(
                                        (255 * topEdge).round(),
                                        255,
                                        255,
                                        255,
                                      ),
                                    );
                                    stops.add(0.0);
                                  }
                                  colors
                                    ..add(const Color(0xFFFFFFFF))
                                    ..add(const Color(0xFFFFFFFF));
                                  stops
                                    ..add(topOn ? f : 0.0)
                                    ..add(bottomOn ? 1 - f : 1.0);
                                  if (bottomOn) {
                                    colors.add(
                                      Color.fromARGB(
                                        (255 * bottomEdge).round(),
                                        255,
                                        255,
                                        255,
                                      ),
                                    );
                                    stops.add(1.0);
                                  }
                                  return ShaderMask(
                                    shaderCallback: (rect) => LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: colors,
                                      stops: stops,
                                    ).createShader(rect),
                                    blendMode: BlendMode.dstIn,
                                    child: child,
                                  );
                                },
                                child: SizedBox(
                                  width: double.infinity,
                                  child: NotificationListener<ScrollNotification>(
                                    onNotification: _onScrollNotification,
                                    child: SingleChildScrollView(
                                      controller: _scroll,
                                      // 永远接受滚动手势：默认 Clamping 在边缘
                                      // 会拒绝新手势（竞技场输给外层聊天列表 →
                                      // 到底后再拖会滚动整个屏幕）
                                      physics: AlwaysScrollableScrollPhysics(
                                        parent: ClampingScrollPhysics(),
                                      ),
                                      child: widget.streaming
                                          // 流式：Text（轻量，尾部窗口内）
                                          ? Text(text, style: thinkStyle)
                                          : SelectableText(
                                              text,
                                              style: thinkStyle,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
    ],
    );
    return widget.flat
        ? InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: body,
            ),
          )
        : Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: Colors.grey.withValues(alpha: 0.15), // 中性灰底，不偏蓝
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: body,
                ),
              ),
            ),
          );
  }
}

/// 消息列表项包装：构造参数（消息对象引用 + 索引）不变时跳过
/// 子树 rebuild——流式期间 HomePage 每 33ms setState，静态消息项
/// 的参数完全相同（Message 是可变对象、引用稳定），子树零重建；
/// 正在流式的那条消息 content 在变，但 Flutter 只 rebuild 它一个
class _MessageItem extends StatefulWidget {
  const _MessageItem({
    super.key,
    required this.message,
    required this.index,
    this.editing = false,
    this.branchEditing = false,
    this.streaming = false,
    this.epoch = 0,
  });

  final Message message;
  final int index;

  /// 编辑态（内联编辑器替换气泡）——必须计入签名：
  /// 进入/退出编辑时内容长度不变，漏掉会复用旧气泡导致编辑器不出现
  final bool editing;

  /// 分支编辑态（同上）
  final bool branchEditing;

  /// 正在流式接收（影响打字点/工具栏显隐判定）
  final bool streaming;

  /// 渲染纪元（全局状态版本号）
  final int epoch;

  @override
  State<_MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<_MessageItem> {
  _HomePageState? _home;

  @override
  void initState() {
    super.initState();
    // 首建即固化签名：否则 _sig=-1 时 didUpdateWidget 的
    // 失效守卫不通过——首次点编辑/分支不清缓存，编辑器不出现
    //（表现为「要先点另一个再点才生效」）
    _sig = _signature();
  }

  void _onStreamTick() {
    // 流式帧：签名变化（本条在更新）才自刷新；静态项零成本
    if (_sig >= 0 && _sig != _signature()) {
      setState(() {
        _cached = null;
        _sig = _signature();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final home = _HomePageScope.of(context);
    if (!identical(home, _home)) {
      _home?._streamTick.removeListener(_onStreamTick);
      _home = home;
      home._streamTick.addListener(_onStreamTick);
    }
  }

  @override
  void dispose() {
    _home?._streamTick.removeListener(_onStreamTick);
    super.dispose();
  }

  /// 子树缓存：静态消息项（内容签名未变）直接复用上一帧 Widget，
  /// 跳过 build——流式期间 HomePage 每 33ms setState，只有正在
  /// 生成的那条消息签名变化触发真实 rebuild
  Widget? _cached;
  int _sig = -1;

  /// O(1) 内容签名：流式 append-only，长度即可感知变化；
  /// 编辑/分支切换也伴随长度或 viewPos 变化。误判后果
  /// 只是多/少 build 一帧（视觉无损）。
  /// 工具卡片：ReAct 轮次中 content 不变而 toolCalls 增长/回填
  /// resultCount——必须计入（漏掉时工具分割卡不渲染）
  int _signature() =>
      widget.message.content.length * 31 +
      (widget.message.thinking?.length ?? 0) * 17 +
      widget.message.viewPos * 7 +
      widget.index +
      (widget.message.branches?.length ?? 0) * 3 +
      (widget.message.toolCalls?.length ?? 0) * 101 +
      (widget.editing ? 9973 : 0) +
      (widget.branchEditing ? 9967 : 0) +
      (widget.message.truncated ? 9949 : 0) +
      (widget.message.error ? 9931 : 0) +
      (widget.streaming ? 9923 : 0) +
      (widget.message.imageParts?.length ?? 0) * 9907 +
      (widget.message.fileParts?.length ?? 0) * 9901 +
      (widget.message.toolCalls?.fold<int>(
            0,
            (a, t) => a * 31 + (t.resultCount ?? -1000) + (t.expanded ? 7 : 0),
          ) ??
          0) +
      widget.epoch * 1000003;

  @override
  void didUpdateWidget(_MessageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sig >= 0 && _sig != _signature()) {
      _cached = null;
    }
    _sig = _signature();
  }

  @override
  Widget build(BuildContext context) {
    final home = _HomePageScope.of(context);
    // 已收纳轮次的组内非首成员：外边距归零（渲染为空，不留空带）
    final hidden = home.isCollapsedToolMember(widget.message, widget.index);
    return _cached ??= Padding(
      padding: hidden ? EdgeInsets.zero : const EdgeInsets.only(bottom: 12),
      child: home.buildMessageBubble(context, widget.message, widget.index),
    );
  }
}

/// HomePage State 暴露作用域：让 _MessageItem 等子组件访问其方法
class _HomePageScope extends InheritedWidget {
  const _HomePageScope({super.key, required this.state, required super.child});

  final _HomePageState state;

  static _HomePageState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_HomePageScope>()!.state;

  @override
  bool updateShouldNotify(_HomePageScope oldWidget) =>
      !identical(oldWidget.state, state);
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
  const _ImageFullscreen({required this.images, this.initialIndex = 0});

  /// 当前聊天的全部图片（复用缓存 provider，原图全分辨率）；
  /// 多张可左右滑动浏览
  final List<ImageProvider> images;
  final int initialIndex;

  @override
  State<_ImageFullscreen> createState() => _ImageFullscreenState();
}

class _ImageFullscreenState extends State<_ImageFullscreen> {
  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: PhotoViewGallery.builder(
              pageController: _page,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _index = i),
              builder: (context, i) => PhotoViewGalleryPageOptions(
                imageProvider: widget.images[i],
                // 初始 contain（整图可见，无黑边）；放大上限 8 倍
                initialScale: PhotoViewComputedScale.contained,
                minScale: PhotoViewComputedScale.contained,
                maxScale: 8.0,
                filterQuality: FilterQuality.medium,
                // 点按关闭（双击缩放由 PhotoView 内置处理，不影响单击）
                onTapUp: (_, _, _) => Navigator.of(context).pop(),
                errorBuilder: (context, error, stackTrace) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 64,
                    color: Colors.white54,
                  ),
                ),
              ),
              backgroundDecoration: const BoxDecoration(color: Colors.black),
            ),
          ),
          // 页码指示（多张时）
          if (widget.images.length > 1)
            Positioned(
              bottom: MediaQuery.paddingOf(context).bottom + 20,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_index + 1} / ${widget.images.length}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
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

(String, String) _extractWebHtml(String html) {
  String entities(String x) => x
      .replaceAllMapped(
        RegExp(r'&#x([0-9A-Fa-f]+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
      )
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m.group(1)!)),
      )
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'");
  final title = entities(
        RegExp(
          r'<title[^>]*>([^<]*)</title>',
          caseSensitive: false,
        ).firstMatch(html)?.group(1) ?? '',
      ).trim();
  var h = html
      .replaceAll(
        RegExp(r'<script\b[^>]*>.*?</script>', dotAll: true, caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(r'<style\b[^>]*>.*?</style>', dotAll: true, caseSensitive: false),
        '',
      )
      .replaceAll(
        RegExp(
          r'<(noscript|svg|iframe|nav|header|footer|aside|form)\b[^>]*>.*?</\1>',
          dotAll: true,
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  String? body = RegExp(
    r'<article\b[^>]*>(.*?)</article>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(h)?.group(1);
  body ??= RegExp(
    r'<main\b[^>]*>(.*?)</main>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(h)?.group(1);
  body ??= RegExp(
    r'<body\b[^>]*>(.*?)</body>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(h)?.group(1) ?? h;
  var t = body
      .replaceAll(
        RegExp(
          r'</(p|div|li|tr|h[1-6]|blockquote|section|article|dd|dt)>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  t = entities(t).replaceAll('\u00a0', ' ');
  final lines = t
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .where((l) => l.isNotEmpty)
      .join('\n');
  return (title, lines);
}

/// 批量 bytes → data URL（isolate 内 base64 编码）：多张大图/
/// PDF 整页 PNG 在主线程编码 MB 级数据是发送卡顿源
List<String> _bytesToDataUrls(List<(String, Uint8List)> jobs) => [
  for (final (mime, b) in jobs) 'data:$mime;base64,${base64Encode(b)}',
];

/// 测试导出：HTML 正文提取（_extractWebHtml 为 isolate 顶层用途）
(String, String) extractWebHtmlForTest(String html) =>
    _extractWebHtml(html);

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
          maxWidth: math.max(260, MediaQuery.sizeOf(context).width * 0.82),
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

/// 原图字节 → 压缩 JPEG 字节（isolate 内执行）：解码 + 缩放 +
/// 重编码全在后台，主线程零卡顿
/// 图片压缩（isolate 调用）：原生编解码器优先（Android BitmapFactory
/// + libjpeg，C 实现，快 10-50 倍——截屏等大型 PNG 用纯 Dart image 包
/// 解码动辄数秒甚至失败，是「有图无法上传」的主因），原生失败再回退
/// 纯 Dart。注意：flutter_image_compress 在 isolate 中不可直接用
/// （平台通道），因此此函数跑在主 isolate 的 await 链上——原生压缩
/// 本身在 C 线程执行，不阻塞 UI
Future<Uint8List> compressSingleImageNative(
  Uint8List bytes, {
  required double maxSide,
  required int quality,
}) async {
  try {
    final result = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: maxSide.round(),
      minHeight: maxSide.round(),
      quality: quality,
      format: CompressFormat.jpeg,
    );
    if (result.isNotEmpty) return result;
  } catch (_) {}
  // 回退：纯 Dart（isolate 里执行）
  return compute(_compressSingleImageDart, {
    'bytes': bytes,
    'maxSide': maxSide,
    'quality': quality,
  });
}

Uint8List _compressSingleImageDart(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final maxSide = (args['maxSide'] as num).toDouble();
  final quality = args['quality'] as int;
  final decoded = im.decodeImage(bytes);
  if (decoded == null) return Uint8List(0); // 空 = 失败：原始字节直发会被端点 400
  var img = decoded;
  if (img.width > maxSide || img.height > maxSide) {
    img = im.copyResize(
      img,
      width: img.width >= img.height ? maxSide.round() : null,
      height: img.height > img.width ? maxSide.round() : null,
      interpolation: im.Interpolation.average,
    );
  }
  return Uint8List.fromList(im.encodeJpg(img, quality: quality));
}

/// dataUrl → 原始字节（isolate 内执行）
Uint8List _b64ToBytes(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  return base64Decode(comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl);
}

/// 内存音频源（API 返回的 MP3 字节直接播放，不落盘）
class _BytesAudioSource extends StreamAudioSource {
  _BytesAudioSource(this._bytes);

  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async =>
      StreamAudioResponse(
        sourceLength: _bytes.length,
        contentLength: (end ?? _bytes.length) - (start ?? 0),
        offset: start ?? 0,
        stream: Stream.value(_bytes.sublist(start ?? 0, end ?? _bytes.length)),
        contentType: 'audio/mpeg',
      );
}

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
