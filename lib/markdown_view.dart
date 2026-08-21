import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:highlight/highlight.dart' as hl;
import 'package:markdown/markdown.dart' as md;
import 'package:webview_flutter/webview_flutter.dart';

import 'browser_page.dart';

/// 项目风格 Markdown 渲染组件（助手/用户消息气泡内容）：
/// - 代码块语法高亮（highlight 包，深色块 + VS Code 系配色）
/// - LaTeX 公式（flutter_math_fork；预处理 $...$/$$...$$ → 代码块/行内）
/// - Mermaid 图表（webview_flutter + mermaid.js；点击全屏查看可缩放）
/// - Artifacts 预览（html/svg 代码块下方自动展开 webview 预览）
/// - 链接点击打开（url_launcher；仅 http/https）
/// - 流式渲染节流：markdown 全量重解析 + 高亮限频 ~30fps，尾帧补齐
/// - markdown 图片链接不自动加载，显示为可点击链接（安全）
class MarkdownView extends StatefulWidget {
  const MarkdownView({
    super.key,
    required this.text,
    this.isUser = false,
    this.latexEnabled = false,
    this.mermaidEnabled = false,
    this.artifactsEnabled = false,
  });

  final String text;

  /// 用户消息（蓝底白字气泡 → 白色文字/链接）
  final bool isUser;

  /// LaTeX 公式渲染开关
  final bool latexEnabled;

  /// Mermaid 图表渲染开关
  final bool mermaidEnabled;

  /// Artifacts（html/svg 代码块）自动预览开关
  final bool artifactsEnabled;

  @override
  State<MarkdownView> createState() => _MarkdownViewState();
}

class _MarkdownViewState extends State<MarkdownView> {
  String _text = '';
  Timer? _trailing;
  int _lastRenderMs = 0;

  @override
  void initState() {
    super.initState();
    _text = widget.text;
    _lastRenderMs = DateTime.now().millisecondsSinceEpoch;
  }

  @override
  void didUpdateWidget(MarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != _text) _coalesce();
  }

  /// 流式节流：新文本 33ms 内只重渲一次（~30fps），尾帧 Timer 补齐
  /// 保证最终完整内容必达。markdown 全量重解析 + 代码高亮是流式期间
  /// 最重的开销，节流后长回复滚动/渲染不卡
  void _coalesce() {
    _trailing?.cancel();
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastRenderMs;
    if (elapsed >= 33) {
      _lastRenderMs = now;
      setState(() => _text = widget.text);
    } else {
      _trailing = Timer(Duration(milliseconds: 33 - elapsed), () {
        _lastRenderMs = DateTime.now().millisecondsSinceEpoch;
        if (mounted) setState(() => _text = widget.text);
      });
    }
  }

  @override
  void dispose() {
    _trailing?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget._render(context, _text);
}

