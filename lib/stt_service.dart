import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// ── 语音输入（STT）：sherpa-onnx 本地流式识别 ──
/// 模型：streaming-zipformer-bilingual-zh-en（中英双语，边说边出字），
/// 全程离线。模型文件按直链下载到应用支持目录（免解压）：
/// hf-mirror 主源（国内直连）+ HuggingFace 官方备源。
class SttService {
  SttService._();

  static final SttService I = SttService._();

  static const _repo =
      'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20';

  /// (文件名, 期望字节) —— 期望值用于断点校验；实际以下载响应为准
  static const _files = <String>[
    'encoder-epoch-99-avg-1.int8.onnx',
    'decoder-epoch-99-avg-1.onnx',
    'joiner-epoch-99-avg-1.onnx',
    'tokens.txt',
  ];

  static const _mirrors = <String>[
    'https://hf-mirror.com/$_repo/resolve/main',
    'https://huggingface.co/$_repo/resolve/main',
  ];

  /// 模型目录（应用支持目录下，卸载即清）
  Future<String> modelDir() async =>
      p.join((await getApplicationSupportDirectory()).path, 'stt-model');

  /// 四个文件齐且非零 → 就绪
  Future<bool> get isReady async {
    try {
      final dir = await modelDir();
      for (final f in _files) {
        final file = File(p.join(dir, f));
        if (!await file.exists() || await file.length() == 0) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 逐文件下载（.part 临时文件 + 完成改名，可断点重下）。
  /// 进度 0..1（按文件数 + 当前文件字节折算）
  Future<void> download(void Function(double)? onProgress) async {
    final dir = await modelDir();
    await Directory(dir).create(recursive: true);
    for (var i = 0; i < _files.length; i++) {
      final name = _files[i];
      final target = p.join(dir, name);
      if (await File(target).exists() && await File(target).length() > 0) {
        continue; // 已下载（断点续传：整文件粒度）
      }
      final part = '$target.part';
      Object? lastErr;
      for (final mirror in _mirrors) {
        try {
          await _downloadFile(
            '$mirror/$name',
            part,
            name == 'tokens.txt' ? null : 60 * 5,
            (frac) => onProgress?.call((i + frac) / _files.length),
          );
          await File(part).rename(target);
          lastErr = null;
          break;
        } catch (e) {
          lastErr = e;
        }
      }
      if (lastErr != null) {
        final partFile = File(part);
        if (await partFile.exists()) await partFile.delete();
        throw Exception('下载失败：$lastErr');
      }
    }
    onProgress?.call(1);
  }

  /// 单文件流式下载（进度回调按 content-length 折算 0..1）
  Future<void> _downloadFile(
    String url,
    String savePath,
    int? timeoutSec,
    void Function(double frac)? onFrac,
  ) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(url));
      final resp = await client.send(req).timeout(
        Duration(seconds: timeoutSec ?? 30),
      );
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final total = resp.contentLength ?? 0;
      final sink = File(savePath).openWrite();
      var done = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0 && onFrac != null) {
          onFrac((done / total).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();
      if (total > 0 && done != total) throw Exception('不完整（$done/$total）');
    } finally {
      client.close();
    }
  }

  Future<void> delete() async {
    _rec?.free();
    _rec = null;
    final dir = await modelDir();
    final d = Directory(dir);
    if (await d.exists()) await d.delete(recursive: true);
  }

  // ── 识别（懒加载，首次起播加载模型 1-3 秒）──
  sherpa.OnlineRecognizer? _rec;

  Future<sherpa.OnlineRecognizer> _recognizer() async {
    if (_rec != null) return _rec!;
    sherpa.initBindings();
    final dir = await modelDir();
    _rec = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: p.join(dir, _files[0]),
            decoder: p.join(dir, _files[1]),
            joiner: p.join(dir, _files[2]),
          ),
          tokens: p.join(dir, _files[3]),
          modelType: 'zipformer',
          debug: false,
          numThreads: 4,
        ),
      ),
    );
    return _rec!;
  }

  // ── 录音会话 ──
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription? _sub;
  sherpa.OnlineStream? _stream;
  String _committed = '';

  /// 开始流式识别。onUpdate 收"已定稿 + 当前增量"全文；
  /// 静音断句自动定稿追加。模型未就绪/无权限抛异常
  Future<void> start(void Function(String text) onUpdate) async {
    if (!await isReady) throw Exception('语音模型未就绪（先在设置中下载）');
    if (!await _recorder.hasPermission()) throw Exception('未授予麦克风权限');
    final rec = await _recognizer();
    await stop();
    _stream?.free();
    _stream = rec.createStream();
    _committed = '';
    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _sub = stream.listen((data) {
      final s = _stream;
      if (s == null) return;
      s.acceptWaveform(samples: _bytesToFloat32(data), sampleRate: 16000);
      while (rec.isReady(s)) {
        rec.decode(s);
      }
      final text = rec.getResult(s).text;
      onUpdate(_committed + text);
      // 静音断句：该段定稿，开启下一段（识别器内部分句边界）
      if (rec.isEndpoint(s)) {
        if (text.isNotEmpty) _committed += text;
        rec.reset(s);
        onUpdate(_committed);
      }
    });
  }

  /// 结束并返回最终全文（不再补尾帧：增量文本已实时上报）
  Future<String> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    return _committed;
  }

  void dispose() {
    _sub?.cancel();
    _stream?.free();
    _stream = null;
    _rec?.free();
    _rec = null;
    _recorder.dispose();
  }

  /// PCM16 LE → Float32（-1..1），record 流式回调的数据格式
  Float32List _bytesToFloat32(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final out = Float32List(n);
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    for (var i = 0; i < n; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }
}
