package dev.wianger.baya

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Agents at work in the notification shade and, on Android 16, as a Live
 * Update in the status bar. Dart decides what to show; this only shows it,
 * keeps the app running (and its connections up) while an agent works, and
 * hands taps back.
 */
object Agents {
    private const val LIVE_CHANNEL = "agents_live"
    private const val ALERT_CHANNEL = "agents_alerts"
    const val LIVE_ID = 1
    private const val ALERT_ID = 2
    private const val LIVE_TAG = "live"
    private const val EXTRA_HOST = "dev.wianger.baya.host"
    private const val EXTRA_SESSION = "dev.wianger.baya.session"
    const val EXTRA_PAYLOAD = "dev.wianger.baya.payload"
    const val EXTRA_TAG = "dev.wianger.baya.tag"
    private const val ASKED = "asked_notifications"
    private const val ACCENT = 0xFFE0A93B.toInt()

    private var channel: MethodChannel? = null

    /** What the live notification shows now; null when nothing is at work. */
    @Volatile
    var live: Map<*, *>? = null
        private set

    /** The service holds the live notification in the foreground. */
    @Volatile
    var serviceRunning = false

    /** The session a tapped notification opened the app on, until Dart asks. */
    private var launch: Map<String, String>? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        createChannels(activity)
        launch = sessionOf(activity.intent)
        val context = activity.applicationContext
        channel = MethodChannel(messenger, "dev.wianger.baya/agents").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "live" -> showLive(context, call.arguments as? Map<*, *>)
                    "alert" -> (call.arguments as? Map<*, *>)?.let { alert(context, it) }
                    "cancel" -> (call.arguments as? String)?.let { cancel(context, it) }
                    "ask" -> ask(activity, call.argument<Boolean>("settings") == true)
                    "allowed" -> return@setMethodCallHandler result.success(
                        manager(context).areNotificationsEnabled()
                    )
                    "launch" -> {
                        val session = launch
                        launch = null
                        return@setMethodCallHandler result.success(session)
                    }
                    else -> return@setMethodCallHandler result.notImplemented()
                }
                result.success(null)
            }
        }
    }

    /** The app is closing for good: nothing is left to keep these current. */
    fun detach(context: Context) {
        channel?.setMethodCallHandler(null)
        channel = null
        showLive(context.applicationContext, null)
        manager(context).cancelAll()
    }

    /** A notification was tapped while the app was running. */
    fun opened(intent: Intent) {
        sessionOf(intent)?.let { channel?.invokeMethod("open", it) }
    }

    fun action(payload: String) {
        channel?.invokeMethod("action", mapOf("payload" to payload))
    }

    private fun sessionOf(intent: Intent?): Map<String, String>? {
        val host = intent?.getStringExtra(EXTRA_HOST) ?: return null
        val session = intent.getStringExtra(EXTRA_SESSION) ?: return null
        return mapOf("host" to host, "session" to session)
    }

    private fun manager(context: Context) =
        context.getSystemService(NotificationManager::class.java)

    private fun createChannels(context: Context) {
        manager(context).createNotificationChannels(
            listOf(
                NotificationChannel(
                    LIVE_CHANNEL,
                    context.getString(R.string.agents_live_channel),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = context.getString(R.string.agents_live_channel_about)
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                },
                NotificationChannel(
                    ALERT_CHANNEL,
                    context.getString(R.string.agents_alert_channel),
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = context.getString(R.string.agents_alert_channel_about)
                },
            )
        )
    }

    /** Asks for the notification permission; once, unless [settings]. */
    private fun ask(activity: Activity, settings: Boolean) {
        if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            if (settings && !manager(activity).areNotificationsEnabled()) openSettings(activity)
            return
        }
        val prefs = activity.getSharedPreferences("baya", Context.MODE_PRIVATE)
        val asked = prefs.getBoolean(ASKED, false)
        if (!asked || activity.shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            prefs.edit().putBoolean(ASKED, true).apply()
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7)
        } else if (settings) {
            openSettings(activity)
        }
    }

    private fun openSettings(activity: Activity) {
        activity.startActivity(
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        )
    }

    private fun showLive(context: Context, content: Map<*, *>?) {
        live = content
        if (content == null) {
            if (serviceRunning) {
                serviceRunning = false
                context.stopService(Intent(context, AgentService::class.java))
            }
            manager(context).cancel(LIVE_ID)
            return
        }
        if (serviceRunning) {
            manager(context).notify(LIVE_ID, buildLive(context, content))
            return
        }
        try {
            context.startForegroundService(Intent(context, AgentService::class.java))
        } catch (error: IllegalStateException) {
            // Not allowed from the background: show it all the same, without
            // keeping the app running.
            manager(context).notify(LIVE_ID, buildLive(context, content))
        }
    }

    fun buildLive(context: Context, content: Map<*, *>): Notification {
        val text = content["text"] as? String ?: ""
        val since = (content["since"] as? Number)?.toLong() ?: 0L
        val builder = Notification.Builder(context, LIVE_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_baya)
            .setColor(ACCENT)
            .setContentTitle(content["title"] as? String ?: "")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(
                openIntent(context, content["host"] as? String, content["session"] as? String, LIVE_TAG)
            )
        if (since > 0) builder.setWhen(since).setShowWhen(true).setUsesChronometer(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            // A Live Update: a chip in the status bar, on the lock screen and
            // at the top of the shade, counting up the turn or saying what
            // the agent waits for.
            // Notification.EXTRA_REQUEST_PROMOTED_ONGOING, as NotificationCompat
            // sets it: the platform builder has no setter for it.
            builder.addExtras(Bundle().apply { putBoolean("android.requestPromotedOngoing", true) })
            (content["chip"] as? String)?.let { builder.setShortCriticalText(it) }
            if (content["busy"] == true) {
                builder.setStyle(Notification.ProgressStyle().setProgressIndeterminate(true))
            } else {
                builder.setStyle(Notification.BigTextStyle().bigText(text))
            }
        } else {
            builder.setStyle(Notification.BigTextStyle().bigText(text))
        }
        addActions(context, builder, content["actions"], LIVE_TAG)
        return builder.build()
    }

    private fun alert(context: Context, content: Map<*, *>) {
        val tag = content["id"] as? String ?: return
        val text = content["text"] as? String ?: ""
        val builder = Notification.Builder(context, ALERT_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_baya)
            .setColor(ACCENT)
            .setContentTitle(content["title"] as? String ?: "")
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setAutoCancel(true)
            .setCategory(
                if (tag.startsWith("ask:")) Notification.CATEGORY_REMINDER
                else Notification.CATEGORY_STATUS
            )
            .setContentIntent(
                openIntent(context, content["host"] as? String, content["session"] as? String, tag)
            )
        addActions(context, builder, content["actions"], tag)
        manager(context).notify(tag, ALERT_ID, builder.build())
    }

    fun cancel(context: Context, tag: String) {
        if (tag == LIVE_TAG) return
        manager(context).cancel(tag, ALERT_ID)
    }

    private fun openIntent(context: Context, host: String?, session: String?, tag: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra(EXTRA_HOST, host)
            .putExtra(EXTRA_SESSION, session)
        return PendingIntent.getActivity(
            context,
            tag.hashCode(),
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun addActions(context: Context, builder: Notification.Builder, raw: Any?, tag: String) {
        (raw as? List<*>)?.forEachIndexed { index, item ->
            val action = item as? Map<*, *> ?: return@forEachIndexed
            val intent = Intent(context, AgentActionReceiver::class.java)
                .putExtra(EXTRA_PAYLOAD, action["payload"] as? String)
                .putExtra(EXTRA_TAG, tag)
            val pending = PendingIntent.getBroadcast(
                context,
                "$tag#$index".hashCode(),
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(
                Notification.Action.Builder(null as Icon?, action["label"] as? String ?: "", pending).build()
            )
        }
    }
}

/** Keeps the app, and its connections to the computers, up while agents work. */
class AgentService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val content = Agents.live
        try {
            startForeground(
                Agents.LIVE_ID,
                Agents.buildLive(this, content ?: emptyMap<String, Any>()),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } catch (error: RuntimeException) {
            stopSelf()
            return START_NOT_STICKY
        }
        Agents.serviceRunning = true
        // Everything finished before the service got going.
        if (content == null) {
            Agents.serviceRunning = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Agents.serviceRunning = false
        super.onDestroy()
    }
}

/** A button on a notification: answered here, acted on by Dart. */
class AgentActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val payload = intent.getStringExtra(Agents.EXTRA_PAYLOAD) ?: return
        intent.getStringExtra(Agents.EXTRA_TAG)?.let { Agents.cancel(context, it) }
        Agents.action(payload)
    }
}
