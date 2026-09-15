import 'dart:typed_data';

import 'package:flutter/services.dart';

/// ── Edge TTS（微软 Edge「大声朗读」端点，免密钥免费）──
/// 经 Android 平台通道用 OkHttp WebSocket 合成——Dart 的 TLS ClientHello
/// 指纹会被微软反滥用直接 403（同网络同参数 Python/OkHttp 放行，
/// PC 上 Dart 复现同样 403，实锤指纹过滤）。返回 MP3 字节。
class EdgeTts {
  static const _ch = MethodChannel('llm/edge_tts');

  /// 合成一段文本 → MP3 字节。[voice] 形如 zh-CN-XiaoxiaoNeural；
  /// [rate] 语速（1.0 = 常速）
  static Future<Uint8List> synth(
    String text, {
    String voice = 'zh-CN-XiaoxiaoNeural',
    double rate = 1.0,
  }) async {
    final bytes = await _ch.invokeListMethod<int>('synth', {
      'text': text,
      'voice': voice,
      'ratePct': ((rate - 1) * 100).round(),
    });
    if (bytes == null || bytes.isEmpty) throw Exception('未收到音频数据');
    return Uint8List.fromList(bytes);
  }
}
