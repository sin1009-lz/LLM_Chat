import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show compute;

/// ──────────────────────────────────────────────────────────────
/// 文档附件本地解析（Cherry Studio / ChatBox 同方案）
///
/// OpenAI 兼容端点没有文件上传 API，文档内容必须以文本注入消息。
/// Office Open XML（docx/xlsx/pptx）本质是 ZIP + XML，本地解包提取
/// 文本即可；PDF 走 pdfrx 文本层（在 main.dart，pdfium 对象不能跨
/// isolate）。旧版二进制格式（doc/xls/ppt）无法轻量解析，仍降级为
/// 文件名占位
/// ──────────────────────────────────────────────────────────────

/// 提取内容上限（字符）：超出截断。约 6 万字符覆盖绝大多数工作簿/
/// 文档，同时不打爆模型上下文
const int kMaxDocExtractChars = 60000;

/// 是否为可解析的文档附件（按扩展名）
bool isDocAttachmentName(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return const {
    'docx',
    'xlsx',
    'pptx',
  }.contains(name.substring(dot + 1).toLowerCase());
}

/// compute 入口（顶层函数，release 下可跨 isolate）
(String, bool) extractDocumentIsolate((String, Uint8List) args) =>
    extractDocumentText(args.$1, args.$2);

/// 按扩展名分发解析。返回 (文本, 是否截断)；
/// 非文档/损坏文件抛异常，由调用方降级为文件名占位
(String, bool) extractDocumentText(String name, List<int> bytes) {
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  final archive = ZipDecoder().decodeBytes(bytes);
  final text = switch (ext) {
    'docx' => _extractDocx(archive),
    'xlsx' => _extractXlsx(archive),
    'pptx' => _extractPptx(archive),
    _ => throw FormatException('不支持的文档类型：.$ext'),
  };
  final t = text.trim();
  if (t.isEmpty) throw const FormatException('文档中没有可提取的文本');
  if (t.length <= kMaxDocExtractChars) return (t, false);
  return (t.substring(0, kMaxDocExtractChars), true);
}

/// zip 条目按名取内容；找不到返回 null
Uint8List? _zipRead(Archive archive, String name) {
  for (var i = 0; i < archive.length; i++) {
    final f = archive[i];
    if (f.name == name) return f.content;
  }
  return null;
}

/// XML 字符实体解码：数字实体（&#NNNN; / &#xHHHH;——openpyxl 等生成器
/// 对非 ASCII 字符的写法）+ 命名实体（&amp; 最后解，避免二次解码）
String _xmlDecode(String s) => s
    .replaceAllMapped(RegExp(r'&#x([0-9A-Fa-f]+);|&#(\d+);'), (m) {
      final code = m.group(1) != null
          ? int.parse(m.group(1)!, radix: 16)
          : int.parse(m.group(2)!);
      // fromCharCode 对 >0xFFFF 的码点自动生成代理对
      return String.fromCharCode(code);
    })
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