extension _MarkdownViewRender on MarkdownView {
  /// 渲染主体（State 持节流后的 [text] 调用）
  Widget _render(BuildContext context, String text) {
    final theme = Theme.of(context);
    final textColor = isUser ? Colors.white : theme.colorScheme.onSurface;
    final linkColor = isUser
        ? Colors.white70
        : theme.colorScheme.primary.withValues(alpha: 0.9);

    // LaTeX 预处理：把 $...$ / $$...$$ 转成代码块/行内代码占位（builder 内识别）
    final data = latexEnabled
        ? _preprocessLatex(text)
        : (text.isEmpty ? ' ' : text);

    return MarkdownBody(
      data: data,
      selectable: true,
      softLineBreak: true,
      onTapLink: (text, href, title) => _openLink(context, href),
      sizedImageBuilder: (config) =>
          _imageAsLink(context, config.uri, config.alt),
      builders: {
        'pre': _CodeBlockBuilder(
          textColor: textColor,
          mermaidEnabled: mermaidEnabled,
          artifactsEnabled: artifactsEnabled,
          isDark: theme.brightness == Brightness.dark,
        ),
        if (latexEnabled) 'code': _InlineCodeBuilder(textColor: textColor),
      },
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(height: 1.5, color: textColor),
        strong: TextStyle(color: textColor, fontWeight: FontWeight.w700),
        em: const TextStyle(fontStyle: FontStyle.italic),
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12.5,
          color: textColor,
          backgroundColor: Colors.black.withValues(alpha: 0.1),
        ),
        h1: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: textColor,
          height: 1.4,
        ),
        h2: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: textColor,
          height: 1.4,
        ),
        h3: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          color: textColor,
          height: 1.4,
        ),
        h4: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
          color: textColor,
          height: 1.4,
        ),
        h5: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.4,
        ),
        h6: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: textColor.withValues(alpha: 0.8),
          height: 1.4,
        ),
        blockquote: TextStyle(
          color: textColor.withValues(alpha: 0.7),
          fontStyle: FontStyle.italic,
          height: 1.5,
        ),
        blockquoteDecoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: Colors.grey.withValues(alpha: 0.6),
              width: 3,
            ),
          ),
        ),
        // 去掉 flutter_markdown 给 pre 块包的原生背景层：
        // styleSheet 会与 Material 回退样式 merge（null 字段被默认值填充，
        // 不能用 null），用显式透明装饰覆盖默认卡片底
        codeblockDecoration: const BoxDecoration(color: Colors.transparent),
        codeblockPadding: EdgeInsets.zero,
        listBullet: TextStyle(color: linkColor),
        tableHead: TextStyle(fontWeight: FontWeight.bold, color: textColor),
        tableBody: TextStyle(color: textColor),
        tableBorder: TableBorder.all(color: Colors.grey.withValues(alpha: 0.3)),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 4,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.grey.withValues(alpha: 0.4)),
          ),
        ),
        a: TextStyle(color: linkColor, decoration: TextDecoration.underline),
      ),
    );
  }

  /// LaTeX 预处理：
  /// - block 公式 `$$...$$` → fenced code block ```latex\n...\n```
  /// - inline 公式 `$...$` → inline code `LATEX:...`
  /// 正则非贪婪、不跨行（inline），避免误吞普通 $ 符号
  String _preprocessLatex(String input) {
    var out = input;
    // block 先（$$ ... $$）
    out = out.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$'),
      (m) => '\n```latex\n${m.group(1)!.trim()}\n```\n',
    );
    // inline（$ ... $），不跨行、不吞已处理的 LATEX: 前缀
    out = out.replaceAllMapped(
      RegExp(r'(?<!\$)\$(?!\$)([^\$\n]+?)\$(?!\$)'),
      (m) => '`LATEX:${m.group(1)}`',
    );
    return out;
  }

  /// 打开链接（仅 http/https）：应用内浏览器打开（Via 思路：复用
  /// 系统 WebView，零额外体积），不再跳出应用
  Future<void> _openLink(BuildContext context, String? href) async {
    if (href == null || href.isEmpty) return;
    final uri = Uri.tryParse(href);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => BrowserPage(url: href)));
  }

  /// 图片链接：不自动加载网络图，显示为可点击链接（安全）
  Widget _imageAsLink(BuildContext context, Uri uri, String? alt) {
    return InkWell(
      onTap: () => _openLink(context, uri.toString()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, size: 14),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                (alt != null && alt.isNotEmpty) ? alt : uri.toString(),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 统一代码块 builder（替换默认 pre 渲染）。
/// 按语言分发：latex → Math.tex / mermaid → _MermaidDiagram /
/// html/svg + artifactsEnabled → 代码高亮 + _ArtifactPreview / 其他 → 高亮
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({
    required this.textColor,
    required this.mermaidEnabled,
    required this.artifactsEnabled,
    required this.isDark,
  });

  final Color textColor;
  final bool mermaidEnabled;
  final bool artifactsEnabled;
  final bool isDark;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    // 语言：pre 下 code 子元素的 class="language-xxx"
    var lang = '';
    for (final c in element.children ?? const <md.Node>[]) {
      if (c is md.Element && c.tag == 'code') {
        lang = (c.attributes['class'] ?? '')
            .replaceFirst('language-', '')
            .trim();
        break;
      }
    }
    final code = element.textContent.replaceAll(RegExp(r'\n$'), '');

    // LaTeX block：Math.tex 渲染公式
    if (lang == 'latex' || lang == 'tex' || lang == 'math') {
      return _latexBlock(code);
    }

    // Mermaid：共享无头 WebView 光栅化为 PNG 后原生显示
    if (lang == 'mermaid' && mermaidEnabled) {
      return _MermaidDiagram(
        source: code,
        isDark: isDark,
        fallback: _highlightBlock(code, 'mermaid'),
      );
    }

    // Artifacts：html/svg 代码块下方加预览面板
    if (artifactsEnabled && (lang == 'html' || lang == 'svg')) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _highlightBlock(code, lang),
          const SizedBox(height: 8),
          _ArtifactPreview(code: code, language: lang, isDark: isDark),
        ],
      );
    }

    return _highlightBlock(code, lang);
  }

  /// LaTeX block 公式渲染（沉浸式居中，无独立背景；解析失败显示原始文本）
  Widget _latexBlock(String formula) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Math.tex(
          formula.trim(),
          textStyle: TextStyle(fontSize: 16, color: textColor),
          onErrorFallback: (_) => SelectableText(
            formula,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
        ),
      ),
    );
  }

  /// 普通代码块高亮（深色块 + VS Code Dark+ 配色）
  Widget _highlightBlock(String code, String lang) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SelectableText.rich(
        TextSpan(
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            height: 1.5,
            color: Color(0xFFD4D4D4),
          ),
          children: _highlight(code, lang),
        ),
      ),
    );
  }

  List<TextSpan> _highlight(String code, String lang) {
    final result = hl.highlight.parse(
      code.isEmpty ? ' ' : code,
      language: lang.isEmpty ? 'plaintext' : lang,
    );
    return _nodesToSpans(result.nodes ?? const []);
  }

  List<TextSpan> _nodesToSpans(List<hl.Node> nodes) {
    return [
      for (final n in nodes)
        TextSpan(
          text: n.value,
          children: (n.value == null && n.children != null)
              ? _nodesToSpans(n.children!)
              : null,
          style: (n.className != null && n.className!.isNotEmpty)
              ? TextStyle(
                  color: _hlColor(n.className!.replaceFirst('hljs-', '')),
                )
              : null,
        ),
    ];
  }

  /// VS Code Dark+ 系配色
  Color? _hlColor(String? cls) {
    return switch (cls) {
      'keyword' ||
      'built_in' ||
      'literal' ||
      'meta' ||
      'symbol' => const Color(0xFF569CD6),
      'string' || 'regexp' || 'char' => const Color(0xFFCE9178),
      'comment' || 'quote' => const Color(0xFF6A9955),
      'number' => const Color(0xFFB5CEA8),
      'title' ||
      'function_' ||
      'class_' ||
      'type' ||
      'selector-tag' ||
      'attribute' => const Color(0xFFDCDCAA),
      'params' || 'attr' => const Color(0xFF9CDCFE),
      'name' || 'tag' || 'variable' => const Color(0xFF4EC9B0),
      _ => null,
    };
  }
}

