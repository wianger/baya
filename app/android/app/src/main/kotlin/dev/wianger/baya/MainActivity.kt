package dev.wianger.baya

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.tts.TextToSpeech
import android.provider.Settings
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val channelName = "dev.wianger.baya/read_aloud"
    private var channel: MethodChannel? = null
    private var textToSpeech: TextToSpeech? = null

    // PDFs opened for the Files page, rendered a page at a time off the UI thread.
    private val pdfChannelName = "dev.wianger.baya/pdf"
    private var pdfChannel: MethodChannel? = null
    private val pdfWorker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val pdfs = mutableMapOf<Int, PdfRenderer>()
    private var nextPdf = 1

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        Agents.attach(this, flutterEngine.dartExecutor.binaryMessenger)

        textToSpeech = TextToSpeech(this) { status ->
            if (status != TextToSpeech.SUCCESS) return@TextToSpeech
            textToSpeech?.setOnUtteranceProgressListener(
                object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) = Unit

                    override fun onDone(utteranceId: String?) {
                        channel?.invokeMethod("completed", null)
                    }

                    @Deprecated("Deprecated in Java")
                    override fun onError(utteranceId: String?) {
                        channel?.invokeMethod("completed", null)
                    }

                    override fun onError(utteranceId: String?, errorCode: Int) {
                        channel?.invokeMethod("completed", null)
                    }
                }
            )
        }

        // What the computer lists this phone as: the name the owner gave it
        // in Settings, else its maker and model.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.wianger.baya/device")
            .setMethodCallHandler { call, result ->
                if (call.method != "name") return@setMethodCallHandler result.notImplemented()
                val given = Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
                val model = if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) {
                    Build.MODEL
                } else {
                    "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"
                }
                result.success(given?.takeIf { it.isNotBlank() } ?: model)
            }

        pdfChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pdfChannelName)
        pdfChannel?.setMethodCallHandler { call, result ->
            fun reply(work: () -> Any?) = pdfWorker.execute {
                try {
                    val value = work()
                    main.post { result.success(value) }
                } catch (error: Exception) {
                    main.post { result.error("pdf", error.message ?: "$error", null) }
                }
            }
            when (call.method) {
                "open" -> reply {
                    val path = call.argument<String>("path")!!
                    val renderer = PdfRenderer(
                        ParcelFileDescriptor.open(File(path), ParcelFileDescriptor.MODE_READ_ONLY)
                    )
                    val id = nextPdf++
                    pdfs[id] = renderer
                    val sizes = (0 until renderer.pageCount).map { index ->
                        renderer.openPage(index).use { listOf(it.width, it.height) }
                    }
                    mapOf("id" to id, "sizes" to sizes)
                }
                "render" -> reply {
                    val renderer = pdfs[call.argument<Int>("id")!!]
                        ?: throw IllegalStateException("closed")
                    val width = call.argument<Int>("width")!!.coerceIn(1, 3000)
                    renderer.openPage(call.argument<Int>("page")!!).use { page ->
                        val height = (width.toLong() * page.height / page.width).toInt().coerceAtLeast(1)
                        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        bitmap.eraseColor(Color.WHITE)
                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        val out = ByteArrayOutputStream()
                        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                        bitmap.recycle()
                        out.toByteArray()
                    }
                }
                "close" -> reply {
                    pdfs.remove(call.argument<Int>("id")!!)?.close()
                    null
                }
                else -> result.notImplemented()
            }
        }

        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text")
                    val language = call.argument<String>("language") ?: "en-US"
                    val engine = textToSpeech
                    if (text.isNullOrBlank() || engine == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val locale = Locale.forLanguageTag(language)
                    if (engine.isLanguageAvailable(locale) >= TextToSpeech.LANG_AVAILABLE) {
                        engine.language = locale
                    }
                    engine.setSpeechRate(0.48f)
                    val params = Bundle().apply {
                        putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, "assistant")
                    }
                    val spoken = engine.speak(
                        text,
                        TextToSpeech.QUEUE_FLUSH,
                        params,
                        "assistant"
                    )
                    result.success(spoken == TextToSpeech.SUCCESS)
                }
                "stop" -> {
                    textToSpeech?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Agents.opened(intent)
    }

    override fun onDestroy() {
        // Leaving for good takes Dart with it: nothing would keep the
        // notifications current, or act on their buttons.
        if (isFinishing) Agents.detach(this)
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        channel?.setMethodCallHandler(null)
        channel = null
        pdfChannel?.setMethodCallHandler(null)
        pdfChannel = null
        pdfWorker.execute {
            pdfs.values.forEach { it.close() }
            pdfs.clear()
        }
        pdfWorker.shutdown()
        super.onDestroy()
    }
}
