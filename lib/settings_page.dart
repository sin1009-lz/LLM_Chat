import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import 'chat.dart'
    show
        ChatStore,
        Conversation,
        McpServer,
        ModelProvider,
        ProviderModel,
        TextReplaceRule,
        parseMcpServersJson;
import 'general_settings.dart';
import 'ui_tokens.dart';
import 'mcp.dart' show McpClient;

/// ── 项目视觉常量（与 main.dart 一致）──
const Color _bgDark = Color(0xFF161616);

/// ── 项目风格共享组件 ──

/// 页面背景色：亮色纯白 / 暗色与主页面背景一致
Color _pageColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? _bgDark : Colors.white;

/// 项目卡片底：白色半透明（暗色反白半透明），圆角 14，与抽屉历史对话容器一致
Color _cardColor(BuildContext context) => Colors.white.withValues(
  alpha: Theme.of(context).brightness == Brightness.dark ? 0.12 : 0.5,
);

/// 项目按钮底：灰色半透明，圆角 14，与面板按钮一致
Color _buttonColor(BuildContext context) => Colors.grey.withValues(alpha: 0.15);

/// 复制模型并保留全部能力字段（多模态/工具/思考/上下文窗口）——
/// 手动设置的能力在回调/页面副本转换时必须原样传递才能生效保存
ProviderModel _copyProviderModel(ProviderModel m) => ProviderModel(
  id: m.id,
  displayName: m.displayName,
  supportsMultimodal: m.supportsMultimodal,
  supportsTools: m.supportsTools,
  supportsThinking: m.supportsThinking,
  contextWindow: m.contextWindow,
);

/// 项目风格页面框架（背景 + 页眉同色，无阴影）。
/// 顶层把主题 primary 覆盖为中性色（onSurface）：设置页所有默认控件色
/// （涟漪/文字/选中态等）统一灰白体系，不再出现主题蓝紫
Widget _projectScaffold({
  required BuildContext context,
  required String title,
  required Widget body,
  Widget? bottom,
}) {
  final color = _pageColor(context);
  return Theme(
    data: Theme.of(context).copyWith(
      colorScheme: Theme.of(
        context,
      ).colorScheme.copyWith(primary: Theme.of(context).colorScheme.onSurface),
    ),
    child: Scaffold(
      backgroundColor: color,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: color,
        foregroundColor: Theme.of(context).colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: body,
      bottomNavigationBar: bottom,
    ),
  );
}

/// 项目风格输入框：灰色填充 + 圆角 14，无边框线（与面板按钮同色系）
Widget _projectInput({
  required BuildContext context,
  required TextEditingController controller,
  required String label,
  String? hint,
  bool obscure = false,
  bool autofocus = false,
  bool enabled = true,
  int? maxLines = 1,
  TextInputType? keyboardType,
  String? errorText,
  ValueChanged<String>? onChanged,
}) {
  return TextField(
    controller: controller,
    obscureText: obscure,
    autofocus: autofocus,
    enabled: enabled,
    maxLines: maxLines,
    keyboardType: keyboardType,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      // 标签灰字（不随聚焦变主题蓝）
      labelStyle: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      floatingLabelStyle: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      hintText: hint,
      errorText: errorText,
      filled: true,
      fillColor: _buttonColor(context),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
        ),
      ),
    ),
  );
}

Widget _switchTile(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
  bool enabled = true,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  // 药丸型开关（灰白体系，深色模式适配）：浅灰/深灰底 + 细外框 +
  // 深灰/浅灰圆；开启/关闭同款（显式 trackOutlineColor 覆盖 M3
  // 开启态透明描边），状态由圆钮位置区分
  final thumb = dark ? Colors.grey.shade300 : Colors.grey.shade800;
  final track = dark ? Colors.grey.shade700 : Colors.grey.shade300;
  final outline = Colors.grey.shade500;
  return Opacity(
    // 受总开关控制（如内置工具总关时明细开关置灰）
    opacity: enabled ? 1 : 0.4,
    child: Material(
      color: _buttonColor(context),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: enabled ? () => onChanged(!value) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: value,
                onChanged: enabled ? onChanged : null,
                activeThumbColor: thumb,
                inactiveThumbColor: thumb,
                trackColor: WidgetStatePropertyAll(track),
                trackOutlineColor: WidgetStatePropertyAll(outline),
                trackOutlineWidth: const WidgetStatePropertyAll(1.0),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 项目风格全宽大按钮（灰色半透明 + 圆角 14 + 水波纹，与面板大按钮一致）
Widget _primaryButton({
  required BuildContext context,
  required String label,
  required VoidCallback onPressed,
}) {
  return Material(
    color: _buttonColor(context),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onPressed,
      child: SizedBox(
        height: 48,
        child: Center(
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
          ),
        ),
      ),
    ),
  );
}

/// 项目风格列表项（灰色半透明底 + 圆角 14 + 水波纹，与面板按钮一致）
Widget _projectTile({
  required BuildContext context,
  required Widget leading,
  required Widget title,
  required Widget subtitle,
  required VoidCallback onTap,
  Widget? trailing,
}) {
  return Material(
    color: _buttonColor(context),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, const SizedBox(height: 2), subtitle],
              ),
            ),
            trailing ?? const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    ),
  );
}

/// 设置页可直达的子页面（长按页眉按钮等入口直接定位）
enum SettingsSection { main, providers, mcp, general }

