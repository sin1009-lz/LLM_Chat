import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llm_ui/chat.dart';

Message _m(String text, {Role role = Role.assistant}) =>
    Message(role: role, content: text, ts: DateTime(2026, 1, 1));

Conversation _conv(List<Message> msgs) => Conversation(
  id: 't1',
  title: 'T',
  messages: msgs,
  updatedAt: DateTime(2026, 1, 1),
);

void main() {
  test('v2 round-trip：分支尾索引引用还原', () {
    final msgs = [
      _m('a0', role: Role.user),
      _m('a1'),
      _m('a2'),
      _m('a3'),
    ];
    // 分支尾引用主列表消息 + 一条仅存在于其他时间线的消息
    final extra1 = _m('extra-timeline');
    msgs[1].branches = [
      MessageBranch(_m('anchor1'), [msgs[2], msgs[3]]),
      MessageBranch(_m('anchor2'), [msgs[2], extra1]),
    ];
    msgs[1].viewPos = 0;

    final j = msgs.first == msgs.first ? _conv(msgs).toJson() : null;
    expect(j, isNotNull);
    expect(j!['fmt'], 2);
    // tail 是索引引用而非全量对象
    final b0 = (j['messages'][1] as Map)['branches'][0] as Map;
    final b1 = (j['messages'][1] as Map)['branches'][1] as Map;
    expect((b0['tail'] as List).every((e) => e is int), true);
    // extra 消息进池（1 条）
    expect((j['extraMsgs'] as List).length, 1);

    // round-trip：内容等价还原
    final back = Conversation.fromJson(jsonDecode(jsonEncode(j))
        as Map<String, dynamic>);
    expect(back.messages.length, 4);
    expect(back.messages[1].branches!.length, 2);
    expect(back.messages[1].branches![0].tail.length, 2);
    expect(back.messages[1].branches![0].tail[1].content, 'a3');
    expect(back.messages[1].branches![1].tail[1].content, 'extra-timeline');
    expect(back.messages[1].branches![0].anchor.content, 'anchor1');
  });

  test('v1 兼容：旧格式全量 tail 正常解析', () {
    final v1 = {
      'id': 'old',
      'title': 'T',
      'fmt': 1,
      'updatedAt': '2026-01-01T00:00:00.000',
      'archived': false,
      'locked': false,
      'messages': [
        {
          'role': 0,
          'content': 'q',
          'ts': '2026-01-01T00:00:00.000',
          'viewPos': 0,
          'branches': [
            {
              'anchor': {
                'role': 0,
                'content': 'q',
                'ts': '2026-01-01T00:00:00.000',
              },
              'tail': [
                {'role': 1, 'content': 'old-reply', 'ts': '2026-01-01T00:00:00.000'},
              ],
            },
          ],
        },
      ],
    };
    final c = Conversation.fromJson(v1);
    expect(c.messages[0].branches![0].tail[0].content, 'old-reply');
  });

  test('平方级遏制：多分支长对话序列化大小线性', () {
    // 50 条消息 ×1KB；10 个分支点 × 每个 tail 前向引用 40 条消息
    //（真实形态：分支尾 = 分支点之后的消息快照，永远向后无环）
    final msgs = [
      for (var i = 0; i < 50; i++)
        _m(List.generate(20, (_) => '0123456789').join() + '#$i'),
    ];
    for (var b = 0; b < 10; b++) {
      msgs[b].branches = [
        MessageBranch(
          _m('anchor$b'),
          [for (var k = 1; k <= 40; k++) msgs[b + k]],
        ),
      ];
    }
    final json = jsonEncode(_conv(msgs).toJson());
    // 旧格式：10 分支 × 40 条 × ~1KB ≈ 400KB 重复正文；新格式正文
    // 只存 50 份（~52KB），总长应远小于旧值的一半
    expect(json.length, lessThan(120 * 1024), reason: 'json ${json.length} 字节');
    // round-trip 后分支内容完整
    final back = Conversation.fromJson(jsonDecode(json) as Map<String, dynamic>);
    expect(back.messages[5].branches![0].tail.length, 40);
    expect(back.messages[5].branches![0].tail[10].content, contains('#'));
  });

  test('图片消息在分支尾只序列化一份（base64 不翻倍）', () {
    final img = List.generate(100, (_) => 'ABCDEFGH').join(); // ~800B base64
    final msgs = [
      _m('u', role: Role.user),
      _m('a'),
    ];
    msgs[0].imageParts = [
      ImagePart(name: 'i.jpg', mimeType: 'image/jpeg', dataUrl: 'data:image/jpeg;base64,$img'),
    ];
    for (var b = 0; b < 5; b++) {
      msgs[0].branches = [
        ...(msgs[0].branches ?? []),
        MessageBranch(_m('an$b'), [msgs[1]]),
      ];
    }
    final json = jsonEncode(_conv(msgs).toJson());
    // 图片 dataUrl 只出现一次（旧格式会随分支数翻倍）
    expect('data:image/jpeg;base64,$img'.allMatches(json).length, 1);
  });
}