// ── DOCX：word/document.xml —— 先做结构替换（tab/换行/单元格分隔），
// 再剥全部标签，剩下的就是正文 ──
String _extractDocx(Archive archive) {
  final data = _zipRead(archive, 'word/document.xml');
  if (data == null) throw const FormatException('docx 缺少 word/document.xml');
  final xml = utf8.decode(data, allowMalformed: true);
  final text = _xmlDecode(
    xml
        .replaceAll('<w:tab/>', '\t')
        .replaceAll(RegExp(r'<w:br[^>]*/>'), '\n')
        // 单元格末尾段落的 </w:p></w:tc> 连写：tab 连接（不换行），
        // 必须先于 </w:p> → \n 的通用替换
        .replaceAll('</w:p></w:tc>', '\t')
        .replaceAll('</w:tc>', '\t')
        .replaceAll('</w:p>', '\n')
        .replaceAll('</w:tr>', '\n') // 表格行结束 → 换行
        .replaceAll(RegExp(r'<[^>]+>'), ''),
  );
  return text
      .replaceAll(RegExp(r'\t+\n'), '\n') // 行尾残留 tab
      .replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

// ── XLSX：sharedStrings + 各 sheet → 每表一段 TSV ──
String _extractXlsx(Archive archive) {
  // 共享字符串表：<si><t>a</t><t>b</t></si>（富文本多段拼接）
  final shared = <String>[];
  final ss = _zipRead(archive, 'xl/sharedStrings.xml');
  if (ss != null) {
    final xml = utf8.decode(ss, allowMalformed: true);
    for (final si in RegExp(r'<si>.*?</si>', dotAll: true).allMatches(xml)) {
      shared.add(
        RegExp(
          r'<t[^>]*>([^<]*)</t>',
        ).allMatches(si.group(0)!).map((m) => _xmlDecode(m.group(1)!)).join(),
      );
    }
  }
  // sheet 声明（名称 + rId）→ rels 映射 → worksheets/sheetN.xml
  final wb = _zipRead(archive, 'xl/workbook.xml');
  if (wb == null) throw const FormatException('xlsx 缺少 workbook.xml');
  final wbXml = utf8.decode(wb, allowMalformed: true);
  final rels = <String, String>{};
  final relsData = _zipRead(archive, 'xl/_rels/workbook.xml.rels');
  if (relsData != null) {
    final relsXml = utf8.decode(relsData, allowMalformed: true);
    // 属性顺序不定：先取整个标签再独立抽 Id/Target
    for (final r in RegExp(r'<Relationship\b[^>]*>').allMatches(relsXml)) {
      final tag = r.group(0)!;
      final id = RegExp(r'\bId="([^"]+)"').firstMatch(tag)?.group(1);
      final target = RegExp(r'\bTarget="([^"]+)"').firstMatch(tag)?.group(1);
      if (id != null && target != null) rels[id] = target;
    }
  }
  final sb = StringBuffer();
  for (final s in RegExp(r'<sheet\b[^>]*?/?>').allMatches(wbXml)) {
    final tag = s.group(0)!;
    final name = RegExp(r'\bname="([^"]*)"').firstMatch(tag)?.group(1) ?? '';
    final rid =
        RegExp(r'r:id="([^"]*)"').firstMatch(tag)?.group(1) ??
        RegExp(r'\brid="([^"]*)"').firstMatch(tag)?.group(1);
    var target = rid == null ? null : rels[rid];
    if (target == null) continue;
    if (target.startsWith('/')) target = target.substring(1);
    final path = target.startsWith('xl/')
        ? target
        : 'xl/$target'; // Target 相对 xl/ 目录
    final sheetData = _zipRead(archive, path);
    if (sheetData == null) continue;
    final rows = _xlsxRows(
      utf8.decode(sheetData, allowMalformed: true),
      shared,
    );
    if (rows.isEmpty) continue;
    sb.writeln('## 工作表：${_xmlDecode(name)}');
    sb.writeln(rows);
    sb.writeln();
  }
  return sb.toString();
}

/// 单个 sheet 的行 → TSV（列由 r 属性字母推索引，空单元格补 tab 对齐）
String _xlsxRows(String xml, List<String> shared) {
  final sb = StringBuffer();
  for (final row in RegExp(r'<row\b.*?</row>', dotAll: true).allMatches(xml)) {
    var lastCol = 0;
    var line = StringBuffer();
    for (final c in RegExp(
      r'<c\b([^>]*?)/>|<c\b([^>]*?)>(.*?)</c>',
      dotAll: true,
    ).allMatches(row.group(0)!)) {
      final attrs = (c.group(1) ?? c.group(2))!;
      final body = c.group(3);
      // r="B3" → 列字母 → 从 1 计的列号
      final ref = RegExp('r="([A-Z]+)\\d+"').firstMatch(attrs)?.group(1);
      var col = 1;
      if (ref != null) {
        col = 0;
        for (final ch in ref.codeUnits) {
          col = col * 26 + (ch - 0x41 + 1);
        }
      }
      // 跳过的空列补 tab 对齐
      if (col > lastCol + 1) {
        line.write('\t' * (col - lastCol - 1));
      }
      if (col > lastCol) lastCol = col;
      final type = RegExp('t="([^"]*)"').firstMatch(attrs)?.group(1);
      var v = '';
      if (type == 's') {
        // 共享字符串索引
        final idx =
            int.tryParse(
              RegExp(r'<v>([^<]*)</v>').firstMatch(body ?? '')?.group(1) ?? '',
            ) ??
            -1;
        if (idx >= 0 && idx < shared.length) v = shared[idx];
      } else if (type == 'inlineStr') {
        v = RegExp(
          r'<t[^>]*>([^<]*)</t>',
        ).allMatches(body ?? '').map((m) => _xmlDecode(m.group(1)!)).join();
      } else if (type == 'b') {
        v = (RegExp(r'<v>([^<]*)</v>').firstMatch(body ?? '')?.group(1) == '1')
            ? 'TRUE'
            : 'FALSE';
      } else {
        v = _xmlDecode(
          RegExp(r'<v>([^<]*)</v>').firstMatch(body ?? '')?.group(1) ?? '',
        );
        // 公式字符串结果原样；数字保持原样（日期是序列号，
        // 样式在 styles.xml 里，轻量解析不做换算）
      }
      line
        ..write(v)
        ..write('\t');
    }
    final l = line.toString();
    if (l.isNotEmpty) sb.writeln(l.substring(0, l.length - 1)); // 去尾 tab
  }
  return sb.toString();
}

// ── PPTX：ppt/slides/slideN.xml 按页序，<a:t> 拼接 ──
String _extractPptx(Archive archive) {
  final slideNames = <int, String>{};
  for (var i = 0; i < archive.length; i++) {
    final m = RegExp(
      r'^ppt/slides/slide(\d+)\.xml$',
    ).firstMatch(archive[i].name);
    if (m != null) slideNames[int.parse(m.group(1)!)] = archive[i].name;
  }
  if (slideNames.isEmpty) throw const FormatException('pptx 没有幻灯片');
  final sb = StringBuffer();
  for (final n in slideNames.keys.toList()..sort()) {
    final xml = utf8.decode(
      _zipRead(archive, slideNames[n]!)!,
      allowMalformed: true,
    );
    sb.writeln('## 幻灯片 $n');
    // 段落 </a:p> 分行，段内 <a:t> 拼接
    for (final p in RegExp(
      r'<a:p>.*?</a:p>|<a:p/>',
      dotAll: true,
    ).allMatches(xml)) {
      sb.writeln(
        RegExp(
          r'<a:t>([^<]*)</a:t>',
        ).allMatches(p.group(0)!).map((m) => _xmlDecode(m.group(1)!)).join(),
      );
    }
    sb.writeln();
  }
  return sb.toString();
}

/// 文档解析便捷入口（compute 隔离执行，避免大文件解 zip 卡 UI）
Future<(String, bool)> parseDocumentAttachment(String name, List<int> bytes) =>
    compute(extractDocumentIsolate, (name, Uint8List.fromList(bytes)));