/// ── 设置页 ──
class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.providers,
    required this.onProvidersChanged,
    required this.replaceRules,
    required this.onReplaceRulesChanged,
    required this.mcpServers,
    required this.onMcpServersChanged,
    required this.generalSettings,
    required this.onGeneralSettingsChanged,
    required this.availableModels,
    required this.onArchivedChanged,
    this.archived = const [],
    this.store,
    this.initialSection = SettingsSection.main,
  });

  /// 模型提供方列表（由 HomePage 持有并持久化）
  final List<ModelProvider> providers;

  /// 提供方列表变更回调（HomePage 立即生效 + 存档）
  final ValueChanged<List<ModelProvider>> onProvidersChanged;

  /// 文字替换规则（显示层替换；由 HomePage 持有并持久化）
  final List<TextReplaceRule> replaceRules;

  /// 文字替换规则变更回调（HomePage 立即生效 + 存档）
  final ValueChanged<List<TextReplaceRule>> onReplaceRulesChanged;

  /// MCP 服务器列表（由 HomePage 持有并持久化）
  final List<McpServer> mcpServers;

  /// MCP 服务器列表变更回调（HomePage 立即生效 + 存档）
  final ValueChanged<List<McpServer>> onMcpServersChanged;

  /// 进入后直接定位到的子页面（main = 显示设置列表）
  final SettingsSection initialSection;

  /// 通用设置（粘贴/标题策略/AI标题/渲染开关）
  final GeneralSettings generalSettings;

  /// 通用设置变更回调（HomePage 立即生效 + 存档）
  final ValueChanged<GeneralSettings> onGeneralSettingsChanged;

  /// 可用模型列表（AI 标题模型下拉数据源）
  final List<String> availableModels;

  /// 归档对话管理改动后回调（HomePage 重载会话列表）
  final VoidCallback onArchivedChanged;

  /// 归档会话列表（HomePage 内存缓存，构造传入——进入零延迟）
  final List<Conversation> archived;

  /// 会话存储（HomePage 持有；恢复/删除归档对话用）
  final ChatStore? store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 文字替换规则数（从规则页返回后刷新；避免副标题显示过期值）
  late int _ruleCount = widget.replaceRules.length;

  /// 提供方列表（来自主页面持久化配置的副本，改动即回调主页面）
  late final List<ModelProvider> _providers = widget.providers
      .map(
        (p) => ModelProvider(
          name: p.name,
          baseUrl: p.baseUrl,
          apiKey: p.apiKey,
          isPreset: p.isPreset,
          models: p.models.map((m) => _copyProviderModel(m)).toList(),
        ),
      )
      .toList();

  @override
  void initState() {
    super.initState();
    // 直达子页面：首帧后自动推入（长按页眉按钮等入口）。
    // 用 pushReplacement 替换掉本页（设置主页），使侧滑返回直接回到
    // 主页面，而不是先回设置主页
    if (widget.initialSection != SettingsSection.main) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        switch (widget.initialSection) {
          case SettingsSection.providers:
            _openProviders(replace: true);
          case SettingsSection.mcp:
            _openMcp(replace: true);
          case SettingsSection.general:
            _openGeneral(replace: true);
          case SettingsSection.main:
            break;
        }
      });
    }
  }

  /// 进入模型提供方列表页（[replace] = 直达入口：替换本页，返回直接回主页面）
  void _openProviders({bool replace = false}) {
    final route = MaterialPageRoute(
      builder: (_) => _ProviderListPage(
        providers: _providers,
        onChanged: () {
          // 提供方/模型变更：立即回调主页面（生效 + 存档）
          widget.onProvidersChanged(
            _providers
                .map(
                  (p) => ModelProvider(
                    name: p.name,
                    baseUrl: p.baseUrl,
                    apiKey: p.apiKey,
                    isPreset: p.isPreset,
                    models: p.models.map((m) => _copyProviderModel(m)).toList(),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
    final nav = Navigator.of(context);
    if (replace) {
      nav.pushReplacement(route);
    } else {
      nav.push(route);
    }
  }

  /// 进入 MCP 服务器列表页（[replace] = 直达入口：替换本页，返回直接回主页面）
  void _openMcp({bool replace = false}) {
    final nav = Navigator.of(context);
    final route = MaterialPageRoute(
      builder: (_) => _McpServerListPage(
        servers: widget.mcpServers,
        onChanged: widget.onMcpServersChanged,
      ),
    );
    if (replace) {
      nav.pushReplacement(route);
    } else {
      nav.push(route);
    }
    // 返回后刷新副标题（服务器可能变更）
    if (mounted) setState(() {});
  }

  /// 进入语音朗读设置页
  void _openTts() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _TtsSettingsPage(
          settings: widget.generalSettings,
          onChanged: widget.onGeneralSettingsChanged,
        ),
      ),
    );
  }

  /// 进入归档对话管理页：数据由 HomePage 构造传入（内存缓存），
  /// 与其他设置子页一致——点击立即 push，滑入即有完整内容
  void _openArchived() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _ArchivedConversationsPage(
          archived: widget.archived,
          store: widget.store,
          onChanged: widget.onArchivedChanged,
        ),
      ),
    );
  }

  /// 进入通用设置页（[replace] = 直达入口：替换本页，返回直接回主页面）
  void _openGeneral({bool replace = false}) {
    final route = MaterialPageRoute(
      builder: (_) => _GeneralSettingsPage(
        settings: widget.generalSettings,
        availableModels: widget.availableModels,
        onChanged: widget.onGeneralSettingsChanged,
      ),
    );
    final nav = Navigator.of(context);
    if (replace) {
      nav.pushReplacement(route);
    } else {
      nav.push(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 直达子页面（长按页眉等入口）：本页只是跳板，首帧返回空白——
    // postFrameCallback 会立即把它替换为真正的子页，避免闪出设置主页
    if (widget.initialSection != SettingsSection.main) {
      return const SizedBox.shrink();
    }
    return _projectScaffold(
      context: context,
      title: '设置',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 通用设置：粘贴、标题、渲染（置于设置页顶端）
          _projectTile(
            context: context,
            leading: Icon(
              Icons.tune,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              '通用',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '粘贴、标题、渲染、内置工具、归档',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: _openGeneral,
          ),
          const SizedBox(height: 12),
          _projectTile(
            context: context,
            leading: Icon(
              Icons.smart_toy_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              '模型提供方',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '管理模型提供方与模型',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: _openProviders,
          ),
          const SizedBox(height: 12),
          _projectTile(
            context: context,
            leading: Icon(
              Icons.find_replace,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              '文字替换',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '$_ruleCount 条规则：显示文本与模型文本双向替换',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _ReplaceRulePage(
                    rules: widget.replaceRules,
                    onChanged: widget.onReplaceRulesChanged,
                  ),
                ),
              );
              // 从规则页返回：刷新规则数（HomePage 原地更新了同一列表）
              if (mounted) {
                setState(() => _ruleCount = widget.replaceRules.length);
              }
            },
          ),
          const SizedBox(height: 12),
          // MCP 服务器：配置外部工具服务
          _projectTile(
            context: context,
            leading: Icon(
              Icons.hub_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              'MCP 服务器',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              () {
                final total = widget.mcpServers.length;
                final on = widget.mcpServers.where((s) => s.enabled).length;
                return total == 0 ? '未配置服务器' : '已配置 $total 个（启用 $on）';
              }(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: _openMcp,
          ),
          const SizedBox(height: 12),
          // 语音朗读（TTS）：独立设置页
          _projectTile(
            context: context,
            leading: Icon(
              Icons.volume_up_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              '语音朗读',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '朗读回复（在线合成 / 系统引擎）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: _openTts,
          ),
          const SizedBox(height: 12),
          // 归档对话管理：查看、恢复或永久删除归档的对话
          _projectTile(
            context: context,
            leading: Icon(
              Icons.archive_outlined,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            title: Text(
              '归档对话',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '查看、恢复或删除归档的对话',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: _openArchived,
          ),
        ],
      ),
    );
  }
}

/// ── 文字替换规则管理页 ──
class _ReplaceRulePage extends StatefulWidget {
  const _ReplaceRulePage({required this.rules, required this.onChanged});

  final List<TextReplaceRule> rules;
  final ValueChanged<List<TextReplaceRule>> onChanged;

  @override
  State<_ReplaceRulePage> createState() => _ReplaceRulePageState();
}

class _ReplaceRulePageState extends State<_ReplaceRulePage> {
  /// 本地规则副本（改动即回调 HomePage 持久化）
  late final List<TextReplaceRule> _rules = widget.rules
      .map(
        (r) => TextReplaceRule(
          display: r.display,
          model: r.model,
          enabled: r.enabled,
        ),
      )
      .toList();

  /// 内联编辑中的规则索引（null = 无）
  int? _editingIndex;

  /// 长按显示的删除键（规则索引；null = 隐藏）
  int? _longPressedIndex;

  void _emit() => widget.onChanged(_rules);

  /// 新增规则（空规则进入内联编辑）
  void _addRule() {
    setState(() {
      _rules.add(TextReplaceRule(display: '', model: ''));
      _editingIndex = _rules.length - 1;
    });
  }

  /// 删除规则
  void _deleteRule(int index) {
    setState(() {
      _rules.removeAt(index);
      if (_editingIndex == index) _editingIndex = null;
    });
    _emit();
  }

  /// 结束编辑：退出编辑态；完全空白的新增规则一并移除
  void _finishEdit(int index) {
    setState(() {
      _editingIndex = null;
      final r = _rules[index];
      if (r.display.isEmpty && r.model.isEmpty) _rules.removeAt(index);
    });
  }

  /// 规则行（普通态：显示 与 模型 两个字段；编辑态：输入即自动保存）
  Widget _ruleRow(BuildContext context, int index) {
    final rule = _rules[index];
    // 内联编辑态：两个输入框（输入即生效并持久化，退出页面不丢失）
    if (_editingIndex == index) {
      final displayCtrl = TextEditingController(text: rule.display);
      final modelCtrl = TextEditingController(text: rule.model);
      // 实时保存：任意输入立即更新规则并落库
      void sync() {
        _rules[index]
          ..display = displayCtrl.text
          ..model = modelCtrl.text;
        _emit();
      }

      return Material(
        color: _buttonColor(context),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _projectInput(
                context: context,
                controller: displayCtrl,
                label: '显示文本',
                hint: '如：用户',
                autofocus: true,
                onChanged: (_) => sync(),
              ),
              const SizedBox(height: 8),
              _projectInput(
                context: context,
                controller: modelCtrl,
                label: '模型文本',
                hint: '如：user',
                onChanged: (_) => sync(),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant, // 灰色，非主题蓝
                    ),
                    onPressed: () => _finishEdit(index),
                    child: const Text('完成'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    // 普通态：开关在行右侧 + 显示字段 与 模型字段；
    // 长按进入删除确认态（水波扩散 + 卡片变暗，同归档对话）
    return _RuleRow(
      rule: rule,
      longPressed: _longPressedIndex == index,
      onTap: () {
        setState(() => _longPressedIndex = null);
        _editingIndex = index;
      },
      onLongPress: () => setState(() => _longPressedIndex = index),
      onToggle: (v) {
        setState(() => rule.enabled = v);
        _emit();
      },
      onDelete: () => _deleteRule(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _projectScaffold(
      context: context,
      title: '文字替换',
      // 点击空白处退出长按删除状态
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _longPressedIndex = null),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '替换规则作用于显示层：模型输出中的「模型文本」显示为'
              '「显示文本」；你输入中的「显示文本」发给模型时还原为'
              '「模型文本」。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            if (_rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(
                    '还没有替换规则',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              for (var i = 0; i < _rules.length; i++) ...[
                _ruleRow(context, i),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 4),
            _primaryButton(
              context: context,
              label: '添加规则',
              onPressed: _addRule,
            ),
          ],
        ),
      ),
    );
  }
}

/// 文字替换规则行（普通态）：开关在行右侧；
/// 长按进入删除确认态——水波扩散 + 卡片变暗（效果同归档对话删除确认），
/// 开关原位变为大号红色删除按钮
class _RuleRow extends StatefulWidget {
  const _RuleRow({
    required this.rule,
    required this.longPressed,
    required this.onTap,
    required this.onLongPress,
    required this.onToggle,
    required this.onDelete,
  });

  final TextReplaceRule rule;

  /// 是否处于删除确认态（父级状态驱动）
  final bool longPressed;

  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  State<_RuleRow> createState() => _RuleRowState();
}

class _RuleRowState extends State<_RuleRow>
    with SingleTickerProviderStateMixin {
  /// 水波扩散动画（长按进入删除确认态时播放一次）
  late final AnimationController _rippleCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void dispose() {
    _rippleCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _RuleRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进入删除确认态：播放水波扩散（同归档对话）
    if (widget.longPressed && !oldWidget.longPressed) {
      _rippleCtrl.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rule = widget.rule;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        // 删除确认态：卡片变暗（同归档对话）
        color: widget.longPressed
            ? Colors.grey.shade700
            : _buttonColor(context),
        child: Stack(
          children: [
            // 水波：从删除按钮位置（右下）扩散的圆，扩散 + 淡出
            AnimatedBuilder(
              animation: _rippleCtrl,
              builder: (context, _) {
                final t = _rippleCtrl.value;
                if (t == 0) return const SizedBox.shrink();
                final size = 120 + 280 * t;
                return Positioned(
                  right: 24,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.25 * (1 - t)),
                      ),
                    ),
                  ),
                );
              },
            ),
            InkWell(
              borderRadius: BorderRadius.circular(14),
              // 点击进入编辑并退出删除态；长按进入删除态
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              child: Opacity(
                // 禁用规则整体变淡
                opacity: rule.enabled ? 1 : 0.5,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '显示：${rule.display}　模型：${rule.model}',
                          style: Theme.of(context).textTheme.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 固定宽度：开关/删除切换无跳动
                      SizedBox(
                        width: 56,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 150),
                          child: widget.longPressed
                              ? IconButton(
                                  key: const ValueKey('delete'),
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 22, // 大一点
                                    color: Colors.redAccent, // 红色
                                  ),
                                  onPressed: widget.onDelete,
                                )
                              : Builder(
                                  key: const ValueKey('switch'),
                                  builder: (context) {
                                    final dark =
                                        Theme.of(context).brightness ==
                                        Brightness.dark;
                                    return Switch(
                                      value: rule.enabled,
                                      onChanged: widget.onToggle,
                                      activeThumbColor: dark
                                          ? Colors.grey.shade300
                                          : Colors.grey.shade800,
                                      inactiveThumbColor: dark
                                          ? Colors.grey.shade300
                                          : Colors.grey.shade800,
                                      trackColor: WidgetStatePropertyAll(
                                        dark
                                            ? Colors.grey.shade700
                                            : Colors.grey.shade300,
                                      ),
                                      trackOutlineColor: WidgetStatePropertyAll(
                                        Colors.grey.shade500,
                                      ),
                                      trackOutlineWidth:
                                          const WidgetStatePropertyAll(1.0),
                                      materialTapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    );
                                  },
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── 模型提供方列表页 ──
class _ProviderListPage extends StatefulWidget {
  const _ProviderListPage({required this.providers, required this.onChanged});

  final List<ModelProvider> providers;

  /// 提供方/模型变更回调（父级回调主页面：生效 + 存档）
  final VoidCallback onChanged;

  @override
  State<_ProviderListPage> createState() => _ProviderListPageState();
}

class _ProviderListPageState extends State<_ProviderListPage> {
  /// 删除提供方：确认后移除（项目风格确认对话框）
  Future<void> _deleteProvider(int index) async {
    final provider = widget.providers[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('删除 ${provider.name}？'),
        content: const Text('该提供方及其模型将被移除（不影响已选模型）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          Material(
            color: _buttonColor(context),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).pop(true),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Text(
                  '删除',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => widget.providers.removeAt(index));
      widget.onChanged(); // 提供方删除：回调主页面
    }
  }

  /// 添加提供方：底部弹出表单（名称 / API 地址 / API Key，Key 可留空）
  Future<void> _addProvider() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final keyController = TextEditingController();
    final result = await showModalBottomSheet<ModelProvider>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        String? nameError;
        return StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _projectInput(
                  context: context,
                  controller: nameController,
                  label: '提供方名称',
                  hint: '如 OpenAI',
                  errorText: nameError,
                  onChanged: (_) {
                    if (nameError != null) {
                      setSheetState(() => nameError = null);
                    }
                  },
                ),
                const SizedBox(height: 12),
                _projectInput(
                  context: context,
                  controller: urlController,
                  label: 'API 地址',
                  hint: 'https://api.example.com/v1',
                ),
                const SizedBox(height: 12),
                _projectInput(
                  context: context,
                  controller: keyController,
                  label: 'API Key（可留空）',
                  hint: 'sk-...',
                  obscure: true,
                ),
                const SizedBox(height: 20),
                _primaryButton(
                  context: context,
                  label: '保存',
                  onPressed: () {
                    final name = nameController.text.trim();
                    if (name.isEmpty) {
                      setSheetState(() => nameError = '请输入提供方名称');
                      return;
                    }
                    Navigator.of(context).pop(
                      ModelProvider(
                        name: name,
                        baseUrl: urlController.text.trim(),
                        apiKey: keyController.text.trim(), // 可留空
                        models: [],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
    if (result != null && mounted) {
      setState(() => widget.providers.add(result));
      widget.onChanged(); // 提供方新增：回调主页面
    }
  }

  @override
  Widget build(BuildContext context) {
    return _projectScaffold(
      context: context,
      title: '模型提供方',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          for (var i = 0; i < widget.providers.length; i++) ...[
            _providerTile(context, i),
            const SizedBox(height: 12),
          ],
          // 底部添加按钮（与文字替换页一致：跟随内容滚动，不贴屏幕底）
          const SizedBox(height: 12),
          _primaryButton(
            context: context,
            label: '添加提供方',
            onPressed: _addProvider,
          ),
        ],
      ),
    );
  }

  Widget _providerTile(BuildContext context, int i) {
    final p = widget.providers[i];
    return _projectTile(
      context: context,
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.grey.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          p.name.characters.first,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      title: Text(
        p.name,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        // 有地址显示地址（自定义提供方），无地址只显示模型数（预设提供方）
        p.baseUrl.isEmpty
            ? '${p.models.length} 个模型'
            : '${p.models.length} 个模型 · ${p.baseUrl}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () async {
        // push 返回后刷新列表（模型数量可能变化）+ 回调主页面
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                _ProviderDetailPage(provider: p, onChanged: widget.onChanged),
          ),
        );
        if (mounted) setState(() {});
      },
      // 删除提供方（仅自定义提供方可删，预置不可删）
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.chevron_right, size: 20),
          if (!p.isPreset)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteProvider(i),
            ),
        ],
      ),
    );
  }
}

/// ── 提供方详情页：API 信息 + 该提供方下的模型管理 ──
class _ProviderDetailPage extends StatefulWidget {
  const _ProviderDetailPage({required this.provider, required this.onChanged});

  final ModelProvider provider;

  /// 提供方/模型变更回调
  final VoidCallback onChanged;

  @override
  State<_ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends State<_ProviderDetailPage> {
  /// API Key 显隐切换
  bool _showKey = false;

  /// 测试连接状态：0=未测试/1=测试中/2=成功/3=失败
  int _testState = 0;

  /// 测试反馈（按钮右侧）：测试中转圈；成功/失败/未测试
  Widget _testStatus(BuildContext context) {
    final variant = Theme.of(context).colorScheme.onSurfaceVariant;
    switch (_testState) {
      case 1:
        return SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(strokeWidth: 2, color: variant),
        );
      case 2:
        final ok = Theme.of(context).brightness == Brightness.dark
            ? kSuccessColor
            : kSuccessColorLight;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, size: 14, color: ok),
            const SizedBox(width: 2),
            Text('成功', style: TextStyle(fontSize: 11, color: ok)),
          ],
        );
      case 3:
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cancel, size: 14, color: kErrorColor),
            SizedBox(width: 2),
            Text('失败', style: TextStyle(fontSize: 11, color: kErrorColor)),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// API 地址内联输入：点击直接输入，失焦/回车自动保存
  late final TextEditingController _urlController = TextEditingController(
    text: widget.provider.baseUrl,
  );
  final _urlFocus = FocusNode();

  /// API Key 内联输入：点击直接输入，失焦/回车自动保存
  late final TextEditingController _keyController = TextEditingController(
    text: widget.provider.apiKey,
  );
  final _keyFocus = FocusNode();

  /// 保存 API 地址（失焦/回车时触发）
  void _saveUrl() {
    if (!mounted) return;
    setState(() {
      widget.provider.baseUrl = _urlController.text.trim();
    });
    widget.onChanged(); // 地址变更：回调主页面（存档）
  }

  /// 保存 API Key（失焦/回车时触发）
  void _saveKey() {
    if (!mounted) return;
    setState(() {
      widget.provider.apiKey = _keyController.text.trim();
    });
    widget.onChanged(); // Key 变更：回调主页面（存档）
  }

  /// 模型显示文本：有显示名时 "显示名 (ID)"，否则 ID
  String _modelLabel(ProviderModel m) =>
      m.displayName == null ? m.id : '${m.displayName} (${m.id})';

  /// 通用 GET 请求（带 Bearer Key），返回 JSON（失败抛异常）
  Future<dynamic> _getJson(String path) async {
    final base = widget.provider.baseUrl.trim();
    if (base.isEmpty) {
      throw StateError('未设置 API 地址');
    }
    final uri = Uri.parse('${base.replaceAll(RegExp(r'/$'), '')}$path');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      if (widget.provider.apiKey.trim().isNotEmpty) {
        req.headers.set(
          'Authorization',
          'Bearer ${widget.provider.apiKey.trim()}',
        );
      }
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401) {
        // 鉴权失败：多半是 API Key 缺失/无效
        throw HttpException('API Key 无效或未设置（HTTP 401）');
      }
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}: $body');
      }
      return jsonDecode(body);
    } finally {
      client.close();
    }
  }

  /// 提示框（成功/失败反馈）
  void _showResult(String title, String message, {bool isError = false}) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title),
        content: Text(
          message,
          style: TextStyle(
            color: isError ? Theme.of(context).colorScheme.error : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 测试连接：GET {baseUrl}/models；反馈显示在按钮右侧（只显示成功/失败）
  Future<void> _testConnection() async {
    setState(() => _testState = 1);
    try {
      await _getJson('/models');
      if (!mounted) return;
      setState(() => _testState = 2);
    } catch (_) {
      if (!mounted) return;
      setState(() => _testState = 3);
    }
  }

  /// 从 API 获取模型：列出模型 ID，勾选启用 + 设置显示名
  Future<void> _fetchModelsFromApi() async {
    List<String> ids;
    try {
      final data = await _getJson('/models');
      final list = (data is Map && data['data'] is List)
          ? (data['data'] as List)
          : <dynamic>[];
      ids = list
          .map((m) => (m is Map && m['id'] is String) ? m['id'] as String : '')
          .where((id) => id.isNotEmpty)
          .toList();
    } catch (e) {
      if (!mounted) return;
      _showResult('获取失败', '$e', isError: true);
      return;
    }
    if (!mounted) return;
    if (ids.isEmpty) {
      _showResult('获取结果', '接口未返回模型列表（data 为空）。', isError: true);
      return;
    }

    // 勾选状态：默认选中「提供方里还没有的」模型
    final existing = widget.provider.models.map((m) => m.id).toSet();
    final checked = <String, bool>{
      for (final id in ids) id: !existing.contains(id),
    };
    final displayNames = <String, TextEditingController>{};

    final selected = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // 显示 API 返回的全部模型；已添加的行标记「已添加」并禁用勾选
          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: const Text('从 API 获取模型'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: ids.length,
                itemBuilder: (context, i) {
                  final id = ids[i];
                  final alreadyAdded = existing.contains(id);
                  // 已添加的模型：显示名输入框预填现有显示名（可修改）
                  displayNames.putIfAbsent(
                    id,
                    () => TextEditingController(
                      text: alreadyAdded
                          ? (widget.provider.models
                                    .where((m) => m.id == id)
                                    .isEmpty
                                ? ''
                                : widget.provider.models
                                          .firstWhere((m) => m.id == id)
                                          .displayName ??
                                      '')
                          : '',
                    ),
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        // 已添加的禁用勾选
                        Checkbox(
                          value: alreadyAdded ? true : (checked[id] ?? true),
                          // 勾选色统一灰白体系
                          activeColor: Colors.grey.shade700,
                          checkColor: Colors.white,
                          onChanged: alreadyAdded
                              ? null
                              : (v) => setDialogState(
                                  () => checked[id] = v ?? false,
                                ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                id,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                              const SizedBox(height: 2),
                              // 所有模型都提供显示名输入（已添加的可修改显示名）
                              TextField(
                                controller: displayNames[id],
                                decoration: InputDecoration(
                                  hintText: alreadyAdded
                                      ? '修改显示名（可留空）'
                                      : '显示名（可留空）',
                                  hintStyle: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                  isDense: true,
                                  filled: true,
                                  fillColor: _buttonColor(context),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none,
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              Material(
                color: _buttonColor(context),
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    // 返回全部 ids，由外层统一处理（添加/更新显示名）
                    Navigator.of(context).pop(ids);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Text(
                      '完成',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );

    if (selected != null && selected.isNotEmpty && mounted) {
      setState(() {
        for (final id in selected) {
          final display = displayNames[id]?.text.trim() ?? '';
          if (existing.contains(id)) {
            // 已添加：更新显示名
            for (final m in widget.provider.models) {
              if (m.id == id) {
                m.displayName = display.isEmpty ? null : display;
              }
            }
          } else if (checked[id] ?? false) {
            // 未添加且勾选：新增（模型进入 provider.models，主页面经 onChanged 同步）
            widget.provider.models.add(
              ProviderModel(
                id: id,
                displayName: display.isEmpty ? null : display,
              ),
            );
          }
        }
      });
      widget.onChanged();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _urlFocus.dispose();
    _keyController.dispose();
    _keyFocus.dispose();
    super.dispose();
  }

  Future<void> _addModel() async {
    final idController = TextEditingController();
    final displayController = TextEditingController();
    // 能力初始值：工具调用默认勾选、思考默认勾选（默认可思考），
    // 多模态默认不勾；上下文档位按命名默认
    late _CapabilityValues caps = _CapabilityValues(
      mm: false,
      tm: true,
      th: true,
      ctxMode: _defaultCtxMode(''),
    );
    final result = await _showModelSheet<ProviderModel>(
      context: context,
      title: '添加模型',
      children: [
        _projectInput(
          context: context,
          controller: idController,
          label: '模型 ID',
          hint: '如 gpt-4o',
          autofocus: true, // 打开即聚焦，可直接输入
        ),
        const SizedBox(height: 12),
        // 显示名：页眉展示用，可留空（留空则显示 ID）
        _projectInput(
          context: context,
          controller: displayController,
          label: '显示名（可留空）',
          hint: '页眉展示的名称',
        ),
        const SizedBox(height: 16),
        _CapabilitySection(
          modelId: idController.text.trim(),
          baseUrl: widget.provider.baseUrl,
          apiKey: widget.provider.apiKey,
          initial: caps,
          onChanged: (v) => caps = v,
        ),
      ],
      onSave: () {
        final id = idController.text.trim();
        if (id.isEmpty) return null;
        return ProviderModel(
          id: id,
          displayName: displayController.text.trim().isEmpty
              ? null
              : displayController.text.trim(),
          supportsMultimodal: caps.mm,
          supportsTools: caps.tm,
          supportsThinking: caps.th,
          contextWindow: switch (caps.ctxMode) {
            1 => 32768,
            2 => 131072,
            3 => 1048576,
            4 => caps.ctxCustom,
            _ => null,
          },
        );
      },
    );
    if (result != null && mounted) {
      setState(() => widget.provider.models.add(result));
      widget.onChanged(); // 模型变更：回调主页面
    }
  }

  /// 点击模型行：编辑显示名与能力设置
  Future<void> _editModel(ProviderModel model) async {
    final displayController = TextEditingController(
      text: model.displayName ?? '',
    );
    // 能力初始值：模型能力为纯布尔（有无），无 null 状态
    late _CapabilityValues caps = _CapabilityValues(
      mm: model.supportsMultimodal,
      tm: model.supportsTools,
      th: model.supportsThinking,
      ctxMode: switch (model.contextWindow) {
        32768 => 1,
        131072 => 2,
        1048576 => 3,
        null => _defaultCtxMode(model.id), // 未设置：按命名默认
        _ => 4, // 其他数值 = 自定义
      },
      ctxCustom: model.contextWindow == null
          ? null
          : switch (model.contextWindow) {
              32768 => null,
              131072 => null,
              1048576 => null,
              _ => model.contextWindow,
            },
    );
    final ok = await _showModelSheet<bool>(
      context: context,
      title: model.id,
      children: [
        _projectInput(
          context: context,
          controller: displayController,
          label: '显示名（可留空）',
          hint: '页眉展示的名称',
        ),
        const SizedBox(height: 16),
        _CapabilitySection(
          modelId: model.id,
          baseUrl: widget.provider.baseUrl,
          apiKey: widget.provider.apiKey,
          initial: caps,
          onChanged: (v) => caps = v,
        ),
      ],
      onSave: () {
        model
          ..displayName = displayController.text.trim().isEmpty
              ? null
              : displayController.text.trim()
          ..supportsMultimodal = caps.mm
          ..supportsTools = caps.tm
          ..supportsThinking = caps.th
          ..contextWindow = switch (caps.ctxMode) {
            1 => 32768,
            2 => 131072,
            3 => 1048576,
            4 => caps.ctxCustom,
            _ => null,
          };
        return true;
      },
    );
    if (ok == true && mounted) {
      setState(() {});
      widget.onChanged(); // 显示名/能力变更：回调主页面
    }
  }

  /// 模型添加/编辑底部弹出表单（与主界面加号面板同风格：
  /// 圆角 20 + 顶部小横条 + 下拉关闭 + 亮白/暗 1C1C1E 背景）。
  /// 内容 [children] 与保存逻辑 [onSave]（返回 null = 不关闭）由调用方提供
  Future<T?> _showModelSheet<T>({
    required BuildContext context,
    required String title,
    required List<Widget> children,
    required T? Function() onSave,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Theme.of(context).brightness == Brightness.dark
          ? kSheetBgDark
          : Colors.white,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      isScrollControlled: true,
      showDragHandle: true, // 顶部居中小横条
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Theme(
        // 底部表单同样覆盖 primary 为中性色（涟漪等不再蓝紫）
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(
            primary: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        child: Padding(
          // 键盘避让：输入框聚焦时整体随键盘抬起
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标题
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                ...children,
                const SizedBox(height: 16),
                // 按钮行：取消（灰色）+ 保存（灰底实心，与面板按钮一致）
                Row(
                  children: [
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Material(
                        color: _buttonColor(context),
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            final v = onSave();
                            if (v != null) Navigator.of(context).pop(v);
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
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
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _projectScaffold(
      context: context,
      title: widget.provider.name,
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // API 信息卡片（项目卡片风格）
          Material(
            color: _cardColor(context),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // 预设提供方：内置地址，只读展示（不显示输入框）；
                  // 自定义提供方：地址输入框，点击直接输入，失焦/回车自动保存
                  if (widget.provider.isPreset)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        widget.provider.baseUrl, // 内置地址
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    TextField(
                      controller: _urlController,
                      focusNode: _urlFocus,
                      textAlign: TextAlign.start, // 左对齐
                      style: Theme.of(context).textTheme.bodyMedium,
                      decoration: InputDecoration(
                        hintText: '未设置 API 地址',
                        hintStyle: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                        isDense: true,
                        filled: true,
                        fillColor: _buttonColor(context),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
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
                      // 回车保存
                      onSubmitted: (_) {
                        _saveUrl();
                        _urlFocus.unfocus();
                      },
                      // 点击外部失焦保存
                      onTapOutside: (_) {
                        _saveUrl();
                        _urlFocus.unfocus();
                      },
                    ),
                  const SizedBox(height: 12),
                  // API Key 内联输入框：点击直接输入，失焦/回车自动保存
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _keyController,
                          focusNode: _keyFocus,
                          obscureText: !_showKey,
                          textAlign: TextAlign.start, // 左对齐
                          style: Theme.of(context).textTheme.bodyMedium,
                          decoration: InputDecoration(
                            hintText: '未设置 API Key',
                            hintStyle: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                            isDense: true,
                            filled: true,
                            fillColor: _buttonColor(context),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
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
                          // 回车保存
                          onSubmitted: (_) {
                            _saveKey();
                            _keyFocus.unfocus();
                          },
                          // 点击外部失焦保存
                          onTapOutside: (_) {
                            _saveKey();
                            _keyFocus.unfocus();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          _showKey ? Icons.visibility_off : Icons.visibility,
                          size: 20,
                        ),
                        onPressed: () => setState(() => _showKey = !_showKey),
                      ),
                    ],
                  ),
                  // 测试连接按钮（灰色，项目风格）；反馈在按钮右侧
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          onPressed: _testState == 1 ? null : _testConnection,
                          icon: const Icon(Icons.wifi_tethering, size: 18),
                          label: const Text('测试连接'),
                        ),
                        const SizedBox(width: 8),
                        _testStatus(context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // 模型列表标题 + 操作按钮（从 API 获取 / 添加模型，灰色）
          Row(
            children: [
              Text('模型', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  // 灰色文字（onSurfaceVariant），无杂色
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                ),
                onPressed: _fetchModelsFromApi,
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                label: const Text('从 API 获取'),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant,
                ),
                onPressed: _addModel,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加模型'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 该提供方下的模型列表（项目卡片风格）
          if (widget.provider.models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '暂无模型，点击右上角添加',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            Material(
              color: _cardColor(context),
              borderRadius: BorderRadius.circular(14),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (var i = 0; i < widget.provider.models.length; i++) ...[
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        // 点击模型行：编辑显示名（设置模型）
                        onTap: () => _editModel(widget.provider.models[i]),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: SizedBox(
                            height: 44,
                            child: Row(
                              children: [
                                Expanded(
                                  // 显示名 + ID（有显示名时展示"显示名 (ID)"）
                                  child: Text(
                                    _modelLabel(widget.provider.models[i]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close, size: 20),
                                  onPressed: () {
                                    setState(() {
                                      widget.provider.models.removeAt(i);
                                    });
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (i < widget.provider.models.length - 1)
                      Container(
                        height: 1,
                        margin: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0x00000000),
                              Color(0x1A000000),
                              Color(0x00000000),
                            ],
                          ),
                        ),
                      ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 模型能力值快照：mm/tm/th = 多模态/工具调用/思考（有无，勾选 = 支持）；
/// ctxMode = 上下文窗口档位（1=32k/2=128k/3=1M/4=自定义），
/// ctxMode 为 4 时用 ctxCustom（tokens）
class _CapabilityValues {
  const _CapabilityValues({
    required this.mm,
    required this.tm,
    required this.th,
    required this.ctxMode,
    this.ctxCustom,
  });

  final bool mm;
  final bool tm;
  final bool th;
  final int ctxMode;
  final int? ctxCustom;
}

/// 上下文窗口默认档位：DeepSeek 系列默认 1M，其余默认 128k
int _defaultCtxMode(String modelId) {
  final s = modelId.toLowerCase();
  return s.contains('deepseek') || RegExp(r'(^|[-_])ds([-_]|$)').hasMatch(s)
      ? 3
      : 2;
}

/// 1x1 透明 PNG（多模态能力真实检测的最小图片载荷）
const String _k1x1Png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

/// 真实能力检测结果（null = 该次探测失败/超时/未知）
class _DetectResult {
  const _DetectResult({this.thinking, this.multimodal, this.tools});

  final bool? thinking;
  final bool? multimodal;
  final bool? tools;
}

/// 真实检测模型能力：发送三次请求确认——
/// 1) 思考：普通请求，回复含 `reasoning_content`（或 `<think>`）即支持
/// 2) 多模态：带 1x1 图片的多模态请求，200 即支持（4xx = 拒绝图片）
/// 3) 工具调用：带 function 定义的请求，200 即支持（4xx = 不支持 tools）
/// 5xx/超时/网络错误 = null（检测失败）
Future<_DetectResult> _detectCapabilities({
  required String baseUrl,
  required String apiKey,
  required String model,
}) async {
  final url = Uri.parse(
    '${baseUrl.replaceAll(RegExp(r'/$'), '')}/chat/completions',
  );
  final headers = <String, String>{
    'Content-Type': 'application/json',
    if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer $apiKey',
  };

  // 探测通用逻辑：200 = 支持；4xx = 明确不支持；其余/超时 = null
  Future<bool?> probe(Map<String, dynamic> body) async {
    try {
      final res = await http
          .post(url, headers: headers, body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) return true;
      if (res.statusCode >= 400 && res.statusCode < 500) return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  // 1) 思考：小预算请求，检查 reasoning_content / <think>
  bool? thinking;
  try {
    final res = await http
        .post(
          url,
          headers: headers,
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'user', 'content': '1+1=?'},
            ],
            'stream': false,
            'max_tokens': 64,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode == 200) {
      final msg =
          ((jsonDecode(res.body) as Map<String, dynamic>)['choices'] as List?)
                  ?.firstOrNull?['message']
              as Map<String, dynamic>?;
      final rc = msg?['reasoning_content'] as String? ?? '';
      final content = msg?['content'] as String? ?? '';
      thinking = rc.trim().isNotEmpty || content.contains('<think>');
    } else if (res.statusCode >= 400 && res.statusCode < 500) {
      thinking = false; // 普通请求被拒 = 模型本身不可用/不支持
    }
  } catch (_) {}

  // 2) 多模态：带 1x1 PNG 图片
  final multimodal = await probe({
    'model': model,
    'messages': [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
          {
            'type': 'image_url',
            'image_url': {'url': 'data:image/png;base64,$_k1x1Png'},
          },
        ],
      },
    ],
    'max_tokens': 8,
  });

  // 3) 工具调用：带 function 定义
  final tools = await probe({
    'model': model,
    'messages': [
      {'role': 'user', 'content': 'hi'},
    ],
    'tools': [
      {
        'type': 'function',
        'function': {
          'name': 'ping_tool',
          'description': '能力检测用',
          'parameters': {'type': 'object', 'properties': {}},
        },
      },
    ],
    'tool_choice': 'auto',
    'max_tokens': 8,
  });

  return _DetectResult(
    thinking: thinking,
    multimodal: multimodal,
    tools: tools,
  );
}

/// 模型能力设置区（状态自持，变化经 onChanged 回调完整值）：
/// 多模态 / 工具调用 / 思考 = 打勾与否（有无），副标题显示实测结果
/// + 标题右侧「检测」按钮：真实发送三次请求确认能力（思考/多模态/工具调用）
/// + 上下文窗口档位（32k/128k/1M/自定义输入）
class _CapabilitySection extends StatefulWidget {
  const _CapabilitySection({
    required this.modelId,
    required this.baseUrl,
    required this.apiKey,
    required this.initial,
    required this.onChanged,
  });

  final String modelId;
  final String baseUrl;
  final String apiKey;
  final _CapabilityValues initial;
  final ValueChanged<_CapabilityValues> onChanged;

  @override
  State<_CapabilitySection> createState() => _CapabilitySectionState();
}

class _CapabilitySectionState extends State<_CapabilitySection> {
  late bool _mm = widget.initial.mm;
  late bool _tm = widget.initial.tm;
  late bool _th = widget.initial.th;
  late int _ctx = widget.initial.ctxMode;

  /// 用户手动改过上下文档位后，ID 变化不再联动默认（ds→1M/其他→128k）
  bool _ctxTouched = false;

  /// 真实检测状态（检测中按钮禁用）
  bool _detecting = false;

  late final TextEditingController _ctxCtrl = TextEditingController(
    text: widget.initial.ctxCustom?.toString() ?? '',
  );

  @override
  void dispose() {
    _ctxCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _CapabilitySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 添加模型：输入模型 ID 时按命名联动默认上下文档位（ds 默认 1M）
    if (widget.modelId != oldWidget.modelId && !_ctxTouched) {
      setState(() => _ctx = _defaultCtxMode(widget.modelId));
      _emit();
    }
  }

  _CapabilityValues get _values => _CapabilityValues(
    mm: _mm,
    tm: _tm,
    th: _th,
    ctxMode: _ctx,
    ctxCustom: int.tryParse(_ctxCtrl.text.trim()),
  );

  void _emit() => widget.onChanged(_values);

  /// 检测按钮（真实请求）：思考 / 多模态 / 工具调用各发一次，
  /// 按回复确认能力并勾选；失败的项保持原值
  Future<void> _detect() async {
    if (_detecting || widget.modelId.trim().isEmpty) return;
    setState(() => _detecting = true);
    final r = await _detectCapabilities(
      baseUrl: widget.baseUrl,
      apiKey: widget.apiKey,
      model: widget.modelId.trim(),
    );
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (r.thinking != null) _th = r.thinking!;
      if (r.multimodal != null) _mm = r.multimodal!;
      if (r.tools != null) _tm = r.tools!;
    });
    _emit();
  }

  /// 能力行副标题：检测中 / 支持 / 不支持 / 未检测
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行 + 检测按钮
        Row(
          children: [
            Expanded(
              child: Text(
                '能力',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Material(
              color: _buttonColor(context),
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: _detecting || widget.modelId.trim().isEmpty
                    ? null
                    : _detect,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_detecting)
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.onSurfaceVariant,
                          ),
                        )
                      else
                        Icon(
                          Icons.bolt,
                          size: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      const SizedBox(width: 4),
                      Text(
                        _detecting ? '检测中' : '检测',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 三个能力并排（有无问题：打勾 = 支持）
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _capabilityCheckTile(
                context,
                label: '多模态',
                value: _mm,
                onChanged: (v) {
                  setState(() => _mm = v);
                  _emit();
                },
              ),
            ),
            Expanded(
              child: _capabilityCheckTile(
                context,
                label: '工具调用',
                value: _tm,
                onChanged: (v) {
                  setState(() => _tm = v);
                  _emit();
                },
              ),
            ),
            Expanded(
              child: _capabilityCheckTile(
                context,
                label: '思考',
                value: _th,
                onChanged: (v) {
                  setState(() => _th = v);
                  _emit();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _capabilityRow(
          context,
          label: '上下文窗口',
          subtitle: _ctx == 4
              ? (_ctxCtrl.text.trim().isEmpty ? '未输入' : null)
              : null,
          value: _ctx,
          segments: const [(1, '32k'), (2, '128k'), (3, '1M'), (4, '自定义')],
          onChanged: (v) {
            setState(() {
              _ctx = v;
              _ctxTouched = true;
            });
            _emit();
          },
        ),
        // 自定义上下文：选中「自定义」时展开数字输入
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _ctx == 4
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: _projectInput(
                    context: context,
                    controller: _ctxCtrl,
                    label: '上下文窗口（tokens）',
                    hint: '如 65536',
                    keyboardType: TextInputType.number,
                    onChanged: (_) => _emit(),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  /// 能力块（并排用）：复选框打勾 + 标题 + 检测结果副标题。
  /// 选中色统一为设置页灰白体系（深灰实底白字，与面板按钮一致）
  Widget _capabilityCheckTile(
    BuildContext context, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Checkbox(
              value: value,
              onChanged: (v) => onChanged(v ?? false),
              activeColor: Colors.grey.shade700,
              checkColor: Colors.white,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 2),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 上下文窗口行：左标题+副标题，右分段选择器（档位）
  Widget _capabilityRow(
    BuildContext context, {
    required String label,
    String? subtitle,
    required int value,
    required List<(int, String)> segments,
    required ValueChanged<int> onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        SegmentedButton<int>(
          segments: [
            for (final (v, t) in segments)
              ButtonSegment(value: v, label: Text(t)),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
          showSelectedIcon: false,
          // 风格统一（设置页灰白体系）：选中 = 深灰实底白字，
          // 未选中 = 浅灰底灰字（整个控件带浅灰背景），无外框描边
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 8),
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.grey.shade700
                  : Colors.grey.withValues(alpha: 0.15),
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? Colors.white
                  : scheme.onSurfaceVariant,
            ),
            // 无外框描边（取消默认边框线）
            side: const WidgetStatePropertyAll(BorderSide.none),
          ),
        ),
      ],
    );
  }
}

/// ── MCP 服务器列表页（增删改 + 启用开关 + 测试连接）──
/// 仿 _SearchProviderListPage / _ProviderListPage 模式
class _McpServerListPage extends StatefulWidget {
  const _McpServerListPage({required this.servers, required this.onChanged});

  final List<McpServer> servers;
  final ValueChanged<List<McpServer>> onChanged;

  @override
  State<_McpServerListPage> createState() => _McpServerListPageState();
}

class _McpServerListPageState extends State<_McpServerListPage> {
  /// 测试状态（按服务器 id）：0=未测试/1=测试中/2=成功/3=失败/4=不可用
  final Map<String, int> _testStates = {};

  late final List<McpServer> _servers = widget.servers
      .map(
        (s) => McpServer(
          id: s.id,
          name: s.name,
          url: s.url,
          token: s.token,
          enabled: s.enabled,
        ),
      )
      .toList();

  void _emit() => widget.onChanged(_servers);

  /// 底部表单：添加 / 编辑服务器（支持直接粘贴 JSON 配置导入）
  Future<void> _openForm([McpServer? existing]) async {
    final isEdit = existing != null;
    final nameController = TextEditingController(text: existing?.name ?? '');
    final urlController = TextEditingController(text: existing?.url ?? '');
    final tokenController = TextEditingController(text: existing?.token ?? '');
    final jsonController = TextEditingController();
    final result = await showModalBottomSheet<List<McpServer>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        String? nameError;
        String? urlError;
        String? jsonError;
        var showJsonImport = false;
        return StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isEdit ? '编辑 MCP 服务器' : '添加 MCP 服务器',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                // JSON 导入入口：粘贴配置自动回填/批量添加
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(
                        context,
                      ).colorScheme.onSurfaceVariant,
                    ),
                    onPressed: () =>
                        setSheetState(() => showJsonImport = !showJsonImport),
                    icon: const Icon(Icons.paste, size: 16),
                    label: Text(showJsonImport ? '收起 JSON 导入' : '粘贴 JSON 导入'),
                  ),
                ),
                if (showJsonImport) ...[
                  _projectInput(
                    context: context,
                    controller: jsonController,
                    label: 'JSON 配置',
                    hint:
                        '{"mcpServers": {"名称": {"url": "...", "token": "..."}}}',
                    maxLines: 5,
                    errorText: jsonError,
                    onChanged: (_) {
                      if (jsonError != null) {
                        setSheetState(() => jsonError = null);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onSurface,
                      ),
                      onPressed: () {
                        final servers = parseMcpServersJson(
                          jsonController.text,
                        );
                        if (servers.isEmpty) {
                          setSheetState(
                            () => jsonError = '无法解析出 MCP 服务器，请检查 JSON 格式',
                          );
                          return;
                        }
                        if (isEdit) {
                          // 编辑模式：仅回填字段（不能批量）
                          nameController.text = servers.first.name;
                          urlController.text = servers.first.url;
                          tokenController.text = servers.first.token;
                          setSheetState(() {
                            showJsonImport = false;
                            jsonError = null;
                          });
                        } else {
                          // 添加模式：直接批量添加
                          Navigator.of(context).pop(servers);
                        }
                      },
                      child: const Text('解析并导入'),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                _projectInput(
                  context: context,
                  controller: nameController,
                  label: '名称',
                  hint: '如：我的工具服务器',
                  errorText: nameError,
                  autofocus: !isEdit && !showJsonImport,
                  onChanged: (_) {
                    if (nameError != null) {
                      setSheetState(() => nameError = null);
                    }
                  },
                ),
                const SizedBox(height: 16),
                // stdio 原始命令只读展示（编辑模式下导入的本地进程配置）
                if (isEdit && existing.command.isNotEmpty) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _buttonColor(context),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      'stdio 命令：${existing.command.join(' ')}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '本地进程无法在移动端运行，请在上方填写对应的远程端点 URL',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.error.withValues(alpha: 0.9),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                _projectInput(
                  context: context,
                  controller: urlController,
                  label: 'MCP 端点 URL',
                  hint: existing?.isStdio ?? false
                      ? 'stdio 服务器请填写远程端点'
                      : 'https://example.com/mcp',
                  errorText: urlError,
                  onChanged: (_) {
                    if (urlError != null) {
                      setSheetState(() => urlError = null);
                    }
                  },
                ),
                const SizedBox(height: 16),
                _projectInput(
                  context: context,
                  controller: tokenController,
                  label: 'Bearer Token（可选）',
                  hint: '留空则不携带 Authorization',
                  obscure: true,
                ),
                const SizedBox(height: 24),
                _primaryButton(
                  context: context,
                  label: isEdit ? '保存' : '添加',
                  onPressed: () {
                    final name = nameController.text.trim();
                    final url = urlController.text.trim();
                    if (name.isEmpty) {
                      setSheetState(() => nameError = '请输入名称');
                      return;
                    }
                    if (url.isEmpty || !Uri.tryParse(url)!.hasAbsolutePath) {
                      setSheetState(() => urlError = '请输入有效 URL');
                      return;
                    }
                    Navigator.of(context).pop([
                      McpServer(
                        id:
                            existing?.id ??
                            DateTime.now().microsecondsSinceEpoch.toString(),
                        name: name,
                        url: url,
                        token: tokenController.text.trim(),
                        enabled: existing?.enabled ?? true,
                        // 填了 URL 即视为 HTTP；保留原 stdio 命令仅作展示
                        transport: 'http',
                        command: existing?.command ?? const [],
                      ),
                    ]);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
    if (result == null || result.isEmpty) return;
    setState(() {
      if (isEdit) {
        final i = _servers.indexWhere((s) => s.id == result.first.id);
        if (i >= 0) _servers[i] = result.first;
      } else {
        // 批量添加：按 url 去重（同 url 跳过）
        for (final s in result) {
          if (_servers.any((x) => x.url == s.url)) continue;
          _servers.add(s);
        }
      }
    });
    _emit();
  }

  /// 测试连接：initialize + listTools；反馈显示在按钮右侧（成功/失败/不可用）
  Future<void> _testConnection(McpServer server) async {
    // stdio 服务器（本地进程）：移动端无法运行，按钮侧显示「不可用」
    if (server.isStdio) {
      setState(() => _testStates[server.id] = 4);
      return;
    }
    setState(() => _testStates[server.id] = 1);
    try {
      final client = McpClient(url: server.url, token: server.token);
      await client.listTools();
      client.dispose();
      if (!mounted) return;
      setState(() => _testStates[server.id] = 2);
    } catch (_) {
      if (!mounted) return;
      setState(() => _testStates[server.id] = 3);
    }
  }

  /// 测试反馈（按钮右侧）：测试中转圈；成功/失败/不可用
  Widget _testStatus(McpServer s) {
    final st = _testStates[s.id] ?? 0;
    if (st == 1) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    if (st == 2) {
      final ok = Theme.of(context).brightness == Brightness.dark
          ? kSuccessColor
          : kSuccessColorLight;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 14, color: ok),
          const SizedBox(width: 2),
          Text('成功', style: TextStyle(fontSize: 11, color: ok)),
        ],
      );
    }
    if (st == 3) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cancel, size: 14, color: kErrorColor),
          SizedBox(width: 2),
          Text('失败', style: TextStyle(fontSize: 11, color: kErrorColor)),
        ],
      );
    }
    if (st == 4) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.block,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 2),
          Text(
            '不可用',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  /// 列表页快捷 JSON 导入：弹出多行输入，解析后批量添加（按 url 去重）
  Future<void> _importJson() async {
    final controller = TextEditingController();
    String? jsonError;
    final result = await showModalBottomSheet<List<McpServer>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '从 JSON 导入 MCP 服务器',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                '支持 Claude 风格 {"mcpServers": {...}}、单服务器或数组格式',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              _projectInput(
                context: context,
                controller: controller,
                label: 'JSON 配置',
                hint: '{"mcpServers": {"名称": {"url": "...", "token": "..."}}}',
                maxLines: 8,
                autofocus: true,
                errorText: jsonError,
                onChanged: (_) {
                  if (jsonError != null) {
                    setSheetState(() => jsonError = null);
                  }
                },
              ),
              const SizedBox(height: 16),
              _primaryButton(
                context: context,
                label: '导入',
                onPressed: () {
                  final servers = parseMcpServersJson(controller.text);
                  if (servers.isEmpty) {
                    setSheetState(
                      () => jsonError = '无法解析出 MCP 服务器，请检查 JSON 格式',
                    );
                    return;
                  }
                  Navigator.of(context).pop(servers);
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null || result.isEmpty) return;
    setState(() {
      for (final s in result) {
        if (_servers.any((x) => x.url == s.url)) continue;
        _servers.add(s);
      }
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return _projectScaffold(
      context: context,
      title: 'MCP 服务器',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          // 安全提示
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'MCP 服务器可执行任意工具，仅配置你信任的服务器。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_servers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text(
                  '暂无 MCP 服务器',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            for (final s in _servers)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _serverCard(s),
              ),
          // 底部操作按钮（与文字替换页一致：跟随内容滚动，不贴屏幕底）
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _primaryButton(
                  context: context,
                  label: '添加服务器',
                  onPressed: () => _openForm(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _primaryButton(
                  context: context,
                  label: 'JSON 导入',
                  onPressed: _importJson,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _serverCard(McpServer s) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: _buttonColor(context),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.name,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: s.enabled,
                  // 药丸型开关：深色模式适配的浅灰/深灰底 + 细外框 + 圆钮，
                  // 开启/关闭同款（显式 outline 覆盖 M3 开启态透明描边）
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
                  onChanged: (v) {
                    setState(() => s.enabled = v);
                    _emit();
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            const SizedBox(height: 2),
            // stdio 服务器：显示命令 + 明确提示；HTTP：显示 URL
            if (s.isStdio) ...[
              Text(
                'stdio（本地进程）· ${s.command.isEmpty ? '未配置命令' : s.command.join(' ')}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.error.withValues(alpha: 0.9),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '移动端无法运行本地进程，请在编辑中填写远程端点 URL',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ] else
              Text(
                s.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                // 测试连接按钮在最左侧（反馈在其右侧）
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => _testConnection(s),
                  child: const Text('测试连接'),
                ),
                // 反馈显示在按钮右侧（成功/失败/不可用）
                _testStatus(s),
                const Spacer(),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => _openForm(s),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.delete_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  onPressed: () => setState(() {
                    _servers.removeWhere((x) => x.id == s.id);
                    _emit();
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ── 通用设置页（粘贴 / 标题策略 / AI 标题 / 渲染开关）──
/// 仿 _ReplaceRulePage 模式：本地副本 + 每次修改 _emit 回调上抛
class _GeneralSettingsPage extends StatefulWidget {
  const _GeneralSettingsPage({
    required this.settings,
    required this.availableModels,
    required this.onChanged,
  });

  final GeneralSettings settings;
  final List<String> availableModels;
  final ValueChanged<GeneralSettings> onChanged;

  @override
  State<_GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<_GeneralSettingsPage> {
  /// 导出进行中（非模态遮罩转圈）
  bool _exporting = false;

  late GeneralSettings _s = widget.settings;
  late final TextEditingController _promptCtrl = TextEditingController(
    text: _s.aiTitlePrompt,
  );
  late final TextEditingController _sysPromptCtrl = TextEditingController(
    text: _s.defaultSystemPrompt,
  );
  late final TextEditingController _thresholdCtrl = TextEditingController(
    text: _s.pasteThreshold.toString(),
  );
  late final TextEditingController _archiveCtrl = TextEditingController(
    text: _s.autoArchiveDays.toString(),
  );
  late final TextEditingController _deleteCtrl = TextEditingController(
    text: _s.autoDeleteDays.toString(),
  );
  late final TextEditingController _reactRoundsCtrl = TextEditingController(
    text: _s.reactMaxRounds.toString(),
  );

  /// AI 标题提示词输入框展开状态（收纳在 AI 生成开关下，点 > 展开/收起）
  bool _aiPromptExpanded = false;

  /// AI 标题生成模型下拉栏展开状态
  bool _modelExpanded = false;

  @override
  void dispose() {
    _promptCtrl.dispose();
    _sysPromptCtrl.dispose();
    _thresholdCtrl.dispose();
    _archiveCtrl.dispose();
    _deleteCtrl.dispose();
    _reactRoundsCtrl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged(_s);

  void _update(GeneralSettings Function(GeneralSettings) mutator) {
    setState(() => _s = mutator(_s));
    _emit();
  }

  /// 导出全部数据为 ZIP：convs/（会话文件）+ settings.json（prefs 全量
  /// 键值）。生成后用系统分享面板保存/发送
  Future<void> _exportData() async {
    // 打包动画（非模态转圈遮罩）：后台 isolate 压缩期间反馈进行中
    setState(() => _exporting = true);
    try {
      final base = await getApplicationDocumentsDirectory();
      final tmpDir = await getTemporaryDirectory();
      // 设置（SharedPreferences 全量——含索引/提供方/规则/模板/开关）
      final prefs = await SharedPreferences.getInstance();
      final settings = <String, dynamic>{};
      for (final k in prefs.getKeys()) {
        if (k.startsWith('flutter.') || k.startsWith('plugin')) continue;
        settings[k] = prefs.get(k);
      }
      // 打包 + 压缩全部在 isolate：带图会话几十 MB 的读盘/zip 在主线程
      // 会冻结 UI（ANR 级卡死）
      final tmpPath = await compute(_zipBackupIsolate, {
        'convsDir': '${base.path}/convs',
        'settingsJson': jsonEncode(settings),
        'outPath':
            '${tmpDir.path}/'
            'LLM_Chat_backup_${DateTime.now().millisecondsSinceEpoch}.zip',
      });
      await SharePlus.instance.share(ShareParams(files: [XFile(tmpPath)]));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导入 ZIP：合并会话文件（同 ID 覆盖）+ 设置键值，完成后提示重启
  Future<void> _importData() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );
    final f = result?.files.firstOrNull;
    if (f == null) return;
    try {
      final archive = ZipDecoder().decodeBytes(f.bytes!);
      final base = await getApplicationDocumentsDirectory();
      final convsDir = Directory('${base.path}/convs');
      if (!convsDir.existsSync()) convsDir.createSync(recursive: true);
      var convCount = 0;
      final settings = <String, dynamic>{};
      for (final file in archive) {
        if (file.isFile) {
          final data = file.content as List<int>;
          if (file.name.startsWith('convs/') && file.name.endsWith('.json')) {
            final name = file.name.split('/').last;
            File('${convsDir.path}/$name').writeAsBytesSync(data);
            convCount++;
          } else if (file.name == 'settings.json') {
            settings.addAll(
              jsonDecode(utf8.decode(data)) as Map<String, dynamic>,
            );
          }
        }
      }
      // 设置合并写回 prefs
      if (settings.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        for (final e in settings.entries) {
          final v = e.value;
          if (v is String) {
            prefs.setString(e.key, v);
          } else if (v is int) {
            prefs.setInt(e.key, v);
          } else if (v is double) {
            prefs.setDouble(e.key, v);
          } else if (v is bool) {
            prefs.setBool(e.key, v);
          } else if (v is List) {
            prefs.setStringList(e.key, v.whereType<String>().toList());
          }
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已导入 $convCount 个对话与设置，重启应用后生效')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败：文件格式错误')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAiTitle = _s.titleStrategy == TitleStrategy.ai;
    return _projectScaffold(
      context: context,
      title: '通用',
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── 输入 ──
              _sectionLabel('输入'),
              _switchTile(
                context,
                icon: Icons.content_paste_go,
                title: '粘贴长文本转为文件',
                subtitle: '超过阈值的粘贴文本自动转为 .txt 附件',
                value: _s.pasteLongTextAsFile,
                onChanged: (v) =>
                    _update((s) => s.copyWith(pasteLongTextAsFile: v)),
              ),
              const SizedBox(height: 12),
              // 阈值输入（与文字替换页内联编辑同款卡片包裹）
              Material(
                color: _buttonColor(context),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _projectInput(
                    context: context,
                    controller: _thresholdCtrl,
                    label: '字符阈值',
                    hint: '超过此长度的粘贴文本转附件',
                    enabled: _s.pasteLongTextAsFile,
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n > 0) {
                        _update((s) => s.copyWith(pasteThreshold: n));
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 将 PDF 解析为图像：发送时渲染每页为图片（多模态模型可查看）
              _switchTile(
                context,
                icon: Icons.picture_as_pdf_outlined,
                title: '将 PDF 解析为图像',
                subtitle: 'PDF 附件渲染为图片发送，模型可直接查看内容',
                value: _s.pdfAsImage,
                onChanged: (v) => _update((s) => s.copyWith(pdfAsImage: v)),
              ),
              const SizedBox(height: 20),

              // ── 对话标题 ──
              _sectionLabel('默认提示词'),
              // 会话未设置自己的提示词时使用（空 = 不发送）；常驻编辑框
              Material(
                color: _buttonColor(context),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _projectInput(
                    context: context,
                    controller: _sysPromptCtrl,
                    label: '默认 System 提示词',
                    hint: '留空 = 新对话不发送 system',
                    maxLines: 6,
                    onChanged: (v) =>
                        _update((s) => s.copyWith(defaultSystemPrompt: v)),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              _sectionLabel('对话标题'),
              for (final strategy in TitleStrategy.values) ...[
                _strategyTile(
                  strategy,
                  // AI 行：右侧热区（行宽 - 72px）点按展开/收起，其余点按只选中；
                  // 波纹铺满整个选项卡
                  trailing: strategy == TitleStrategy.ai
                      ? Icon(
                          _aiPromptExpanded
                              ? Icons.expand_more
                              : Icons.chevron_right,
                          size: 24, // 大一点，右侧热区即按钮
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        )
                      : null,
                  onTapUp: strategy == TitleStrategy.ai
                      ? (d, width) {
                          // 右侧 2/5 卡片区域 = 展开热区，其余 = 选中策略
                          if (d.localPosition.dx > width * 0.6) {
                            setState(
                              () => _aiPromptExpanded = !_aiPromptExpanded,
                            );
                          } else {
                            _update((s) => s.copyWith(titleStrategy: strategy));
                          }
                        }
                      : null,
                ),
                if (strategy == TitleStrategy.ai) ...[
                  // AI 标题展开区（提示词 + 生成模型）：收纳在 AI 生成开关下，
                  // 开/关都有过渡动画（AnimatedCrossFade：淡入淡出 + 高度过渡）
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 220),
                    sizeCurve: Curves.easeOutCubic,
                    firstChild: const SizedBox(width: double.infinity),
                    secondChild: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Material(
                            color: _buttonColor(context),
                            borderRadius: BorderRadius.circular(14),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: _projectInput(
                                context: context,
                                controller: _promptCtrl,
                                label: 'AI 标题生成提示词',
                                hint: '含 {{USER}} / {{ASSISTANT}} 占位符',
                                maxLines: 6,
                                onChanged: (v) => _update(
                                  (s) => s.copyWith(aiTitlePrompt: v),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          // 生成模型：收纳进 AI 生成展开区（展开下拉栏）
                          _modelDropdown(),
                        ],
                      ),
                    ),
                    crossFadeState: isAiTitle && _aiPromptExpanded
                        ? CrossFadeState.showSecond
                        : CrossFadeState.showFirst,
                  ),
                  const SizedBox(height: 12),
                ] else
                  const SizedBox(height: 12),
              ],
              const SizedBox(height: 12),

              // ── 渲染 ──
              _sectionLabel('渲染'),
              _switchTile(
                context,
                icon: Icons.article_outlined,
                title: 'Markdown 渲染',
                subtitle: '消息正文按 Markdown 格式渲染',
                value: _s.markdownEnabled,
                onChanged: (v) =>
                    _update((s) => s.copyWith(markdownEnabled: v)),
              ),
              const SizedBox(height: 12),
              // 上下文占用百分比（默认只显示圆环；开启后百分比显示在圆环右侧）
              _switchTile(
                context,
                icon: Icons.donut_large,
                title: '上下文占用百分比',
                subtitle: '在输出气泡的上下文占用圆环右侧显示百分比',
                value: _s.contextPercent,
                onChanged: (v) => _update((s) => s.copyWith(contextPercent: v)),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.functions,
                title: 'LaTeX 渲染',
                subtitle: '识别 \$...\$ 与 \$\$...\$\$ 数学公式',
                value: _s.latexEnabled,
                onChanged: (v) => _update((s) => s.copyWith(latexEnabled: v)),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.account_tree_outlined,
                title: 'Mermaid 图表',
                subtitle: '渲染 mermaid 代码块为流程图',
                value: _s.mermaidEnabled,
                onChanged: (v) => _update((s) => s.copyWith(mermaidEnabled: v)),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.preview_outlined,
                title: 'Artifacts 预览',
                subtitle: '自动预览 HTML/SVG 代码块的生成物',
                value: _s.artifactsEnabled,
                onChanged: (v) =>
                    _update((s) => s.copyWith(artifactsEnabled: v)),
              ),
              const SizedBox(height: 20),

              // ── 内置工具 ──
              _sectionLabel('内置工具'),
              _switchTile(
                context,
                icon: Icons.build_outlined,
                title: '内置工具',
                subtitle: '启用后模型可调用以下工具（可单独开关）',
                value: _s.builtinToolsEnabled,
                onChanged: (v) =>
                    _update((s) => s.copyWith(builtinToolsEnabled: v)),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.schedule,
                title: '获取当前时间',
                subtitle: 'builtin__get_current_time',
                // 子开关与总开关相互独立：各自记忆并始终可操作
                value: _s.builtinTimeEnabled,
                onChanged: (v) =>
                    _update((s) => s.copyWith(builtinTimeEnabled: v)),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.location_on_outlined,
                title: '获取地理位置',
                subtitle: 'builtin__get_location（需定位权限）',
                value: _s.builtinLocationEnabled,
                onChanged: (v) =>
                    _update((s) => s.copyWith(builtinLocationEnabled: v)),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.travel_explore,
                title: '联网搜索',
                subtitle: 'builtin__web_search（DeepSeek 原生搜索）',
                value: _s.builtinSearchEnabled,
                onChanged: (v) =>
                    _update((s) => s.copyWith(builtinSearchEnabled: v)),
              ),
              const SizedBox(height: 12),
              Material(
                color: _buttonColor(context),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _projectInput(
                    context: context,
                    controller: _reactRoundsCtrl,
                    label: '工具循环上限（轮）',
                    hint: '默认 6，范围 2-20',
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n >= 2 && n <= 20) {
                        _update((s) => s.copyWith(reactMaxRounds: n));
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '模型自主调用工具（搜索/时间/位置/MCP）的最大迭代轮数；'
                  '上限越高模型可进行更多轮搜索，同时消耗更多 token。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '可在输入栏加号面板中按对话单独开启/关闭内置工具。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── 归档 ──
              _sectionLabel('数据管理'),
              Row(
                children: [
                  Expanded(
                    child: _primaryButton(
                      context: context,
                      label: '导出数据（ZIP）',
                      onPressed: _exportData,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _primaryButton(
                      context: context,
                      label: '导入数据',
                      onPressed: _importData,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '导出包含：全部对话（含图片/附件）、提供方与模型、通用设置、'
                  '替换规则、提示词模板、MCP 配置。导入会合并到现有数据'
                  '（同 ID 对话覆盖）。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              _sectionLabel('归档'),
              _switchTile(
                context,
                icon: Icons.archive_outlined,
                title: '自动归档',
                subtitle: '未活跃超过设定天数的对话自动归档（锁定的除外）',
                value: _s.autoArchiveDays > 0,
                onChanged: (v) =>
                    _update((s) => s.copyWith(autoArchiveDays: v ? 30 : 0)),
              ),
              const SizedBox(height: 12),
              Material(
                color: _buttonColor(context),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _projectInput(
                    context: context,
                    controller: _archiveCtrl,
                    label: '自动归档天数',
                    hint: '0 = 关闭',
                    enabled: _s.autoArchiveDays > 0,
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n >= 0) {
                        _update((s) => s.copyWith(autoArchiveDays: n));
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _switchTile(
                context,
                icon: Icons.delete_sweep_outlined,
                title: '自动删除归档',
                subtitle: '归档超过设定天数的对话自动永久删除',
                value: _s.autoDeleteDays > 0,
                onChanged: (v) =>
                    _update((s) => s.copyWith(autoDeleteDays: v ? 90 : 0)),
              ),
              const SizedBox(height: 12),
              Material(
                color: _buttonColor(context),
                borderRadius: BorderRadius.circular(14),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: _projectInput(
                    context: context,
                    controller: _deleteCtrl,
                    label: '自动删除天数',
                    hint: '0 = 关闭',
                    enabled: _s.autoDeleteDays > 0,
                    keyboardType: TextInputType.number,
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null && n >= 0) {
                        _update((s) => s.copyWith(autoDeleteDays: n));
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '锁定的对话不会被自动归档；手动归档/删除不受锁定影响。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          if (_exporting)
            Positioned.fill(
              child: Container(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.6),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(strokeWidth: 2.4),
                      const SizedBox(height: 12),
                      Text(
                        '正在打包数据…',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 项目风格开关行：灰色卡片 + 图标 + 标题/副标题 + trailing Switch

  /// 标题策略单选行：选中态 = 中性强调色浅底 + 实心勾选图标。
  /// [trailing] 行尾附加控件（AI 行的展开箭头，仅视觉，点击走行级 onTapUp）；
  /// [onTapUp] 提供时按点击位置分发（AI 行：右侧热区 = 展开，其余 = 选中），
  /// 波纹铺满整个选项卡；否则用 [onTap] 或默认选中行为
  Widget _strategyTile(
    TitleStrategy strategy, {
    Widget? trailing,
    VoidCallback? onTap,
    void Function(TapUpDetails details, double width)? onTapUp,
  }) {
    final selected = _s.titleStrategy == strategy;
    // 选中强调色统一为中性灰白体系（不用主题蓝紫）
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.onSurface;
    final subtitle = switch (strategy) {
      TitleStrategy.timestamp => 'Chat YYYY/M/D HH:MM',
      TitleStrategy.firstLine => '取第一条消息的首行',
      TitleStrategy.ai => '回复完成后用 AI 生成',
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Material(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : _buttonColor(context),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTapUp != null
                ? null
                : onTap ??
                      () {
                        _update((s) => s.copyWith(titleStrategy: strategy));
                        // 切走 AI 策略时收起展开的提示词/模型区
                        if (strategy != TitleStrategy.ai) {
                          setState(() => _aiPromptExpanded = false);
                        }
                      },
            onTapUp: onTapUp == null ? null : (d) => onTapUp(d, width),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                          strategy.label,
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

  /// AI 标题生成模型：展开下拉栏（行内展开选项列表，非底部弹窗）。
  /// 模型名超长省略号截断；选中项右侧打勾
  Widget _modelDropdown() {
    final scheme = Theme.of(context).colorScheme;
    final current = _s.aiTitleModel.isEmpty ? '跟随对话模型' : _s.aiTitleModel;
    return Material(
      color: _buttonColor(context),
      borderRadius: BorderRadius.circular(14),
      child: Column(
        children: [
          // 标题行：点击展开/收起下拉列表
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => setState(() => _modelExpanded = !_modelExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AI 标题生成模型',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          current,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _modelExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          // 选项列表：展开/收起带过渡动画
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            sizeCurve: Curves.easeOutCubic,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 6),
                children: [
                  // 顶部与标题行的分隔线
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 14,
                    endIndent: 14,
                    color: scheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                  _modelOption(context, value: '', label: '跟随对话模型'),
                  for (final m in widget.availableModels)
                    _modelOption(context, value: m, label: m),
                ],
              ),
            ),
            crossFadeState: _modelExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
          ),
        ],
      ),
    );
  }

  /// 模型下拉选项行：名称超长省略；选中打勾
  Widget _modelOption(
    BuildContext context, {
    required String value,
    required String label,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final accent = scheme.onSurface;
    final selected = _s.aiTitleModel == value;
    return InkWell(
      onTap: () {
        _update((s) => s.copyWith(aiTitleModel: value));
        setState(() => _modelExpanded = false);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w600 : null,
                  color: selected ? accent : null,
                ),
              ),
            ),
            if (selected) ...[
              const SizedBox(width: 8),
              Icon(Icons.check, size: 18, color: accent),
            ],
          ],
        ),
      ),
    );
  }

  /// 小节标签（灰色风格分隔）
  Widget _sectionLabel(String text) => Padding(
    padding: const EdgeInsets.only(left: 2, bottom: 8, top: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// ── 归档对话管理页：查看、恢复或永久删除归档的对话 ──
/// 数据由入口构造传入（HomePage 内存缓存），滑入即有内容
class _ArchivedConversationsPage extends StatefulWidget {
  const _ArchivedConversationsPage({
    required this.archived,
    required this.store,
    required this.onChanged,
  });

  /// 归档会话列表（按归档时间倒序）
  final List<Conversation> archived;

  /// 会话存储（恢复/删除持久化）
  final ChatStore? store;

  /// 归档/删除后回调（HomePage 重载会话列表）
  final VoidCallback onChanged;

  @override
  State<_ArchivedConversationsPage> createState() =>
      _ArchivedConversationsPageState();
}

class _ArchivedConversationsPageState
    extends State<_ArchivedConversationsPage> {
  /// 页面内列表副本（增删不影响 HomePage 缓存——统一由 onChanged 重载）
  late final List<Conversation> _archived = [...widget.archived];

  /// 恢复归档对话
  Future<void> _restore(Conversation c) async {
    setState(() {
      c.archived = false;
      c.archivedAt = null;
      _archived.remove(c);
    });
    await widget.store?.save(c);
    widget.onChanged();
  }

  /// 处于删除确认态的对话题（点删除按钮后：左侧恢复变灰色 X、删除变红色勾）
  final Set<String> _confirmDelete = {};

  /// 确认永久删除
  Future<void> _doDeleteForever(Conversation c) async {
    setState(() {
      _confirmDelete.remove(c.id);
      _archived.remove(c);
    });
    await widget.store?.delete(c.id);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final archived = _archived;
    return _projectScaffold(
      context: context,
      title: '归档对话',
      body: archived.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 80),
              child: Center(
                child: Text(
                  '没有归档的对话',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                for (final c in archived)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _ArchivedCard(
                      c: c,
                      confirm: _confirmDelete.contains(c.id),
                      onRestore: () => _restore(c),
                      onRequestDelete: () =>
                          setState(() => _confirmDelete.add(c.id)),
                      onConfirmDelete: () => _doDeleteForever(c),
                      onCancel: () =>
                          setState(() => _confirmDelete.remove(c.id)),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// 导出打包（isolate）：convs/ + settings.json → ZIP 写临时文件
/// 返回 ZIP 路径。全部同步 IO 在后台执行，主线程零阻塞
String _zipBackupIsolate(Map<String, dynamic> args) {
  final convsDir = Directory(args['convsDir'] as String);
  final archive = Archive();
  if (convsDir.existsSync()) {
    for (final f in convsDir.listSync()) {
      if (f is File && f.path.endsWith('.json')) {
        final bytes = f.readAsBytesSync();
        archive.addFile(
          ArchiveFile('convs/${f.uri.pathSegments.last}', bytes.length, bytes),
        );
      }
    }
  }
  final settingsBytes = utf8.encode(args['settingsJson'] as String);
  archive.addFile(
    ArchiveFile('settings.json', settingsBytes.length, settingsBytes),
  );
  final zipBytes = ZipEncoder().encode(archive);
  final outPath = args['outPath'] as String;
  File(outPath).writeAsBytesSync(zipBytes, flush: true);
  return outPath;
}

/// 相对时间（归档卡片用）：刚刚 / N 分钟前 / N 小时前 / N 天前 / 日期
String _relativeTimeText(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${t.year}/${t.month}/${t.day}';
}

/// 归档对话卡片（含删除确认动效：点击删除按钮 → 水波从按钮扩散 +
/// 卡片整体变暗进入确认态）
class _ArchivedCard extends StatefulWidget {
  const _ArchivedCard({
    required this.c,
    required this.confirm,
    required this.onRestore,
    required this.onRequestDelete,
    required this.onConfirmDelete,
    required this.onCancel,
  });

  final Conversation c;

  /// 是否处于删除确认态（父级状态驱动）
  final bool confirm;

  final VoidCallback onRestore;
  final VoidCallback onRequestDelete;
  final VoidCallback onConfirmDelete;
  final VoidCallback onCancel;

  @override
  State<_ArchivedCard> createState() => _ArchivedCardState();
}

class _ArchivedCardState extends State<_ArchivedCard>
    with SingleTickerProviderStateMixin {
  /// 水波扩散动画（点击删除按钮进入确认态时播放一次）
  late final AnimationController _rippleCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );

  @override
  void dispose() {
    _rippleCtrl.dispose();
    super.dispose();
  }

  /// 点删除按钮：播放水波扩散动画 + 通知父级进入确认态
  void _startRipple() {
    _rippleCtrl.forward(from: 0);
    widget.onRequestDelete();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        // 确认态：卡片变暗（深灰底）
        color: widget.confirm
            ? Colors.grey.shade700
            : Colors.grey.withValues(alpha: 0.15),
        child: Stack(
          children: [
            // 水波：从删除按钮位置（右下）扩散的圆，扩散 + 淡出
            AnimatedBuilder(
              animation: _rippleCtrl,
              builder: (context, _) {
                final t = _rippleCtrl.value;
                if (t == 0) return const SizedBox.shrink();
                final size = 120 + 280 * t; // 扩散到覆盖整卡
                return Positioned(
                  right: 24,
                  bottom: 8,
                  child: IgnorePointer(
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withValues(alpha: 0.25 * (1 - t)),
                      ),
                    ),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    c.locked ? Icons.lock_outline : Icons.archive_outlined,
                    size: 20,
                    color: grey,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '归档于 ${_relativeTimeText(c.archivedAt ?? c.updatedAt)} · '
                          '${c.messages.length} 条消息',
                          style: Theme.of(
                            context,
                          ).textTheme.bodySmall?.copyWith(color: grey),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (widget.confirm)
                    // 确认态（无弹窗）：左侧灰色 X 退回，右侧红色勾确认删除
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '取消',
                          icon: Icon(Icons.close, size: 20, color: grey),
                          onPressed: widget.onCancel,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: '确认删除',
                          icon: const Icon(
                            Icons.check,
                            size: 20,
                            color: Colors.redAccent,
                          ),
                          onPressed: widget.onConfirmDelete,
                        ),
                      ],
                    )
                  else ...[
                    // 恢复
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '恢复',
                      icon: Icon(Icons.restore, size: 20, color: grey),
                      onPressed: widget.onRestore,
                    ),
                    // 永久删除：点击播放水波动效 + 进入确认态（不弹窗）
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '永久删除',
                      icon: const Icon(
                        Icons.delete_forever_outlined,
                        size: 20,
                        color: Colors.redAccent,
                      ),
                      onPressed: _startRipple,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ── 语音朗读（TTS）独立设置页 ──
class _TtsSettingsPage extends StatefulWidget {
  const _TtsSettingsPage({required this.settings, required this.onChanged});

  final GeneralSettings settings;
  final ValueChanged<GeneralSettings> onChanged;

  @override
  State<_TtsSettingsPage> createState() => _TtsSettingsPageState();
}

class _TtsSettingsPageState extends State<_TtsSettingsPage> {
  late GeneralSettings _s = widget.settings;
  late final TextEditingController _ttsUrlCtrl = TextEditingController(
    text: _s.ttsBaseUrl,
  );
  late final TextEditingController _ttsKeyCtrl = TextEditingController(
    text: _s.ttsApiKey,
  );
  late final TextEditingController _ttsModelCtrl = TextEditingController(
    text: _s.ttsModel,
  );
  late final TextEditingController _ttsVoiceCtrl = TextEditingController(
    text: _s.ttsVoice,
  );

  void _update(GeneralSettings Function(GeneralSettings) mutator) {
    setState(() => _s = mutator(_s));
    widget.onChanged(_s);
  }

  @override
  void dispose() {
    _ttsUrlCtrl.dispose();
    _ttsKeyCtrl.dispose();
    _ttsModelCtrl.dispose();
    _ttsVoiceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _projectScaffold(
      context: context,
      title: '语音朗读',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _switchTile(
            context,
            icon: Icons.volume_up_outlined,
            title: '朗读消息',
            subtitle: '助手消息工具栏显示朗读按钮',
            value: _s.ttsEnabled,
            onChanged: (v) => _update((s) => s.copyWith(ttsEnabled: v)),
          ),
          const SizedBox(height: 12),
          _switchTile(
            context,
            icon: Icons.cloud_outlined,
            title: '在线语音 API',
            subtitle:
                '伪流式分段合成（OpenAI 兼容 /audio/speech）；'
                '关闭则用系统语音引擎',
            value: _s.ttsUseApi,
            enabled: _s.ttsEnabled,
            onChanged: (v) => _update((s) => s.copyWith(ttsUseApi: v)),
          ),
          if (_s.ttsEnabled && _s.ttsUseApi) ...[
            const SizedBox(height: 12),
            Material(
              color: _buttonColor(context),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    _projectInput(
                      context: context,
                      controller: _ttsUrlCtrl,
                      label: '接口地址',
                      hint: 'https://api.siliconflow.cn/v1/audio/speech',
                      onChanged: (v) =>
                          _update((s) => s.copyWith(ttsBaseUrl: v)),
                    ),
                    const SizedBox(height: 12),
                    _projectInput(
                      context: context,
                      controller: _ttsKeyCtrl,
                      label: 'API Key',
                      hint: 'sk-...',
                      onChanged: (v) =>
                          _update((s) => s.copyWith(ttsApiKey: v)),
                    ),
                    const SizedBox(height: 12),
                    _projectInput(
                      context: context,
                      controller: _ttsModelCtrl,
                      label: '模型',
                      hint: 'FunAudioLLM/CosyVoice2-0.5B',
                      onChanged: (v) => _update((s) => s.copyWith(ttsModel: v)),
                    ),
                    const SizedBox(height: 12),
                    _projectInput(
                      context: context,
                      controller: _ttsVoiceCtrl,
                      label: '音色',
                      hint: 'alex / anna / bella …（取决于服务）',
                      onChanged: (v) => _update((s) => s.copyWith(ttsVoice: v)),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(
                          '语速',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 10,
                              activeTrackColor: Colors.grey.shade700,
                              inactiveTrackColor: Colors.grey.withValues(
                                alpha: 0.25,
                              ),
                              thumbColor: Colors.white,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 9,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 0,
                              ),
                              tickMarkShape: SliderTickMarkShape.noTickMark,
                            ),
                            child: Slider(
                              value: _s.ttsSpeed,
                              min: 0.5,
                              max: 2.0,
                              divisions: 6,
                              label: '${_s.ttsSpeed.toStringAsFixed(2)}x',
                              onChanged: (v) =>
                                  _update((s) => s.copyWith(ttsSpeed: v)),
                            ),
                          ),
                        ),
                        Text(
                          '${_s.ttsSpeed.toStringAsFixed(2)}x',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
