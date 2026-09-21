package io.ciphernest.vault

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.Process

/**
 * Turns "swipe the app out of recents" into a real close.
 *
 * Why this exists. The vault key lives in the Dart heap, and it is cleared by
 * AppLockService when the vault locks or by process death. Neither happened
 * on a swipe-away: the media foreground service (audio_service) keeps the
 * process alive whenever a track is loaded, even paused, so the app was
 * swiped from recents, its process survived, and reopening it landed straight
 * back in an unlocked vault with the media notification still sitting in the
 * shade. To the user that is indistinguishable from the app ignoring a hard
 * close (MASVS finding F-34, reported from the field).
 *
 * This service holds no state and does no work. It exists only to receive
 * [onTaskRemoved], which Android delivers to services in a task when that
 * task is swiped away. Killing the process there is the whole point: it is
 * the only way to guarantee the key is gone, because anything softer leaves
 * the decision to a runtime that may already be tearing down.
 *
 * Opt-out. If the user has turned on "keep playing after closing", playback
 * is the explicitly requested behaviour and the process is left alone. That
 * flag is written by the Dart settings screen into Flutter's own preferences
 * file, which is why the key carries the `flutter.` prefix.
 */
class TaskExitService : Service() {

    companion object {
        private const val FLUTTER_PREFS = "FlutterSharedPreferences"

        /** Must match kKeepPlayingOnClose in lib/services/gallery_prefs.dart. */
        private const val KEY_KEEP_PLAYING = "flutter.keep_playing_on_close_v1"

        fun start(context: Context) {
            try {
                context.startService(Intent(context, TaskExitService::class.java))
            } catch (_: Exception) {
                // Backgrounded start restrictions. Not fatal: the worst case is
                // that a swipe-away behaves the way it did before this existed.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // START_STICKY would have Android restart us after the kill, resurrecting
    // the very process we just removed. Not sticky, deliberately.
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)

        val keepPlaying = try {
            getSharedPreferences(FLUTTER_PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_KEEP_PLAYING, false)
        } catch (_: Exception) {
            false
        }
        if (keepPlaying) return

        // Drop the media notification with the process. Stopping the audio
        // service first means the shade is clean even if the kill is slower
        // than the system's own teardown.
        try {
            stopService(Intent(this, UploadForegroundService::class.java))
        } catch (_: Exception) {
        }
        stopSelf()
        Process.killProcess(Process.myPid())
    }
}
