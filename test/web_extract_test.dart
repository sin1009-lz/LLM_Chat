import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/main.dart' show extractWebHtmlForTest;

void main() {
  test('HTML 正文提取：标题/正文优先级/去噪/实体', () {
    const html = '''
<html><head><title>测试页 &amp; 更多</title>
<style>.a{color:red}</style>
<script>var x=1;</script></head>
<body>
<nav>导航 登录</nav>
<header>页头</header>
<article>
  <h1>标题一</h1>
  <p>第一段&nbsp;内容 &lt;tag&gt; &amp; 符号</p>
  <div>第二段<div>嵌套</div></div>
  <br><br>
  <ul><li>项目一</li><li>项目二</li></ul>
</article>
<footer>页脚</footer>
<script>console.log(1)</script>
</body></html>
''';
    final (title, body) = extractWebHtmlForTest(html);
    expect(title, '测试页 & 更多');
    expect(body, contains('第一段 内容 <tag> & 符号'));
    expect(body, contains('项目一'));
    expect(body, contains('项目二'));
    expect(body, contains('嵌套'));
    // 噪音区不进正文
    expect(body, isNot(contains('导航 登录')));
    expect(body, isNot(contains('页脚')));
    expect(body, isNot(contains('var x=1')));
    expect(body, isNot(contains('color:red')));
  });

  test('无 article 时回退 main/body；纯文本透传字段', () {
    const html =
        '<html><head><title>T</title></head><body><main><p>主区</p></main></body></html>';
    final (title, body) = extractWebHtmlForTest(html);
    expect(title, 'T');
    expect(body, '主区');
  });

  test('数字实体解码', () {
    const html =
        '<html><body><article><p>&#20013;&#x6587;</p></article></body></html>';
    final (_, body) = extractWebHtmlForTest(html);
    expect(body, contains('中文'));
    expect(utf8.encode(body).length, greaterThan(0));
  });
}
