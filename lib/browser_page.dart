import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 应用内浏览器（复用系统 WebView 内核，不引入独立浏览器引擎）。
/// markdown 链接等网页打开统一走这里，不再跳出应用；
/// 也可传 [htmlDoc]（HTML 字符串）直接预览（artifacts 等）。
/// - 地址栏：点击进入编辑，回车跳转（自动补 https://）
/// - 网页历史后退/前进 + 刷新/停止 + 进度条
/// - 系统返回手势 = 网页后退，无历史时退出浏览器页
/// - 「外部打开」按钮兜底（默认浏览器；HTML 数据模式不可用）
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, this.url, this.htmlDoc})
      : assert(url != null || htmlDoc != null, 'url 或 htmlDoc 至少一个');

  final String? url;

  /// HTML 字符串直接预览（data URI 加载，走 loadUrl 路径编码正确）
  final String? htmlDoc;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final WebViewController _controller;
  late final TextEditingController _urlCtrl;
  final _urlFocus = FocusNode();

  /// 0-100 加载进度（100 = 完成，进度条隐藏）
  int _progress = 100;

  /// 地址栏编辑态（点击 URL 进入编辑，失焦/跳转退出）
  bool _editing = false;

  bool _canGoBack = false;
  bool _canGoForward = false;

  /// 主文档加载失败信息（非空时覆盖显示错误占位）
  String? _error;

  /// HTML 数据模式（无真实 URL）：地址栏显示占位、不可编辑、不外部打开
  bool get _htmlMode => widget.htmlDoc != null;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.url ?? '');
    _urlFocus.addListener(() {
      if (!_urlFocus.hasFocus && _editing) {
        setState(() => _editing = false);
      }
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(
        Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF121212)
            : Colors.white,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _editing = false;
                _error = null;
                if (!_htmlMode) _urlCtrl.text = url;
              });
            }
          },
          onPageFinished: (url) {
            if (mounted) {
              setState(() => _progress = 100);
            }
            _syncNav();
          },
          onUrlChange: (change) {
            if (mounted && change.url != null) {
              setState(() {
                if (!_editing && !_htmlMode) _urlCtrl.text = change.url!;
              });
            }
            _syncNav();
          },
          onWebResourceError: (e) {
            // 仅主文档失败才整页报错（子资源失败常见且不影响阅读）
            if (mounted && e.isForMainFrame == true) {
              setState(() => _error = e.description);
            }
          },
        ),
      );
    final doc = widget.htmlDoc;
    if (doc != null) {
      _controller.loadRequest(
        Uri.dataFromString(
          doc,
          mimeType: 'text/html',
          encoding: utf8,
          base64: true,
        ),
      );
    } else {
      _controller.loadRequest(Uri.parse(widget.url!));
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _urlFocus.dispose();
    super.dispose();
  }

  Future<void> _syncNav() async {
    final back = await _controller.canGoBack();
    final forward = await _controller.canGoForward();
    if (mounted) {
      setState(() {
        _canGoBack = back;
        _canGoForward = forward;
      });
    }
  }

  /// 地址栏输入跳转：无 scheme 补 https://，非法/非 http(s) 忽略
  void _go(String input) {
    var text = input.trim();
    if (text.isEmpty) return;
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      text = 'https://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return;
    }
    _urlFocus.unfocus();
    _controller.loadRequest(uri);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PopScope(
      // 系统返回手势：优先网页后退，无历史才退出浏览器页
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_canGoBack) {
          _controller.goBack();
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: dark ? const Color(0xFF121212) : Colors.white,
        appBar: AppBar(
          backgroundColor: dark ? const Color(0xFF121212) : Colors.white,
          foregroundColor: scheme.onSurface,
          elevation: 0,
          scrolledUnderElevation: 0,
          // 返回 = 退出浏览器页（区别于网页历史后退按钮）
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          titleSpacing: 0,
          title: _editing
              ? TextField(
                  controller: _urlCtrl,
                  focusNode: _urlFocus,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: scheme.onSurface.withValues(alpha: 0.06),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                )
              : GestureDetector(
                  // HTML 数据模式无真实 URL：地址栏仅展示、不可编辑
                  onTap: _htmlMode
                      ? null
                      : () => setState(() => _editing = true),
                  child: Text(
                    _displayUrl(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
          actions: [
            // 网页历史后退/前进
            IconButton(
              icon: Icon(
                Icons.arrow_back_ios_new,
                size: 18,
                color: _canGoBack
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: 0.3),
              ),
              onPressed: _canGoBack ? () => _controller.goBack() : null,
            ),
            IconButton(
              icon: Icon(
                Icons.arrow_forward_ios,
                size: 18,
                color: _canGoForward
                    ? scheme.onSurface
                    : scheme.onSurface.withValues(alpha: 0.3),
              ),
              onPressed: _canGoForward ? () => _controller.goForward() : null,
            ),
            // 刷新 / 停止
            IconButton(
              icon: Icon(
                _progress >= 100 ? Icons.refresh : Icons.close,
                size: 20,
              ),
              onPressed: () {
                if (_progress >= 100) {
                  _controller.reload();
                } else {
                  // 停止加载（WebView 无 stopLoading 封装：重载当前页代替）
                  _controller.reload();
                }
              },
            ),
            // 外部浏览器兜底（HTML 数据模式：无真实 URL，禁用）
            IconButton(
              icon: const Icon(Icons.open_in_new, size: 18),
              onPressed: _htmlMode
                  ? null
                  : () {
                      final uri = Uri.tryParse(_urlCtrl.text);
                      if (uri != null &&
                          (uri.scheme == 'http' || uri.scheme == 'https')) {
                        launchUrl(uri, mode: LaunchMode.externalApplication);
                      }
                    },
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(2),
            child: _progress >= 100
                ? const SizedBox(height: 2)
                : LinearProgressIndicator(
                    value: _progress / 100,
                    minHeight: 2,
                    backgroundColor: scheme.onSurface.withValues(alpha: 0.1),
                  ),
          ),
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    '页面加载失败\n$_error',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 14,
                    ),
                  ),
                ),
              )
            : WebViewWidget(controller: _controller),
      ),
    );
  }

  /// 地址栏展示形式：HTML 数据模式显示占位；URL 模式优先域名（完整
  /// URL 过长）
  String _displayUrl() {
    if (_htmlMode) return '内置预览';
    final uri = Uri.tryParse(_urlCtrl.text);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }
    return _urlCtrl.text;
  }
}
