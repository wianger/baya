package dev.wianger.baya

import android.app.Activity
import android.content.Context
import android.graphics.Rect
import android.net.ConnectivityManager
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.Surface
import android.view.SurfaceHolder
import com.limelight.binding.audio.AndroidAudioRenderer
import com.limelight.binding.crypto.AndroidCryptoProvider
import com.limelight.binding.video.CrashListener
import com.limelight.binding.video.MediaCodecDecoderRenderer
import com.limelight.binding.video.PerfOverlayListener
import com.limelight.nvstream.NvConnection
import com.limelight.nvstream.NvConnectionListener
import com.limelight.nvstream.StreamConfiguration
import com.limelight.nvstream.http.ComputerDetails
import com.limelight.nvstream.http.NvApp
import com.limelight.nvstream.http.NvHTTP
import com.limelight.nvstream.http.PairingManager
import com.limelight.nvstream.input.KeyboardPacket
import com.limelight.nvstream.jni.MoonBridge
import com.limelight.preferences.PreferenceConfiguration
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayInputStream
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.Executors

/**
 * A computer's screen through Moonlight's streaming core: pairing with
 * Sunshine, a stream decoded by MediaCodec in low-latency mode straight
 * into a Flutter texture, and the mouse and keyboard back.
 */
object Moonlight {
    private const val HTTP_PORT = 47989
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private lateinit var activity: Activity
    private lateinit var textures: TextureRegistry
    private var events: EventChannel.EventSink? = null

    private var connection: NvConnection? = null
    private var producer: TextureRegistry.SurfaceProducer? = null
    private var decoder: MediaCodecDecoderRenderer? = null

