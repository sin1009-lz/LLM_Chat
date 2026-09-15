import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/edge_tts.dart';
import 'package:llm_ui/markdown_view.dart';

/// 复刻 main.dart _sentenceStartWords（私有方法，逻辑须保持一致）
List<int> sentenceStartWordsReplica(List<String> sentences, List<TtsWord> words) {
  final flat = StringBuffer();
  final owner = <int>[];
  for (var i = 0; i < words.length; i++) {
    final t = words[i].text.replaceAll(RegExp(r'\s'), '');
    for (var c = 0; c < t.length; c++) {
      flat.write(t[c]);
      owner.add(i);
    }
  }
  final s = flat.toString();
  final starts = List<int>.filled(sentences.length, -1);
  var ptr = 0;
  for (var si = 0; si < sentences.length; si++) {
    final norm = sentences[si]
        .replaceAll(RegExp(r'\s'), '')
        .replaceFirst(RegExp(r'^[#>*\-]+'), '');
    if (norm.isEmpty) continue;
    final probe = norm.substring(0, norm.length < 3 ? norm.length : 3);
    final at = s.indexOf(probe, ptr);
    if (at < 0) continue;
    starts[si] = owner[at];
    ptr = at + probe.length;
  }
  return starts;
}

void main() {
  test('真实抓包词戳 + 纯文本段落：句子起点对齐', () {
    const block = '今天天气很好。我们去公园散步，然后再回家吃饭。';
    final sentences = splitProseSentences(block)!;
    // PC 抓包实测 WordBoundary（ms）
    final words = const [
      ('今天', 15), ('天气', 403), ('很', 753), ('好', 990),
      ('我们', 1903), ('去', 2140), ('公园', 2540), ('散步', 3028),
      ('然后', 3653), ('再', 3990), ('回家', 4228), ('吃饭', 4703),
    ].map((e) => TtsWord(startMs: e.$2, durMs: 300, text: e.$1)).toList();
    final starts = sentenceStartWordsReplica(sentences, words);
    expect(sentences.length, 2);
    expect(starts[0], 0);
    expect(starts[1], greaterThanOrEqualTo(4));
  });

  test('带 markdown 的典型助手段落：探针不被残留字符卡死', () {
    const block = '**性能优化**完成后，应用更流畅了。我们还修复了三个问题。';
    final sentences = splitProseSentences(block);
    // 断句不应被 ** 内部的句号影响（标记不失衡）
    expect(sentences, isNotNull);
    final words = const [
      ('性能优化', 15), ('完成后', 700), ('应用更流畅了', 1500),
      ('我们还修复了三个问题', 3000),
    ].map((e) => TtsWord(startMs: e.$2, durMs: 300, text: e.$1)).toList();
    final starts = sentenceStartWordsReplica(sentences!, words);
    // 每句都应找到起点（句首 ** 已剥，探针应命中）
    for (final st in starts) {
      expect(st, greaterThanOrEqualTo(0), reason: 'starts=$starts');
    }
  });
}
