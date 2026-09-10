import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/doc_extract.dart';

/// 构造最小 OOXML zip（模拟真实 docx/xlsx/pptx 的结构）
List<int> buildZip(Map<String, String> entries) {
  final a = Archive();
  entries.forEach(
    (name, xml) => a.add(ArchiveFile.bytes(name, utf8.encode(xml))),
  );
  return ZipEncoder().encode(a);
}

void main() {
  test('xlsx：共享字符串/数字/多表解析为 TSV', () {
    final bytes = buildZip({
      '[Content_Types].xml': '<Types/>',
      'xl/workbook.xml':
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<sheets><sheet name="成绩表" sheetId="1" r:id="rId1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels':
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type=".../worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
      'xl/sharedStrings.xml':
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<si><t>姓名</t></si><si><t>分数</t></si><si><t>张三</t></si>'
          '<si><r><t>富</t></r><r><t>文本</t></r></si></sst>',
      'xl/worksheets/sheet1.xml':
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData>'
          '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row>'
          '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>95.5</v></c></row>'
          '<row r="3"><c r="A3" t="s"><v>3</v></c></row>'
          '</sheetData></worksheet>',
    });
    final (text, truncated) = extractDocumentText('工作簿1.xlsx', bytes);
    expect(truncated, false);
    // 工作表标题 + 表头行（C1 空列跳过 → A、C 之间一个 tab）
    expect(text, contains('## 工作表：成绩表'));
    expect(text, contains('姓名\t\t分数'));
    // 共享字符串 + 数字原样
    expect(text, contains('张三\t95.5'));
    // 富文本 si（多段 t 拼接）
    expect(text, contains('富文本'));
  });

  test('xlsx：inlineStr 与自闭合空单元格', () {
    final bytes = buildZip({
      'xl/workbook.xml':
          '<workbook><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels':
          '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
      'xl/worksheets/sheet1.xml':
          '<worksheet><sheetData>'
          '<row r="1"><c r="A1" t="inlineStr"><is><t>内联值</t></is></c>'
          '<c r="B1"/></row>'
          '</sheetData></worksheet>',
    });
    final (text, _) = extractDocumentText('a.xlsx', bytes);
    expect(text, contains('内联值'));
  });

  test('docx：段落/表格/tab/实体解码', () {
    final bytes = buildZip({
      'word/document.xml':
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
          '<w:body>'
          '<w:p><w:r><w:t>你好</w:t></w:r>'
          '<w:r><w:t xml:space="preserve"> 世界 &amp; 朋友</w:t></w:r></w:p>'
          '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>'
          '<w:tc><w:p><w:r><w:t>B1</w:t></w:r></w:p></w:tc></w:tr></w:tbl>'
          '<w:p><w:r><w:tab/></w:r><w:r><w:t>缩进</w:t></w:r></w:p>'
          '</w:body></w:document>',
    });
    final (text, _) = extractDocumentText('文档.docx', bytes);
    expect(text, contains('你好 世界 & 朋友'));
    expect(text, contains('A1\tB1'));
    expect(text, contains('\t缩进'));
  });

  test('pptx：按页序提取 <a:t>', () {
    final bytes = buildZip({
      'ppt/slides/slide1.xml':
          '<p:sld><p:txBody><a:p><a:r><a:t>标题页</a:t></a:r></a:p></p:txBody></p:sld>',
      'ppt/slides/slide10.xml':
          '<p:sld><a:p><a:r><a:t>第十页</a:t></a:r></a:p></p:sld>',
      'ppt/slides/slide2.xml':
          '<p:sld><a:p><a:r><a:t>第二页</a:t></a:r></a:p></p:sld>',
    });
    final (text, _) = extractDocumentText('演示.pptx', bytes);
    // 数字序而非字典序：slide2 在 slide10 前
    expect(text.indexOf('第二页'), lessThan(text.indexOf('第十页')));
    expect(text, contains('## 幻灯片 1'));
    expect(text, contains('标题页'));
  });

  test('超长内容截断 + 空内容抛异常 + 旧格式不支持', () {
    final big = buildZip({
      'word/document.xml':
          '<w:document><w:body><w:p><w:r><w:t>${'长' * 80000}</w:t></w:r></w:p></w:body></w:document>',
    });
    final (text, truncated) = extractDocumentText('big.docx', big);
    expect(truncated, true);
    expect(text.length, kMaxDocExtractChars);

    final empty = buildZip({'word/document.xml': '<w:document/>'});
    expect(() => extractDocumentText('e.docx', empty), throwsException);
    expect(() => extractDocumentText('old.xls', [1, 2, 3]), throwsException);
  });

  test('isDocAttachmentName 扩展名识别（大小写）', () {
    expect(isDocAttachmentName('a.XLSX'), true);
    expect(isDocAttachmentName('b.pptx'), true);
    expect(isDocAttachmentName('c.xlsx.bak'), false);
    expect(isDocAttachmentName('无扩展名'), false);
  });
}
