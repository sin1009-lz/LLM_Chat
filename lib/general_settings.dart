import 'dart:convert';

/// 会话标题生成策略
enum TitleStrategy {
  /// 时间戳（`Chat YYYY/M/D HH:MM`）
  timestamp,

  /// 第一条用户消息的首行
  firstLine,

  /// AI 生成（流式结束后独立短请求覆盖）
  ai;

  String get label => switch (this) {
    timestamp => '时间戳',
    firstLine => '第一句对话',
    ai => 'AI 生成',
  };

  String toJson() => name;

  static TitleStrategy fromJson(String s) {
    for (final v in values) {
      if (v.name == s) return v;
    }
    return GeneralSettings.defaults.titleStrategy;
  }
}

/// 通用设置（持久化，key = general_settings）
class GeneralSettings {
  const GeneralSettings({
    required this.pasteLongTextAsFile,
    required this.pasteThreshold,
    required this.titleStrategy,
    required this.aiTitleModel,
    required this.aiTitlePrompt,
    required this.defaultSystemPrompt,
    required this.markdownEnabled,
    required this.latexEnabled,
    required this.mermaidEnabled,
    required this.artifactsEnabled,
    required this.autoArchiveDays,
    required this.autoDeleteDays,
    required this.builtinToolsEnabled,
    required this.builtinTimeEnabled,
    required this.builtinLocationEnabled,
    required this.builtinSearchEnabled,
    required this.pdfAsImage,
    required this.contextPercent,
    required this.reactMaxRounds,
  });

  /// 默认值（集中一处：新增字段时同步更新 fromJson 回退逻辑）
  static const defaults = GeneralSettings(
    pasteLongTextAsFile: true,
    pasteThreshold: 2000,
    titleStrategy: TitleStrategy.ai,
    aiTitleModel: '',
    aiTitlePrompt: kDefaultTitlePrompt,
    defaultSystemPrompt: '',
    markdownEnabled: true,
    latexEnabled: true,
    mermaidEnabled: true,
    artifactsEnabled: true,
    autoArchiveDays: 30,
    autoDeleteDays: 90,
    builtinToolsEnabled: true,
    builtinTimeEnabled: true,
    builtinLocationEnabled: true,
    builtinSearchEnabled: true,
    pdfAsImage: false,
    contextPercent: false,
    reactMaxRounds: 6,
  );

  /// 默认 AI 标题生成提示词（中文，6-8 字精炼标题）
  static const kDefaultTitlePrompt =
      '根据下面的对话，生成一个简短精炼的标题（6-8 个汉字），'
      '概括对话主题。只返回标题文字，不要任何其他内容，不要使用引号。'
      '\n\nUser: {{USER}}\n\nAssistant: {{ASSISTANT}}\n\nTitle:';

  /// 粘贴长文本时自动转成 .txt 附件
  final bool pasteLongTextAsFile;

  /// 触发阈值（字符数）
  final int pasteThreshold;

  /// 对话标题策略
  final TitleStrategy titleStrategy;

  /// AI 标题生成所用模型 ID（'' = 跟随当前对话模型）
  final String aiTitleModel;

  /// AI 标题生成提示词（含 {{USER}}/{{ASSISTANT}} 占位符）
  final String aiTitlePrompt;

  /// 默认 system 提示词：会话未设置自己的提示词时使用（空 = 不发送）
  final String defaultSystemPrompt;

  /// Markdown 渲染开关
  final bool markdownEnabled;

  /// LaTeX 公式渲染开关
  final bool latexEnabled;

  /// Mermaid 图表渲染开关
  final bool mermaidEnabled;

  /// Artifacts 自动预览开关
  final bool artifactsEnabled;

  /// 未活跃 N 天后自动归档（0 = 关闭；锁定对话不归档）
  final int autoArchiveDays;

  /// 归档后 N 天自动永久删除（0 = 关闭）
  final int autoDeleteDays;

  /// 内置工具（获取当前时间 / 地理位置，供模型调用）
  final bool builtinToolsEnabled;

  /// 内置工具明细开关：获取当前时间
  final bool builtinTimeEnabled;

  /// 内置工具明细开关：获取地理位置
  final bool builtinLocationEnabled;

  /// 内置工具明细开关：联网搜索
  final bool builtinSearchEnabled;

  /// 将 PDF 附件解析为图像发送（多模态模型可查看内容）
  final bool pdfAsImage;

  /// 在上下文占用圆环右侧显示百分比（默认只显示圆环）
  final bool contextPercent;

  /// ReAct 工具调用循环的最大轮数（模型可自主调用工具的迭代上限）
  final int reactMaxRounds;

