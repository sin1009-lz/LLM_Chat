import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/markdown_view.dart';

void main() {
  group('splitProseSentences（朗读句级高亮切分）', () {
    test('中文句末标点断句', () {
      final s = splitProseSentences('今天天气很好。我们去公园！走了多远？');
      expect(s, ['今天天气很好。', '我们去公园！', '走了多远？']);
    });

    test('强调/行内代码内部不断句（标记不失衡）', () {
      final s = splitProseSentences('**加粗。内部**结束。');
      expect(s, ['**加粗。内部**结束。']);
      final s2 = splitProseSentences('代码 `foo(); bar()` 结束。后一句。');
      expect(s2, ['代码 `foo(); bar()` 结束。', '后一句。']);
    });

    test('ASCII 问号仅在后随空白/CJK 时断句（URL 不切断）', () {
      final s = splitProseSentences('看这个 https://x.com/a?b=1 对吗？好的。');
      expect(s!.length, 2);
      expect(s.first, contains('?b=1'));
    });

    test('含围栏/表格行返回 null；列表块按条目切分', () {
      expect(splitProseSentences('```dart\ncode\n```'), isNull);
      expect(splitProseSentences('| a | b |\n| - | - |'), isNull);
      // 列表 → 顶级条目片
      final items = splitProseSentences('- 第一条。第二条。\n- 第二项。\n- 第三项');
      expect(items, hasLength(3));
      expect(items!.first, startsWith('- 第一条'));
    });

    test('有序列表按条目切分', () {
      final items = splitProseSentences('1. 步骤一\n2. 步骤二\n3. 步骤三');
      expect(items, hasLength(3));
      expect(items![1], '2. 步骤二');
    });

    test('引导句+列表：引导句自成一片', () {
      final items = splitProseSentences('步骤如下：\n- 甲\n- 乙');
      expect(items, hasLength(3));
      expect(items!.first, '步骤如下：');
    });

    test('松散列表条目（空行分隔）各成一片', () {
      final items = splitProseSentences('- 第一项\n\n- 第二项\n\n- 第三项');
      expect(items, hasLength(3));
    });

    test('无句末标点的整段为一句', () {
      final s = splitProseSentences('一段没有标点结尾的文字');
      expect(s, ['一段没有标点结尾的文字']);
    });

    test('空块返回 null', () {
      expect(splitProseSentences('  \n '), isNull);
    });
  });
  test('空行切块：段落各自成块', () {
    final blocks = splitMarkdownBlocks('第一段。\n\n第二段。\n\n第三段。');
    expect(blocks, ['第一段。', '第二段。', '第三段。']);
  });

  test('松散列表（空行分隔项）合并为一个块', () {
    const src = '- 第一项\n\n- 第二项\n\n- 第三项';
    final blocks = splitMarkdownBlocks(src);
    expect(blocks, hasLength(1));
    expect(blocks.first, contains('第一项'));
    expect(blocks.first, contains('第三项'));
  });

  test('列表后接普通段落：列表块在此截断', () {
    final blocks = splitMarkdownBlocks('- 第一项\n\n- 第二项\n\n后续段落。');
    expect(blocks, hasLength(2));
    expect(blocks.first, startsWith('- 第一项'));
    expect(blocks.last, '后续段落。');
  });

  test('有序/无序混合空行延续不误并（列表结束于普通段）', () {
    final blocks = splitMarkdownBlocks('1. 步骤一\n\n2. 步骤二\n\n结论在这里。');
    expect(blocks, hasLength(2));
    expect(blocks.first, contains('步骤二'));
    expect(blocks.last, '结论在这里。');
  });

  test('围栏代码块：内容含空行仍是一个块', () {
    const src = '```dart\nvoid main() {\n\n  print(1);\n}\n```\n\n正文段。';
    final blocks = splitMarkdownBlocks(src);
    expect(blocks, hasLength(2));
    expect(blocks.first, contains('```dart'));
    expect(blocks.first, contains('print(1)'));
    expect(blocks.last, '正文段。');
  });

  test('表格：连续行为一个块，与前后段落分开', () {
    const src = '前文。\n\n| 列1 | 列2 |\n| --- | --- |\n| a | b |\n\n后文。';
    final blocks = splitMarkdownBlocks(src);
    expect(blocks, hasLength(3));
    expect(blocks[1], contains('| a | b |'));
  });

  test('列表缩进续行（空行后缩进内容）仍属于列表块', () {
    const src = '- 第一项\n\n  补充说明\n\n- 第二项\n\n段落。';
    final blocks = splitMarkdownBlocks(src);
    expect(blocks, hasLength(2));
    expect(blocks.first, contains('补充说明'));
    expect(blocks.last, '段落。');
  });

  test('段落内软换行（无空行）不成块边界', () {
    final blocks = splitMarkdownBlocks('第一行，\n第二行。\n第三行。');
    expect(blocks, hasLength(1));
  });

  test('紧邻列表（无空行）与引导段落是一个块', () {
    final blocks = splitMarkdownBlocks('步骤如下：\n- 甲\n- 乙');
    expect(blocks, hasLength(1));
  });

  test('空文本与纯空行不产生块', () {
    expect(splitMarkdownBlocks(''), isEmpty);
    expect(splitMarkdownBlocks('\n\n\n'), isEmpty);
  });
}
