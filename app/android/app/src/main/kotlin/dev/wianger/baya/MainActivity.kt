package dev.wianger.baya

import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity() {
    private val channelName = "dev.wianger.baya/read_aloud"
    private var channel: MethodChannel? = null
    private var textToSpeech: TextToSpeech? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)

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

    override fun onDestroy() {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }
}
