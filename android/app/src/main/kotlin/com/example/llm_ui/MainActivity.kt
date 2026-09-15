package com.example.llm_ui

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    companion object {
        private const val TOK = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
        private const val UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"
    }

    /** Sec-MS-GEC（edge-tts drm.py 同款）：unix 秒 +11644473600 →
     *  %300 取整 → ×1e7 转 100ns → +受信令牌 → SHA256 大写 */
    private fun gec(): String {
        val t = (System.currentTimeMillis() / 1000.0 + 11644473600.0).let {
            Math.floor(it / 300.0) * 300.0
        }
        val ticks = (t * 1e7).toLong()
        val s = "$ticks$TOK"
        val d = MessageDigest.getInstance("SHA-256").digest(s.toByteArray(Charsets.US_ASCII))
        return d.joinToString("") { "%02X".format(it) }
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "llm/edge_tts")
            .setMethodCallHandler { call, result ->
                if (call.method == "synth") {
                    val text = call.argument<String>("text") ?: ""
                    val voice = call.argument<String>("voice") ?: "zh-CN-XiaoxiaoNeural"
                    val rate = call.argument<Int>("ratePct") ?: 0
                    synth(text, voice, rate, result)
                } else {
                    result.notImplemented()
                }
            }
    }

    /** OkHttp WebSocket 合成（Dart TLS 指纹被微软 403，OkHttp 指纹放行） */
    private fun synth(text: String, voice: String, ratePct: Int, result: MethodChannel.Result) {
        val main = Handler(Looper.getMainLooper())
        try {
            val url =
                "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud" +
                    "/edge/v1?TrustedClientToken=$TOK" +
                    "&Sec-MS-GEC=${gec()}" +
                    "&Sec-MS-GEC-Version=1-143.0.3650.75" +
                    "&ConnectionId=${UUID.randomUUID().toString().replace("-", "")}"
            val muid = (1..32).map { "0123456789ABCDEF".random() }.joinToString("")
            val req = Request.Builder()
                .url(url)
                .header("Pragma", "no-cache")
                .header("Cache-Control", "no-cache")
                .header("Origin", "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold")
                .header("User-Agent", UA)
                .header("Accept-Encoding", "gzip, deflate, br, zstd")
                .header("Accept-Language", "en-US,en;q=0.9")
                .header("Cookie", "muid=$muid;")
                .build()

            val client = OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(60, TimeUnit.SECONDS)
                .build()

            val audio = java.io.ByteArrayOutputStream()
            val esc = text
                .replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

            val wsListener = object : WebSocketListener() {
                private var opened = false
                // 一次性回复守卫：turn.end 已 success 后，关闭/失败回调
                // 再触发 result.* 会抛 Reply already submitted 崩溃
                private val answered = java.util.concurrent.atomic.AtomicBoolean(false)
                private fun replyOnce(body: () -> Unit) {
                    if (answered.compareAndSet(false, true)) body()
                }

                override fun onOpen(webSocket: WebSocket, response: Response) {
                    opened = true
                    webSocket.send(
                        "X-Timestamp:Na\r\n" +
                            "Content-Type:application/json; charset=utf-8\r\n" +
                            "Path:speech.config\r\n\r\n" +
                            "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":" +
                            "{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"true\"}," +
                            "\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}"
                    )
                    webSocket.send(
                        "X-RequestId:${UUID.randomUUID().toString().replace("-", "")}\r\n" +
                            "Content-Type:application/ssml+xml\r\n" +
                            "X-Timestamp:NaZ\r\n" +
                            "Path:ssml\r\n\r\n" +
                            "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' " +
                            "xml:lang='zh-CN'><voice name='$voice'>" +
                            "<prosody pitch='+0Hz' rate='$ratePct%' volume='+0%'>$esc</prosody>" +
                            "</voice></speak>"
                    )
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    val f = bytes.toByteArray()
                    if (f.size < 2) return
                    val headerLen = ((f[0].toInt() and 0xFF) shl 8) or (f[1].toInt() and 0xFF)
                    if (f.size < 2 + headerLen) return
                    val header = String(f, 2, headerLen, Charsets.US_ASCII)
                    if (header.contains("Path:audio")) {
                        audio.write(f, 2 + headerLen, f.size - 2 - headerLen)
                    }
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    if (text.contains("Path:turn.end")) {
                        webSocket.close(1000, null)
                        val bytes = audio.toByteArray()
                        // 段间统一的关键：MP3 每段带编码器 delay/padding
                        //（~26ms 头静音 + 尾填充）+ 合成自身的前导静音——
                        // 队列边界间距参差不齐。解码到 PCM 裁掉首尾静音后
                        // 输出 WAV（零编码器填充），段间距归一。
                        // 失败回退原 MP3——Dart 侧按 RIFF 魔数嗅探 contentType，
                        // 回退段与 WAV 段各自类型自洽，不会再被当成 WAV 解析
                        val wav = try { mp3ToTrimmedWav(bytes) } catch (e: Exception) { null }
                        main.post {
                            replyOnce {
                                if (bytes.isEmpty()) result.error("empty", "no audio", null)
                                else result.success(wav ?: bytes)
                            }
                        }
                    }
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    main.post {
                        replyOnce { result.error("ws", t.message ?: "fail", null) }
                    }
                }
            }
            client.newWebSocket(req, wsListener)
        } catch (e: Exception) {
            main.post { result.error("err", e.message, null) }
        }
    }

    // ── MP3 → 裁静音 WAV（段间距归一）──
    // MP3 帧边界带编码器 delay/padding 静音；合成也可能带前导静音。
    // 解码成 PCM16 后按振幅阈值裁首尾（保留 20ms 缓冲），封 WAV 头
    // ——WAV 无填充，队列衔接自然紧
    private fun mp3ToTrimmedWav(mp3: ByteArray): ByteArray? {
        val tmp = java.io.File.createTempFile("tts", ".mp3", cacheDir)
        try {
            tmp.writeBytes(mp3)
            val extractor = android.media.MediaExtractor()
            extractor.setDataSource(tmp.absolutePath)
            val fmt = extractor.getTrackFormat(0)
            val sampleRate = fmt.getInteger(android.media.MediaFormat.KEY_SAMPLE_RATE)
            val channels = fmt.getInteger(android.media.MediaFormat.KEY_CHANNEL_COUNT)
            extractor.selectTrack(0)
            val codec = android.media.MediaCodec.createDecoderByType(fmt.getString(android.media.MediaFormat.KEY_MIME) ?: "audio/mpeg")
            codec.configure(fmt, null, null, 0)
            codec.start()
            val pcm = java.io.ByteArrayOutputStream()
            val info = android.media.MediaCodec.BufferInfo()
            var sawInputEOS = false
            var sawOutputEOS = false
            while (!sawOutputEOS) {
                if (!sawInputEOS) {
                    val inIdx = codec.dequeueInputBuffer(10000)
                    if (inIdx >= 0) {
                        val buf = codec.getInputBuffer(inIdx)!!
                        val sz = extractor.readSampleData(buf, 0)
                        if (sz < 0) {
                            codec.queueInputBuffer(inIdx, 0, 0, 0, android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            sawInputEOS = true
                        } else {
                            codec.queueInputBuffer(inIdx, 0, sz, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outIdx = codec.dequeueOutputBuffer(info, 10000)
                if (outIdx >= 0) {
                    val out = codec.getOutputBuffer(outIdx)!!
                    val bytes = ByteArray(info.size)
                    out.get(bytes)
                    pcm.write(bytes)
                    codec.releaseOutputBuffer(outIdx, false)
                    if (info.flags and android.media.MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) sawOutputEOS = true
                }
            }
            codec.stop(); codec.release(); extractor.release()
            return trimSilenceToWav(pcm.toByteArray(), sampleRate, channels)
        } finally {
            tmp.delete()
        }
    }

    /// PCM16：按 16bit 采样幅值裁首尾静音，阈值 ≈ -46dB（振幅 250），
    /// 各留 20ms 缓冲；裁后不足 100ms 视为异常（吞内容）→ 返回 null
    /// 走 MP3 回退；封 44 字节 WAV 头
    private fun trimSilenceToWav(pcm: ByteArray, sampleRate: Int, channels: Int): ByteArray? {
        if (pcm.size < 4) return null
        val totalSamples = pcm.size / 2
        val amp = ShortArray(totalSamples)
        var peak: Int = 1
        java.nio.ByteBuffer.wrap(pcm).order(java.nio.ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(amp)
        for (a in amp) { val v = if (a < 0) -a.toInt() else a.toInt(); if (v > peak) peak = v }
        val threshold = (peak * 0.005).toInt().coerceAtLeast(60)  // 峰值 0.5% 且 ≥60
        val winMs = 20
        val win = (sampleRate * winMs / 1000).coerceAtLeast(1)
        var start = 0
        run {
            var run = 0
            for (i in amp.indices) {
                val v = if (amp[i] < 0) -amp[i].toInt() else amp[i].toInt()
                run = if (v > threshold) run + 1 else 0
                if (run >= win) { start = (i - win + 1).coerceAtLeast(0); break }
            }
        }
        var end = totalSamples
        run {
            var run = 0
            for (i in amp.indices.reversed()) {
                val v = if (amp[i] < 0) -amp[i].toInt() else amp[i].toInt()
                run = if (v > threshold) run + 1 else 0
                if (run >= win) { end = (i + win).coerceAtMost(totalSamples); break }
            }
        }
        // 裁后过短 = 裁剪异常（吞内容），宁可不裁走 MP3 回退
        if (end <= start || (end - start) < sampleRate / 10) return null
        val trimmed = pcm.copyOfRange(start * 2, end * 2)
        val byteRate = sampleRate * channels * 2
        val out = java.io.ByteArrayOutputStream(44 + trimmed.size)
        val h = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()); h.putInt(36 + trimmed.size)
        h.put("WAVE".toByteArray()); h.put("fmt ".toByteArray()); h.putInt(16)
        h.putShort(1); h.putShort(channels.toShort()); h.putInt(sampleRate); h.putInt(byteRate)
        h.putShort((channels * 2).toShort()); h.putShort(16)
        h.put("data".toByteArray()); h.putInt(trimmed.size)
        out.write(h.array()); out.write(trimmed)
        return out.toByteArray()
    }
}
