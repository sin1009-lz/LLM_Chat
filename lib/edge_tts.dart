import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:web_socket_channel/io.dart';

/// ── Edge TTS（微软 Edge「大声朗读」端点，免密钥免费）──
/// 协议：wss + Sec-MS-GEC 反滥用令牌（edge-tts 同款实现）。
/// 返回 MP3 字节。国内直连可能 403（地域限流）——失败抛异常，
/// 调用方降级提示改用在线 API
class EdgeTts {
  static const _trustedToken = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';

  /// Sec-MS-GEC 令牌：Windows FILETIME 向下取整 5 分钟 + "800" +
  /// 受信令牌拼接后的 SHA256 大写十六进制（edge-tts drm.py 同款）
  static String _gec() {
    // 官方算法（edge-tts drm.py，已用官方包对照验证）：
    // unix 秒 + 11644473600 → 向下取整 300 秒 → ×1e7 转 100ns 刻度
    //（无 "800" 后缀——此前照错误记忆拼了 800 且 epoch 单位算错 = 403）
    final unix = DateTime.now().millisecondsSinceEpoch / 1000.0;
    var t = unix + 11644473600;
    t -= t % 300;
    final ticks = (t * 1e7).round();
    return crypto
        .sha256
        .convert(utf8.encode('$ticks$_trustedToken'))
        .toString()
        .toUpperCase();
  }

  static String _rid() {
    final r = Random();
    return List.generate(32, (_) => '0123456789abcdef'[r.nextInt(16)]).join();
  }

  static String _ts() {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final n = DateTime.now().toUtc();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${wd[n.weekday - 1]} ${mo[n.month - 1]} ${p(n.day)} ${n.year} '
        '${p(n.hour)}:${p(n.minute)}:${p(n.second)} GMT+0000 '
        '(Coordinated Universal Time)';
  }

  /// 合成一段文本 → MP3 字节。[voice] 形如 zh-CN-XiaoxiaoNeural；
  /// [rate] 语速（1.0 = 常速，映射 ±百分比）
  static Future<Uint8List> synth(
    String text, {
    String voice = 'zh-CN-XiaoxiaoNeural',
    double rate = 1.0,
  }) async {
    final ws = IOWebSocketChannel.connect(
      Uri.parse(
        'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud'
        '/edge/v1?TrustedClientToken=$_trustedToken'
        '&Sec-MS-GEC=${_gec()}&Sec-MS-GEC-Version=1-143.0.3650.75'
        '&ConnectionId=${_rid()}',
      ),
      headers: {
        'Pragma': 'no-cache',
        'Cache-Control': 'no-cache',
        'Origin': 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
        'User-Agent': _ua,
        'Accept-Encoding': 'gzip, deflate, br, zstd',
        'Accept-Language': 'en-US,en;q=0.9',
        // Cookie MUID（官方 DRM.headers_with_muid：随机 32 位大写 hex；
        // 服务端风控要求，缺它 403）
        'Cookie':
            'muid=${List.generate(32, (_) => '0123456789ABCDEF'[Random().nextInt(16)]).join()};',
      },
    );

    // 1) speech.config：输出格式 24kHz 48kbps mono MP3
    ws.sink.add(
      'X-Timestamp:${_ts()}\r\n'
      'Content-Type:application/json; charset=utf-8\r\n'
      'Path:speech.config\r\n\r\n'
      '{"context":{"synthesis":{"audio":{"metadataoptions":'
      '{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"true"},'
      '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}',
    );

    // 2) SSML 请求
    final esc = text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final ratePct = ((rate - 1) * 100).round().toString();
    ws.sink.add(
      'X-RequestId:${_rid()}\r\n'
      'Content-Type:application/ssml+xml\r\n'
      'X-Timestamp:${_ts()}Z\r\n'
      'Path:ssml\r\n\r\n'
      "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' "
      "xml:lang='zh-CN'><voice name='$voice'>"
      "<prosody pitch='+0Hz' rate='$ratePct%' volume='+0%'>$esc</prosody>"
      '</voice></speak>',
    );

    // 3) 收帧：二进制帧头（2 字节大端头长 + 头文本），Path:audio 的
    //    载荷追加；文本帧 Path:turn.end = 结束
    final audio = BytesBuilder();
    try {
      await for (final frame in ws.stream) {
        if (frame is String) {
          if (frame.contains('Path:turn.end')) break;
          continue;
        }
        if (frame is! List<int>) continue;
        if (frame.length < 2) continue;
        final headerLen = (frame[0] << 8) | frame[1];
        if (frame.length < 2 + headerLen) continue;
        final header = utf8.decode(frame.sublist(2, 2 + headerLen));
        if (header.contains('Path:audio')) {
          audio.add(frame.sublist(2 + headerLen));
        }
      }
    } finally {
      await ws.sink.close();
    }
    final bytes = audio.takeBytes();
    if (bytes.isEmpty) throw Exception('未收到音频数据');
    return bytes;
  }
}