/// 行内 code builder：识别 LATEX: 前缀 → Math.tex 行内公式，否则默认渲染。
/// 注意：flutter_markdown 对 inline code 返回 Widget 会以 WidgetSpan 嵌入，
/// 这是渲染行内公式的可行方式
class _InlineCodeBuilder extends MarkdownElementBuilder {
  _InlineCodeBuilder({required this.textColor});

  final Color textColor;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final text = element.textContent;
    if (text.startsWith('LATEX:')) {
      final formula = text.substring(6);
      return Math.tex(
        formula,
        textStyle: TextStyle(fontSize: 14, color: textColor),
        mathStyle: MathStyle.text,
        onErrorFallback: (_) => Text(
          '\$$formula\$',
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12.5,
            color: textColor,
          ),
        ),
      );
    }
    return null; // 默认渲染（让 flutter_markdown 用 styleSheet.code 样式）
  }
}

/// Mermaid 图表：每图一个挂载的 WebView（全图表类型支持；
/// ListView 惰性构建 = 自动按需创建）。渲染完成后 JS 经 mermaidSize
/// 通道上报内容真实高度，容器自适应（上限 640，超高内部滚动）；
/// 光栅化结果：2x PNG 字节 + 自然逻辑尺寸
typedef _MermaidRaster = ({Uint8List bytes, double w, double h});

/// Mermaid 图表：内联 WebView 渲染（全图表类型支持），渲染完成即
/// 自我光栅化为 PNG 并替换成原生 Image——列表滚动不再携带 WebView
/// （platform view 合成是滚动掉帧主因）。结果按「源码+主题」缓存，
/// 再次进入会话直接显示图片、不建 WebView。光栅化失败则回退保留
/// WebView 展示；点击卡片全屏查看（图片模式支持捏合缩放）
class _MermaidDiagram extends StatefulWidget {
  const _MermaidDiagram({
    required this.source,
    required this.isDark,
    required this.fallback,
  });

  final String source;
  final bool isDark;

  /// 渲染失败时显示的源码高亮块（由 _CodeBlockBuilder 传入）
  final Widget fallback;

  @override
  State<_MermaidDiagram> createState() => _MermaidDiagramState();
}

class _MermaidDiagramState extends State<_MermaidDiagram> {
  /// 应用级光栅化缓存：字节封顶 24MB、条目封顶 12——超限按插入序
  /// 淘汰最旧（重建只需一次 WebView 渲染，功能无损）
  static final Map<String, _MermaidRaster> _rasterCache = {};
  static int _rasterCacheBytes = 0;

