package com.example.frontend

import android.app.NotificationChannel
import android.app.NotificationManager
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
/// plus a notification, nothing more.
class UploadForegroundService : Service() {

    companion object {
        const val ACTION_START = "com.example.frontend.upload_fg.START"
        const val ACTION_STOP = "com.example.frontend.upload_fg.STOP"
        private const val CHANNEL_ID = "upload_fg"
        private const val NOTIF_ID = 41
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startPinned()
            ACTION_STOP -> stopPinned()
            else -> stopSelf()
        }
        return START_NOT_STICKY
    }

    private fun startPinned() {
        ensureChannel()
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("CipherNest")
            .setContentText("Securing your file…")
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        ServiceCompat.startForeground(
            this,
            NOTIF_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
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
    // normal failure handling takes over.
    override fun onTimeout(startId: Int) {
        stopPinned()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