    fun attach(activity: Activity, engine: FlutterEngine) {
        this.activity = activity
        textures = engine.renderer
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "dev.wianger.baya/moonlight").setMethodCallHandler(::handle)
        EventChannel(messenger, "dev.wianger.baya/moonlight/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            },
        )
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }

    /** This phone to Sunshine: one random id per install, as Moonlight keeps it. */
    private fun uniqueId(context: Context): String {
        val prefs = context.getSharedPreferences("moonlight", Context.MODE_PRIVATE)
        prefs.getString("unique_id", null)?.let { return it }
        val bytes = ByteArray(8).also { SecureRandom().nextBytes(it) }
        val id = bytes.joinToString("") { "%02x".format(it) }
        prefs.edit().putString("unique_id", id).apply()
        return id
    }

    private fun crypto() = AndroidCryptoProvider(activity.applicationContext)

    private fun certificate(base64: String?): X509Certificate? = base64?.let {
        CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(Base64.decode(it, Base64.NO_WRAP))) as X509Certificate
    }

    private fun http(address: String, cert: X509Certificate?) = NvHTTP(
        ComputerDetails.AddressTuple(address, HTTP_PORT),
        0,
        uniqueId(activity),
        cert,
        crypto(),
    )

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        fun background(work: () -> Any?) = worker.execute {
            try {
                val value = work()
                main.post { result.success(value) }
            } catch (error: Exception) {
                main.post { result.error("moonlight", error.message ?: error.toString(), null) }
            }
        }
        val connection = connection
        when (call.method) {
            // Pairs with [pin], which the computer's Baya hands to Sunshine.
            "pair" -> background {
                val address = call.argument<String>("address")!!
                val pin = call.argument<String>("pin")!!
                val http = http(address, null)
                val pairing = http.pairingManager
                val state = pairing.pair(http.getServerInfo(true), pin)
                mapOf(
                    "state" to state.name,
                    "cert" to pairing.pairedCert?.let { Base64.encodeToString(it.encoded, Base64.NO_WRAP) },
                )
            }
            "paired" -> background {
                val http = http(call.argument<String>("address")!!, certificate(call.argument("cert")))
                http.getPairState() == PairingManager.PairState.PAIRED
            }
            "start" -> start(call, result)
            "stop" -> {
                stop()
                result.success(null)
            }
            "mouseMove" -> {
                connection?.sendMouseMove(
                    (call.argument<Int>("dx") ?: 0).toShort(),
                    (call.argument<Int>("dy") ?: 0).toShort(),
                )
                result.success(null)
            }
            "mousePosition" -> {
                connection?.sendMousePosition(
                    (call.argument<Int>("x") ?: 0).toShort(),
                    (call.argument<Int>("y") ?: 0).toShort(),
                    (call.argument<Int>("width") ?: 1).toShort(),
                    (call.argument<Int>("height") ?: 1).toShort(),
                )
                result.success(null)
            }
            "button" -> {
                val button = (call.argument<Int>("button") ?: 1).toByte()
                if (call.argument<Boolean>("down") == true) {
                    connection?.sendMouseButtonDown(button)
                } else {
                    connection?.sendMouseButtonUp(button)
                }
                result.success(null)
            }
            "scroll" -> {
                val amount = (call.argument<Int>("amount") ?: 0).toShort()
                if (call.argument<Boolean>("horizontal") == true) {
                    connection?.sendMouseHighResHScroll(amount)
                } else {
                    connection?.sendMouseHighResScroll(amount)
                }
                result.success(null)
            }
            "key" -> {
                connection?.sendKeyboardInput(
                    (call.argument<Int>("code") ?: 0).toShort(),
                    if (call.argument<Boolean>("down") == true) KeyboardPacket.KEY_DOWN else KeyboardPacket.KEY_UP,
                    (call.argument<Int>("modifiers") ?: 0).toByte(),
                    0,
                )
                result.success(null)
            }
            "text" -> {
                connection?.sendUtf8Text(call.argument<String>("text") ?: "")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        stop()
        val address = call.argument<String>("address")!!
        val cert = certificate(call.argument("cert"))
        val prefs = PreferenceConfiguration().apply {
            width = call.argument<Int>("width") ?: 1920
            height = call.argument<Int>("height") ?: 1080
            fps = call.argument<Int>("fps") ?: 60
            bitrate = call.argument<Int>("bitrate") ?: 20000
            videoFormat = when (call.argument<String>("codec")) {
                "h264" -> PreferenceConfiguration.FormatOption.FORCE_H264
                "hevc" -> PreferenceConfiguration.FormatOption.FORCE_HEVC
                "av1" -> PreferenceConfiguration.FormatOption.FORCE_AV1
                else -> PreferenceConfiguration.FormatOption.AUTO
            }
        }
        val texture = textures.createSurfaceProducer()
        texture.setSize(prefs.width, prefs.height)
        producer = texture
        val listener = Listener()
        val decoder = MediaCodecDecoderRenderer(
            activity,
            prefs,
            CrashListener { emit(mapOf("event" to "decoderCrashed", "message" to it.message)) },
            0,
            (activity.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).isActiveNetworkMetered,
            false,
            "",
            PerfOverlayListener { text -> emit(mapOf("event" to "stats", "text" to text)) },
        )
        decoder.setRenderTarget(TextureHolder(texture))
        this.decoder = decoder
        worker.execute {
            try {
                val http = http(address, cert)
                val details = http.getComputerDetails(true)
                // Sunshine's own desktop, else whatever it lists first.
                val apps = http.appList
                val app = apps.firstOrNull { it.appName.equals("Desktop", ignoreCase = true) }
                    ?: apps.firstOrNull()
                    ?: NvApp("Desktop")
                var formats = MoonBridge.VIDEO_FORMAT_H264
                if (decoder.isHevcSupported) formats = formats or MoonBridge.VIDEO_FORMAT_H265
                if (decoder.isAv1Supported) formats = formats or MoonBridge.VIDEO_FORMAT_AV1_MAIN8
                val config = StreamConfiguration.Builder()
                    .setResolution(prefs.width, prefs.height)
                    .setLaunchRefreshRate(prefs.fps)
                    .setRefreshRate(prefs.fps)
                    .setApp(app)
                    .setBitrate(prefs.bitrate)
                    .setEnableSops(false)
                    .enableLocalAudioPlayback(false)
                    // Tailscale's tunnel carries 1280-byte packets.
                    .setMaxPacketSize(1024)
                    .setRemoteConfiguration(StreamConfiguration.STREAM_CFG_AUTO)
                    .setSupportedVideoFormats(formats)
                    .setClientRefreshRateX100(prefs.fps * 100)
                    .setColorSpace(decoder.preferredColorSpace)
                    .setColorRange(decoder.preferredColorRange)
                    .build()
                val conn = NvConnection(
                    activity.applicationContext,
                    ComputerDetails.AddressTuple(address, HTTP_PORT),
                    details.httpsPort,
                    uniqueId(activity),
                    config,
                    crypto(),
                    cert,
                )
                connection = conn
                main.post {
                    result.success(mapOf("texture" to texture.id()))
                    conn.start(AndroidAudioRenderer(activity, false), decoder, listener)
                }
            } catch (error: Exception) {
                main.post {
                    stop()
                    result.error("moonlight", error.message ?: error.toString(), null)
                }
            }
        }
    }

    fun stop() {
        decoder?.prepareForStop()
        connection?.stop()
        connection = null
        decoder = null
        producer?.release()
        producer = null
    }

    private class Listener : NvConnectionListener {
        override fun stageStarting(stage: String) = emit(mapOf("event" to "stage", "stage" to stage))
        override fun stageComplete(stage: String) = Unit
        override fun stageFailed(stage: String, portFlags: Int, errorCode: Int) = emit(
            mapOf(
                "event" to "failed",
                "stage" to stage,
                "code" to errorCode,
                "ports" to MoonBridge.stringifyPortFlags(portFlags, ", "),
            ),
        )
        override fun connectionStarted() = emit(mapOf("event" to "started"))
        override fun connectionTerminated(errorCode: Int) =
            emit(mapOf("event" to "ended", "code" to errorCode))
        override fun connectionStatusUpdate(connectionStatus: Int) = emit(
            mapOf(
                "event" to "status",
                "poor" to (connectionStatus == MoonBridge.CONN_STATUS_POOR),
            ),
        )
        override fun displayMessage(message: String) = emit(mapOf("event" to "message", "text" to message))
        override fun displayTransientMessage(message: String) =
            emit(mapOf("event" to "message", "text" to message))
        override fun rumble(controllerNumber: Short, lowFreqMotor: Short, highFreqMotor: Short) = Unit
        override fun rumbleTriggers(controllerNumber: Short, leftTrigger: Short, rightTrigger: Short) = Unit
        override fun setHdrMode(enabled: Boolean, hdrMetadata: ByteArray?) = Unit
        override fun setMotionEventState(controllerNumber: Short, motionType: Byte, reportRateHz: Short) = Unit
        override fun setControllerLED(controllerNumber: Short, r: Byte, g: Byte, b: Byte) = Unit
    }

    /** The decoder draws into a Flutter texture; it only asks for the surface. */
    private class TextureHolder(private val texture: TextureRegistry.SurfaceProducer) : SurfaceHolder {
        override fun getSurface(): Surface = texture.surface
        override fun addCallback(callback: SurfaceHolder.Callback?) = Unit
        override fun removeCallback(callback: SurfaceHolder.Callback?) = Unit
        override fun isCreating() = false
        @Deprecated("Deprecated in Java")
        override fun setType(type: Int) = Unit
        override fun setFixedSize(width: Int, height: Int) = Unit
        override fun setSizeFromLayout() = Unit
        override fun setFormat(format: Int) = Unit
        override fun setKeepScreenOn(screenOn: Boolean) = Unit
        override fun lockCanvas() = null
        override fun lockCanvas(dirty: Rect?) = null
        override fun unlockCanvasAndPost(canvas: android.graphics.Canvas?) = Unit
        override fun getSurfaceFrame() = Rect()
    }
}
