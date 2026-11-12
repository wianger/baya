package dev.wianger.baya

import android.app.Activity
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * The ways into the app from the rest of the phone: text shared from
 * another app, and the launcher icon's shortcuts to recent sessions.
 */
object Launcher {
    private const val MAX_SHARED = 20_000

    private var channel: MethodChannel? = null

    /** Text shared into the app before Dart was ready to take it. */
    private var launchText: String? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        launchText = sharedText(activity.intent)
        channel = MethodChannel(messenger, "dev.wianger.baya/launcher").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchText" -> {
                        val text = launchText
                        launchText = null
                        result.success(text)
                    }
                    "shortcuts" -> {
                        setShortcuts(activity, call.arguments as? List<*> ?: emptyList<Any>())
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    /** Text shared while the app was running. */
    fun received(intent: Intent) {
        sharedText(intent)?.let { channel?.invokeMethod("shared", it) }
    }

    private fun sharedText(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) return null
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.trim()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.trim()
        val whole = when {
            text.isNullOrEmpty() -> subject
            subject.isNullOrEmpty() || text.contains(subject) -> text
            else -> "$subject\n\n$text"
        }
        // Handled: a configuration change must not share it again.
        intent.action = Intent.ACTION_MAIN
        return whole?.takeIf { it.isNotEmpty() }?.take(MAX_SHARED)
    }

    /** The launcher icon's long-press menu: the sessions used last. */
    private fun setShortcuts(activity: Activity, sessions: List<*>) {
        val manager = activity.getSystemService(ShortcutManager::class.java) ?: return
        val limit = manager.maxShortcutCountPerActivity.coerceAtMost(4)
        val icon = Icon.createWithResource(activity, R.drawable.ic_shortcut_session)
        val shortcuts = sessions.mapNotNull { it as? Map<*, *> }.take(limit).mapIndexedNotNull { rank, session ->
            val host = session["host"] as? String ?: return@mapIndexedNotNull null
            val id = session["session"] as? String ?: return@mapIndexedNotNull null
            val title = (session["title"] as? String)?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
            val intent = Intent(activity, MainActivity::class.java)
                .setAction(Intent.ACTION_VIEW)
                .putExtra(Agents.EXTRA_HOST, host)
                .putExtra(Agents.EXTRA_SESSION, id)
            ShortcutInfo.Builder(activity, "session:$host:$id".take(64))
                .setShortLabel(title.take(24))
                .setLongLabel((session["subtitle"] as? String)?.let { "$title · $it" }?.take(48) ?: title.take(48))
                .setIcon(icon)
                .setRank(rank)
                .setIntent(intent)
                .build()
        }
        try {
            manager.dynamicShortcuts = shortcuts
        } catch (error: IllegalStateException) {
            // Rate limited while in the background; the next change sets them.
        }
    }
}
