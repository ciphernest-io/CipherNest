package io.ciphernest.vault

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.documentfile.provider.DocumentFile
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

// AudioServiceFragmentActivity = FlutterFragmentActivity (BiometricPrompt
// requires a FragmentActivity) + the media-session plumbing background
// playback needs.
class MainActivity : AudioServiceFragmentActivity() {

    companion object {
        private const val TREE_REQUEST = 4821
        // Traversal guards — a pathological tree must not wedge the pick.
        private const val MAX_TREE_DEPTH = 8
        private const val MAX_TREE_FILES = 2000
    }

    // Pending Dart result for an in-flight ACTION_OPEN_DOCUMENT_TREE pick.
    private var treePickResult: MethodChannel.Result? = null

    // ---- OAuth return relay (ciphernest-open scheme, see manifest) ----

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Screenshots are allowed by default (2026-10-06 ruling). Only the
        // screens that display credentials block them, via secureWindow below.
        // Must be running before the task can be swiped away, otherwise there
        // is nothing in the task to receive onTaskRemoved.
        TaskExitService.start(this)
        relayOAuthReturn(intent)
    }

    /// Screenshots, screen recording and casting are ALLOWED by default.
    /// Users are trusted with their own gallery, matching what comparable
    /// vault apps do.
    ///
    /// FLAG_SECURE is instead applied per screen, by the screens that display
    /// a credential: the recovery phrase, "view phrase", phrase entry, and any
    /// share link or share password. A screenshot of one of those is a
    /// credential written to DCIM/Screenshots, where photo backup syncs it off
    /// the device. That is MASVS F-05 and it stays closed for those screens
    /// regardless of any user setting.
    ///
    /// NOTE: one flag governs screenshots, recording, casting AND the recents
    /// snapshot, so allowing screenshots necessarily lets the task switcher
    /// show the last screen again. That is the accepted trade of this ruling.
    ///
    /// Debuggable builds never carry the flag, so UI review still works.
    private fun setSecureWindow(on: Boolean) {
        val debuggable =
            (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable) return
        if (on) {
            window.setFlags(
                WindowManager.LayoutParams.FLAG_SECURE,
                WindowManager.LayoutParams.FLAG_SECURE,
            )
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun onNewIntent(intent: Intent) {
        // Relay BEFORE super: super.onNewIntent hands the intent to the
        // Flutter engine and, through it, to the app's lifecycle. The sign-in
        // plugin cancels any pending authenticate() the moment Dart sees
        // `resumed`, so the pending call must already be completed here.
        relayOAuthReturn(intent)
        super.onNewIntent(intent)
    }

    // The auth.ciphernest.io callback page's "Open CipherNest" button
    // targets THIS activity (scheme ciphernest-open) so the app task comes
    // forward. The code is delivered to the sign-in plugin IN-PROCESS: the
    // plugin keeps its pending authenticate() result keyed by callback
    // scheme in a companion map (the same map its own CallbackActivity
    // resolves), so completing it here is exactly what CallbackActivity
    // would do, minus a second task. The earlier design started
    // CallbackActivity in a disposable task; that worked but raced the
    // plugin's cancel-on-resume observer and pushed a stray route
    // (19 Sep 2026, MTR#2 D2). Pinned to flutter_web_auth_2 4.1.0; if the
    // plugin renames `callbacks`, this fails to compile, not at runtime.
    private fun relayOAuthReturn(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "ciphernest-open") return
        val rewritten = data.buildUpon().scheme("ciphernest").build()
        val pending = com.linusu.flutter_web_auth_2.FlutterWebAuth2Plugin
            .callbacks.remove("ciphernest") ?: return
        try {
            pending.success(rewritten.toString())
        } catch (_: Exception) {
            // Result already completed or the engine is gone; nothing to
            // recover. The user simply taps the provider again.
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ciphernest/secure_window",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "set" -> {
                    setSecureWindow(call.argument<Boolean>("on") ?: true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val vault = BiometricSeedVault(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ciphernest/biometric_seed",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "capability" -> result.success(vault.capability())
                "checkArmed" -> result.success(vault.checkArmed())
                "enable" -> {
                    val seed = call.argument<ByteArray>("seed")
                    if (seed == null || seed.size != 64) {
                        result.error("failed", "seed must be 64 bytes", null)
                    } else {
                        vault.enable(
                            seed,
                            call.argument<String>("title") ?: "CipherNest",
                            call.argument<String>("subtitle") ?: "",
                            call.argument<String>("negativeButton") ?: "Use password",
                            result,
                        )
                    }
                }
                "unlock" -> vault.unlock(
                    call.argument<String>("title") ?: "CipherNest",
                    call.argument<String>("subtitle") ?: "",
                    call.argument<String>("negativeButton") ?: "Use password",
                    result,
                )
                "disable" -> {
                    vault.disable()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        // General platform helpers: upload foreground-service pin +
        // battery-optimization visibility for background sync.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ciphernest/platform",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startUploadForeground" -> {
                    val intent = Intent(this, UploadForegroundService::class.java)
                        .setAction(UploadForegroundService.ACTION_START)
                    ContextCompat.startForegroundService(this, intent)
                    result.success(true)
                }
                "stopUploadForeground" -> {
                    val intent = Intent(this, UploadForegroundService::class.java)
                        .setAction(UploadForegroundService.ACTION_STOP)
                    startService(intent)
                    result.success(true)
                }
                "updateUploadForeground" -> {
                    // Best-effort mirror of live progress into the pinned
                    // notification. startForegroundService (not
                    // startService) — a plain startService throws from a
                    // backgrounded app, which is exactly when mirroring
                    // matters.
                    try {
                        val intent = Intent(this, UploadForegroundService::class.java)
                            .setAction(UploadForegroundService.ACTION_UPDATE)
                            .putExtra(
                                UploadForegroundService.EXTRA_TITLE,
                                call.argument<String>("title") ?: "CipherNest",
                            )
                            .putExtra(
                                UploadForegroundService.EXTRA_TEXT,
                                call.argument<String>("text") ?: "",
                            )
                            .putExtra(
                                UploadForegroundService.EXTRA_PROGRESS,
                                call.argument<Int>("progress") ?: 0,
                            )
                            .putExtra(
                                UploadForegroundService.EXTRA_MAX,
                                call.argument<Int>("max") ?: 0,
                            )
                            .putExtra(
                                UploadForegroundService.EXTRA_INDETERMINATE,
                                call.argument<Boolean>("indeterminate") ?: false,
                            )
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "openBatteryOptimizationSettings" -> {
                    // The list screen needs no permission (unlike the
                    // per-app REQUEST_IGNORE dialog, which is Play-policy
                    // sensitive).
                    try {
                        startActivity(
                            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(true)
                    } catch (e: Exception) {
                        // Fall back to the app's own details page.
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    Uri.parse("package:$packageName"),
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error("unavailable", e2.message, null)
                        }
                    }
                }
                "pickFolderTree" -> {
                    if (treePickResult != null) {
                        result.error("busy", "A folder pick is already in progress", null)
                    } else {
                        try {
                            treePickResult = result
                            startActivityForResult(
                                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE),
                                TREE_REQUEST,
                            )
                        } catch (e: Exception) {
                            // OEM without a documents UI — the Dart side
                            // falls back to multi-file selection.
                            treePickResult = null
                            result.error("unavailable", e.message, null)
                        }
                    }
                }
                "copyDocumentToCache" -> {
                    val uriStr = call.argument<String>("uri")
                    val name = call.argument<String>("name") ?: "file"
                    if (uriStr == null) {
                        result.error("bad_args", "uri required", null)
                    } else {
                        // Streams can be huge (videos) — never copy on the
                        // main thread.
                        Thread {
                            try {
                                val input = contentResolver
                                    .openInputStream(Uri.parse(uriStr))
                                    ?: throw java.io.IOException("open failed")
                                val dir = File(cacheDir, "saf_import")
                                    .apply { mkdirs() }
                                val safe = name.replace(Regex("[/\\\\]"), "_")
                                val out = File(
                                    dir,
                                    "${System.nanoTime()}_$safe",
                                )
                                input.use { i ->
                                    out.outputStream().use { o -> i.copyTo(o) }
                                }
                                runOnUiThread { result.success(out.absolutePath) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("copy_failed", e.message, null)
                                }
                            }
                        }.start()
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != TREE_REQUEST) return
        val res = treePickResult ?: return
        treePickResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            // User cancelled — null, not an error.
            res.success(null)
            return
        }
        // Enumeration hits the documents provider repeatedly — off the main
        // thread. Only FILE entries are returned; the Dart side derives the
        // folder structure from each entry's relative dir.
        Thread {
            try {
                val root = DocumentFile.fromTreeUri(this, uri)
                if (root == null || !root.isDirectory) {
                    runOnUiThread { res.success(null) }
                    return@Thread
                }
                val entries = ArrayList<Map<String, Any>>()
                fun walk(dir: DocumentFile, rel: String, depth: Int) {
                    if (depth > MAX_TREE_DEPTH || entries.size >= MAX_TREE_FILES) return
                    for (child in dir.listFiles()) {
                        if (entries.size >= MAX_TREE_FILES) return
                        val name = child.name ?: continue
                        if (child.isDirectory) {
                            walk(
                                child,
                                if (rel.isEmpty()) name else "$rel/$name",
                                depth + 1,
                            )
                        } else if (child.isFile) {
                            entries.add(
                                mapOf(
                                    "name" to name,
                                    "dir" to rel,
                                    "size" to child.length(),
                                    "uri" to child.uri.toString(),
                                ),
                            )
                        }
                    }
                }
                walk(root, "", 0)
                runOnUiThread {
                    res.success(
                        mapOf(
                            "name" to (root.name ?: "Imported folder"),
                            "entries" to entries,
                            "truncated" to (entries.size >= MAX_TREE_FILES),
                        ),
                    )
                }
            } catch (e: Exception) {
                runOnUiThread { res.error("tree_failed", e.message, null) }
            }
        }.start()
    }
}
