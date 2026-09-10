import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/doc_extract.dart';

/// 真实文件回归（openpyxl / python-docx 生成）：验证解析器对
/// 真实 Office 文件结构（命名空间、样式表、rels 路径）的兼容性
void main() {
  test('真实 xlsx（openpyxl 生成）解析', () {
    final bytes = File('test/fixtures/工作簿1.xlsx').readAsBytesSync();
    final (text, truncated) = extractDocumentText('工作簿1.xlsx', bytes);
    expect(truncated, false);
    expect(text, contains('## 工作表：成绩表'));
    expect(text, contains('姓名\t分数\t\t备注'));
    expect(text, contains('张三\t95.5\t\t优秀 & 尖子生'));
    expect(text, contains('李四\t88'));
    expect(text, contains('## 工作表：汇总'));
    expect(text, contains('总数\t2'));
  });

  test('真实 docx（python-docx 生成）解析', () {
    final bytes = File('test/fixtures/文档1.docx').readAsBytesSync();
    final (text, _) = extractDocumentText('文档1.docx', bytes);
    expect(text, contains('第一段：你好世界'));
    expect(text, contains('列A\t列B'));
    expect(text, contains('1\t2'));
    expect(text, contains('结尾段 & 完'));
  });
}