  GeneralSettings copyWith({
    bool? pasteLongTextAsFile,
    int? pasteThreshold,
    TitleStrategy? titleStrategy,
    String? aiTitleModel,
    String? aiTitlePrompt,
    String? defaultSystemPrompt,
    bool? markdownEnabled,
    bool? latexEnabled,
    bool? mermaidEnabled,
    bool? artifactsEnabled,
    int? autoArchiveDays,
    int? autoDeleteDays,
    bool? builtinToolsEnabled,
    bool? builtinTimeEnabled,
    bool? builtinLocationEnabled,
    bool? builtinSearchEnabled,
    bool? pdfAsImage,
    bool? contextPercent,
    int? reactMaxRounds,
  }) => GeneralSettings(
    pasteLongTextAsFile: pasteLongTextAsFile ?? this.pasteLongTextAsFile,
    pasteThreshold: pasteThreshold ?? this.pasteThreshold,
    titleStrategy: titleStrategy ?? this.titleStrategy,
    aiTitleModel: aiTitleModel ?? this.aiTitleModel,
    aiTitlePrompt: aiTitlePrompt ?? this.aiTitlePrompt,
    defaultSystemPrompt: defaultSystemPrompt ?? this.defaultSystemPrompt,
    markdownEnabled: markdownEnabled ?? this.markdownEnabled,
    latexEnabled: latexEnabled ?? this.latexEnabled,
    mermaidEnabled: mermaidEnabled ?? this.mermaidEnabled,
    artifactsEnabled: artifactsEnabled ?? this.artifactsEnabled,
    autoArchiveDays: autoArchiveDays ?? this.autoArchiveDays,
    autoDeleteDays: autoDeleteDays ?? this.autoDeleteDays,
    builtinToolsEnabled: builtinToolsEnabled ?? this.builtinToolsEnabled,
    builtinTimeEnabled: builtinTimeEnabled ?? this.builtinTimeEnabled,
    builtinLocationEnabled:
        builtinLocationEnabled ?? this.builtinLocationEnabled,
    builtinSearchEnabled: builtinSearchEnabled ?? this.builtinSearchEnabled,
    pdfAsImage: pdfAsImage ?? this.pdfAsImage,
    contextPercent: contextPercent ?? this.contextPercent,
    reactMaxRounds: reactMaxRounds ?? this.reactMaxRounds,
  );

  Map<String, dynamic> toJson() => {
    'pasteLongTextAsFile': pasteLongTextAsFile,
    'pasteThreshold': pasteThreshold,
    'titleStrategy': titleStrategy.toJson(),
    'aiTitleModel': aiTitleModel,
    'aiTitlePrompt': aiTitlePrompt,
    'defaultSystemPrompt': defaultSystemPrompt,
    'markdownEnabled': markdownEnabled,
    'latexEnabled': latexEnabled,
    'mermaidEnabled': mermaidEnabled,
    'artifactsEnabled': artifactsEnabled,
    'autoArchiveDays': autoArchiveDays,
    'autoDeleteDays': autoDeleteDays,
    'builtinToolsEnabled': builtinToolsEnabled,
    'builtinTimeEnabled': builtinTimeEnabled,
    'builtinLocationEnabled': builtinLocationEnabled,
    'builtinSearchEnabled': builtinSearchEnabled,
    'pdfAsImage': pdfAsImage,
    'contextPercent': contextPercent,
    'reactMaxRounds': reactMaxRounds,
  };

  /// 从 JSON 反序列化；缺字段用默认值（向前兼容旧版本）
  factory GeneralSettings.fromJson(Map<String, dynamic> j) {
    final d = defaults;
    return GeneralSettings(
      pasteLongTextAsFile:
          j['pasteLongTextAsFile'] as bool? ?? d.pasteLongTextAsFile,
      pasteThreshold:
          (j['pasteThreshold'] as num?)?.toInt() ?? d.pasteThreshold,
      titleStrategy: TitleStrategy.fromJson(
        j['titleStrategy'] as String? ?? '',
      ),
      aiTitleModel: j['aiTitleModel'] as String? ?? d.aiTitleModel,
      aiTitlePrompt: j['aiTitlePrompt'] as String? ?? d.aiTitlePrompt,
      defaultSystemPrompt:
          j['defaultSystemPrompt'] as String? ?? d.defaultSystemPrompt,
      markdownEnabled: j['markdownEnabled'] as bool? ?? d.markdownEnabled,
      latexEnabled: j['latexEnabled'] as bool? ?? d.latexEnabled,
      mermaidEnabled: j['mermaidEnabled'] as bool? ?? d.mermaidEnabled,
      artifactsEnabled: j['artifactsEnabled'] as bool? ?? d.artifactsEnabled,
      autoArchiveDays:
          (j['autoArchiveDays'] as num?)?.toInt() ?? d.autoArchiveDays,
      autoDeleteDays:
          (j['autoDeleteDays'] as num?)?.toInt() ?? d.autoDeleteDays,
      builtinToolsEnabled:
          j['builtinToolsEnabled'] as bool? ?? d.builtinToolsEnabled,
      builtinTimeEnabled:
          j['builtinTimeEnabled'] as bool? ?? d.builtinTimeEnabled,
      builtinLocationEnabled:
          j['builtinLocationEnabled'] as bool? ?? d.builtinLocationEnabled,
      builtinSearchEnabled:
          j['builtinSearchEnabled'] as bool? ?? d.builtinSearchEnabled,
      pdfAsImage: j['pdfAsImage'] as bool? ?? d.pdfAsImage,
      contextPercent: j['contextPercent'] as bool? ?? d.contextPercent,
      reactMaxRounds:
          (j['reactMaxRounds'] as num?)?.toInt() ?? d.reactMaxRounds,
    );
  }

  /// 单条 JSON 字符串（ChatStore 用 setString 存）
  String encode() => jsonEncode(toJson());

  static GeneralSettings decode(String raw) {
    try {
      return GeneralSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return defaults;
    }
  }

  @override
  String toString() => 'GeneralSettings(${toJson()})';
}