  /// 缓存淘汰：保持总字节 ≤ 24MB 且条目 ≤ 12
  static void _evictRasterCache() {
    while (_rasterCache.isNotEmpty &&
        (_rasterCache.length > 12 || _rasterCacheBytes > 24 << 20)) {
      final oldest = _rasterCache.keys.first;
      _rasterCacheBytes -= _rasterCache.remove(oldest)!.bytes.length;
    }
  }

  String get _cacheKey => '${widget.isDark ? 'd' : 'l'}\n${widget.source}';

  WebViewController? _controller;

  /// 光栅化结果（非空后 WebView 卸载，改显示原生 Image）
  _MermaidRaster? _raster;

  /// 加载中的初始高度；JS 上报后更新为内容真实高度（60-640 区间）
  double _height = 200;

  @override
  void initState() {
    super.initState();
    final cached = _rasterCache[_cacheKey];
    if (cached != null) {
      _raster = cached;
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      // JS console 转发到 Flutter 日志（adb logcat 可诊断）
      ..setOnConsoleMessage((m) => debugPrint('[mermaid-web] ${m.message}'))
      ..addJavaScriptChannel(
        'mermaidSize',
        onMessageReceived: (m) {
          final h = double.tryParse(m.message) ?? 0;
          if (h > 0 && mounted) {
            setState(() => _height = h.clamp(60.0, 640.0));
          }
        },
      )
      ..addJavaScriptChannel(
        'mermaidPng',
        onMessageReceived: (m) {
          final data = jsonDecode(m.message) as Map<String, dynamic>;
          final png = data['png'];
          debugPrint(
            '[mermaid-png] ok=${png is String} w=${data['w']} h=${data['h']} '
            'err=${data['error']} skip=${data['skip']}',
          );
          // 超大 PNG 直接丢弃（双保险：超大 base64 传输会打爆
          // WebView 堆导致 OOM 闪退），保留 WebView 展示
          if (png is String && png.length > 8 * 1024 * 1024) {
            debugPrint('[mermaid-png] drop oversized png');
            return;
          }
          if (png is String && data['w'] is num && data['h'] is num) {
            final b64 = png.replaceFirst(
              RegExp(r'^data:image/png;base64,'),
              '',
            );
            final raster = (
              bytes: base64Decode(b64),
              w: (data['w'] as num).toDouble(),
              h: (data['h'] as num).toDouble(),
            );
            _evictRasterCache();
            _rasterCache[_cacheKey] = raster;
            _rasterCacheBytes += raster.bytes.length;
            _evictRasterCache();
            if (mounted) {
              setState(() {
                _raster = raster;
                // 光栅化成功：释放 WebView（列表不再携带 platform view，
                // 控制器与渲染进程资源随之回收）
                _controller = null;
              });
            }
          }
          // skip/error：保留 WebView 展示（现有渲染已可见）
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            final c = _controller;
            if (c == null) return;
            // 转义单引号/反斜杠/换行（含 CR LF），安全注入 JS 字符串
            final escaped = widget.source
                .replaceAll('\\', '\\\\')
                .replaceAll("'", "\\'")
                .replaceAll('\r', '\\r')
                .replaceAll('\n', '\\n');
            c.runJavaScript(
              "runMermaid(0, '$escaped', ${widget.isDark}, true);",
            );
          },
        ),
      )
      ..loadFlutterAsset('assets/mermaid.html');
  }

