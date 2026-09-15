import 'dart:typed_data';

import 'package:flutter/services.dart';

/// ── Edge TTS（微软 Edge「大声朗读」端点，免密钥免费）──
/// 经 Android 平台通道用 OkHttp WebSocket 合成——Dart 的 TLS ClientHello
/// 指纹会被微软反滥用直接 403（同网络同参数 Python/OkHttp 放行，
/// PC 上 Dart 复现同样 403，实锤指纹过滤）。
class TtsWord {
  const TtsWord({required this.startMs, required this.durMs, required this.text});

  /// 词起点（ms，相对本段音频）
  final int startMs;
  final int durMs;
  final String text;
}

/// 一次合成的产物：MP3 音频 + 逐词时间戳（句级高亮的时间轴；
/// 协议未回传元数据时 words 为空，调用方降级为块级高亮）
class TtsSynth {
  const TtsSynth(this.audio, this.words);
  final Uint8List audio;
  final List<TtsWord> words;
}

class EdgeTts {
  static const _ch = MethodChannel('llm/edge_tts');

  /// 词时间戳恒定偏早修正：实测（真实服务合成 + 解码测语音起点）
  /// 偏差 ≈85ms——编码器 delay + 分析窗。社区流传的 875ms 常数来自
  /// Azure SDK 字幕场景，实测不适用于本端点（会反向偏晚 ~0.8s）
  static const _wordBiasMs = 85;

  /// 合成一段文本 → (MP3 字节, 逐词时间戳)。[voice] 形如
  /// zh-CN-XiaoxiaoNeural；[rate] 语速（1.0 = 常速）
  static Future<TtsSynth> synth(
    String text, {
    String voice = 'zh-CN-XiaoxiaoNeural',
    double rate = 1.0,
  }) async {
    final res = await _ch.invokeMethod<Object>('synth', {
      'text': text,
      'voice': voice,
      'ratePct': ((rate - 1) * 100).round(),
    });
    Uint8List audio;
    var words = const <TtsWord>[];
    if (res is Map) {
      final a = res['audio'];
      audio = a is Uint8List ? a : Uint8List.fromList((a as List).cast<int>());
      final ws = res['words'];
      if (ws is List) {
        words = ws
            .map((e) {
              final m = e as Map;
              final raw = (m['start'] as num?)?.toInt() ?? 0;
              return TtsWord(
                startMs: raw > _wordBiasMs ? raw - _wordBiasMs : 0,
                durMs: (m['dur'] as num?)?.toInt() ?? 0,
                text: m['text'] as String? ?? '',
              );
            })
            .where((w) => w.text.isNotEmpty)
            .toList(growable: false);
      }
    } else if (res is Uint8List) {
      // 旧格式兜底：纯音频字节
      audio = res;
    } else if (res is List) {
      audio = Uint8List.fromList(res.cast<int>());
    } else {
      throw Exception('合成返回格式异常');
    }
    if (audio.isEmpty) throw Exception('未收到音频数据');
    return TtsSynth(audio, words);
  }
}
