import 'package:markdown/markdown.dart' as md;

void main() {
  final lines = <String>[];
  for (var i = 0; i < 400; i++) {
    lines.add('def func_$i(x):  # note home');
    lines.add('    return x * ${i + 1}');
  }
  final tail = '```python\n${lines.join('\n')}\n'; // 开围栏（流式中）
  print('tail bytes=${tail.length}');
  final doc = md.Document(
    inlineSyntaxes: [],
    extensionSet: md.ExtensionSet.gitHubWeb,
  );
  final sw = Stopwatch()..start();
  for (var i = 0; i < 20; i++) {
    doc.parseLines(tail.split('\n'));
  }
  sw.stop();
  print('markdown 解析开围栏×20: ${sw.elapsedMilliseconds}ms → 每次 ${(sw.elapsedMilliseconds / 20).toStringAsFixed(2)}ms');
}
