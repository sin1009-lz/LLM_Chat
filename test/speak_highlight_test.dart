import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/markdown_view.dart';

void main() {
  testWidgets('朗读块高亮：DecoratedBox 灰底出现', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            text: '第一段第一句。第二句！\n\n第二段第一句？第二句。',
            speakBlockIndex: 0,
            speakSentenceIndex: 0,
          ),
        ),
      ),
    );
    await tester.pump();
    // 找带背景色的 DecoratedBox（band）
    final bands = tester
        .widgetList<DecoratedBox>(
          find.byType(DecoratedBox),
        )
        .where(
          (db) =>
              db.decoration is BoxDecoration &&
              (db.decoration as BoxDecoration).color != null,
        )
        .toList();
    expect(bands, isNotEmpty, reason: '朗读中必须出现灰底 band');
  });

  testWidgets('句级高亮：句片切分后仍在同一 Column 内', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            text: '第一段第一句。第二句！\n\n第二段第一句？第二句。',
            speakBlockIndex: 0,
            speakSentenceIndex: 1,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(MarkdownBody), findsWidgets);
    // 句级路径：第一块渲染为句片 Column（≥2 个 MarkdownBody 属于同一块）
    expect(
      find.descendant(
        of: find.byType(Column),
        matching: find.byType(MarkdownBody),
      ),
      findsWidgets,
    );
  });

  testWidgets('非朗读状态：无 band', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MarkdownView(text: '普通文本。第二句。')),
      ),
    );
    await tester.pump();
    final bands = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .where(
          (db) =>
              db.decoration is BoxDecoration &&
              (db.decoration as BoxDecoration).color != null,
        )
        .toList();
    expect(bands, isEmpty);
  });
}
