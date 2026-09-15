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
                        // Kimi 同款架构：客户端零处理，音频原样直传——
                        // 间距由合成端产出（Dart 侧按 markdown 块整块合成，
                        // 句间距在单次合成内部由韵律引擎产生，天然统一）
                        main.post {
                            replyOnce {
                                if (bytes.isEmpty()) result.error("empty", "no audio", null)
                                else result.success(bytes.toByteString().toByteArray())
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

}