  void _openViewer(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _MermaidViewerPage(
          source: widget.source,
          isDark: widget.isDark,
          raster: _raster,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 点击卡片全屏查看（图片模式捏合缩放）
      onTap: () => _openViewer(context),
      child: Stack(
        children: [
          if (_raster case final r?)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(vertical: 6),
              clipBehavior: Clip.antiAlias,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: widget.isDark
                    ? const Color(0xFF1A1A1A)
                    : const Color(0xFFFAFAFA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scale = math.min(1.0, constraints.maxWidth / r.w);
                  return Image.memory(
                    r.bytes,
                    width: r.w * scale,
                    height: r.h * scale,
                    fit: BoxFit.fill,
                    gaplessPlayback: true,
                  );
                },
              ),
            )
          else if (_controller case final c?)
            Container(
              width: double.infinity,
              height: _height,
              margin: const EdgeInsets.symmetric(vertical: 6),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: widget.isDark
                    ? const Color(0xFF1A1A1A)
                    : const Color(0xFFFAFAFA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
              ),
              child: WebViewWidget(controller: c),
            ),
          // 右上角放大提示角标（可点开全屏）
          Positioned(
            top: 10,
            right: 10,
            child: IgnorePointer(
              child: Icon(
                Icons.open_in_full,
                size: 14,
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mermaid 全屏查看页：优先显示光栅化图片（InteractiveViewer 捏合缩放，
/// 丝滑无 WebView）；无光栅化结果时回退 WebView 全屏渲染
class _MermaidViewerPage extends StatefulWidget {
  const _MermaidViewerPage({
    required this.source,
    required this.isDark,
    this.raster,
  });

  final String source;
  final bool isDark;
  final _MermaidRaster? raster;

  @override
  State<_MermaidViewerPage> createState() => _MermaidViewerPageState();
}

class _MermaidViewerPageState extends State<_MermaidViewerPage> {
  _MermaidRaster? _raster;
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    _raster = widget.raster;
    if (_raster != null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(
        widget.isDark ? const Color(0xFF121212) : Colors.white,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            final c = _controller;
            if (c == null) return;
            final escaped = widget.source
                .replaceAll('\\', '\\\\')
                .replaceAll("'", "\\'")
                .replaceAll('\r', '\\r')
                .replaceAll('\n', '\\n');
            c.runJavaScript(
              "runMermaid(1, '$escaped', ${widget.isDark}, true);",
            );
          },
        ),
      )
      ..addJavaScriptChannel(
        'mermaidPng',
        onMessageReceived: (m) {
          final data = jsonDecode(m.message) as Map<String, dynamic>;
          final png = data['png'];
          if (png is String && data['w'] is num && data['h'] is num) {
            final b64 = png.replaceFirst(
              RegExp(r'^data:image/png;base64,'),
              '',
            );
            if (mounted) {
              setState(() {
                _raster = (
                  bytes: base64Decode(b64),
                  w: (data['w'] as num).toDouble(),
                  h: (data['h'] as num).toDouble(),
                );
                _controller = null;
              });
            }
          }
        },
      )
      ..loadFlutterAsset('assets/mermaid.html');
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.isDark ? const Color(0xFF121212) : Colors.white;
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Stack(
          children: [
            if (_raster case final r?)
              Center(
                child: InteractiveViewer(
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(double.infinity),
                  minScale: 0.3,
                  maxScale: 6,
                  child: Builder(
                    builder: (context) {
                      final size = MediaQuery.sizeOf(context);
                      final s = math.min(
                        math.min(1.0, size.width / r.w),
                        size.height / r.h,
                      );
                      return Image.memory(
                        r.bytes,
                        width: r.w * s,
                        height: r.h * s,
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                      );
                    },
                  ),
                ),
              )
            else if (_controller case final c?)
              WebViewWidget(controller: c),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Artifacts 预览面板：html 直接渲染 / svg 包一层 HTML。
/// 默认展开，带「收起/展开」按钮 + 「在浏览器打开」
class _ArtifactPreview extends StatefulWidget {
  const _ArtifactPreview({
    required this.code,
    required this.language,
    required this.isDark,
  });

  final String code;
  final String language;
  final bool isDark;

  @override
  State<_ArtifactPreview> createState() => _ArtifactPreviewState();
}

class _ArtifactPreviewState extends State<_ArtifactPreview> {
  // 默认收起：只显示工具栏，展开由用户点击（内容大/多时不占列表空间）
  bool _expanded = false;
  WebViewController? _controller;

  String get _htmlDoc {
    if (widget.language == 'svg') {
      return '<!DOCTYPE html><html><body style="margin:0;padding:8;'
          'background:${widget.isDark ? "#1a1a1a" : "#fafafa"};">'
          '${widget.code}</body></html>';
    }
    return widget.code;
  }

  void _ensureController() {
    if (_controller != null) return;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      // 不用 loadHtmlString：其底层 loadDataWithBaseURL 的 encoding 为
      // null，Android 按 Latin-1 解码，含中文的 HTML 乱码/空白。
      // data URI（base64）走 loadUrl 路径，编码正确且兼容性好
      ..loadRequest(
        Uri.dataFromString(
          _htmlDoc,
          mimeType: 'text/html',
          encoding: utf8,
          base64: true,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    // 懒创建：默认收起时不建 WebView 控制器（不占内存/不加载）
    if (_expanded) _ensureController();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: widget.isDark
            ? const Color(0xFF1A1A1A)
            : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 工具栏：预览标签 + 收起/展开 + 浏览器打开
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.visibility_outlined,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '预览',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // 内置浏览器打开（HTML 数据模式，全屏 + 可缩放）
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BrowserPage(htmlDoc: _htmlDoc),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Icon(
                      Icons.open_in_full,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_expanded)
            SizedBox(
              height: 240,
              child: WebViewWidget(controller: _controller!),
            ),
        ],
      ),
    );
  }
}
