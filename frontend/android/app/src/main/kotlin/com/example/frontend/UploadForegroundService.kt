package com.example.frontend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/// Pins the app's process at foreground priority while a Dart-side
/// encrypt+upload is in flight, so backgrounding the app doesn't freeze the
/// transfer. Deliberately does NOT perform any work itself — the upload
/// stays entirely in the Flutter isolate; this service is a priority anchor
/// plus a notification, nothing more. ACTION_UPDATE lets the Dart activity
/// center mirror live progress (title/text/determinate bar) into the pinned
/// notification.
class UploadForegroundService : Service() {

    companion object {
        const val ACTION_START = "com.example.frontend.upload_fg.START"
        const val ACTION_STOP = "com.example.frontend.upload_fg.STOP"
        const val ACTION_UPDATE = "com.example.frontend.upload_fg.UPDATE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_MAX = "max"
        const val EXTRA_INDETERMINATE = "indeterminate"
        private const val CHANNEL_ID = "upload_fg"
        private const val NOTIF_ID = 41
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startPinned()
            ACTION_UPDATE -> updatePinned(intent)
            ACTION_STOP -> stopPinned()
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startPinned() {
        pin(buildNotification("CipherNest", "Securing your file…", 0, 0, false))
    }

    // Re-calling startForeground both updates the notification AND satisfies
    // the startForegroundService contract; it also re-pins after an
    // onTimeout, which self-heals the Dart guard's stale ref (its eventual
    // end() still sends STOP).
    private fun updatePinned(intent: Intent) {
        pin(
            buildNotification(
                intent.getStringExtra(EXTRA_TITLE) ?: "CipherNest",
                intent.getStringExtra(EXTRA_TEXT) ?: "Securing your file…",
                intent.getIntExtra(EXTRA_PROGRESS, 0),
                intent.getIntExtra(EXTRA_MAX, 0),
                intent.getBooleanExtra(EXTRA_INDETERMINATE, false),
            )
        )
    }

    private fun pin(notification: Notification) {
        ensureChannel()
        ServiceCompat.startForeground(
            this,
            NOTIF_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        max: Int,
        indeterminate: Boolean,
    ): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_stat_ciphernest)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(launchIntent())
            .apply { if (max > 0 || indeterminate) setProgress(max, progress, indeterminate) }
            .build()

    // Tap opens the app. FLAG_IMMUTABLE is mandatory on API 31+.
    private fun launchIntent(): PendingIntent? {
        val launch = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun stopPinned() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Uploads",
                NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Shown while a file is being secured" }
        )
    }

    // Android 15+ enforces a runtime cap on dataSync services (~6h). An
    // upload that long is dead anyway — release the pin; the Dart side's
    // normal failure handling takes over. The Dart guard is deliberately
    // NOT told (a callback needs a live engine at hour ~6, not guaranteed):
    // a post-timeout end() sends STOP to a dead service (harmless no-op),
    // and a post-timeout UPDATE re-pins, after which the still-held ref's
    // end() cleanly stops the service again.
    override fun onTimeout(startId: Int) {
        stopPinned()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
