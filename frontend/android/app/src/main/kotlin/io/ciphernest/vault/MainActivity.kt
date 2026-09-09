package io.ciphernest.vault

import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
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
        relayOAuthReturn(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        relayOAuthReturn(intent)
    }

    // The worker page's "Open CipherNest" button targets THIS activity so
    // the app task comes forward; the URI (scheme rewritten back to
    // ciphernest) is then handed to the plugin's CallbackActivity, whose
    // completer finishes the sign-in. FLAG_ACTIVITY_NEW_TASK is
    // LOAD-BEARING: without it CallbackActivity joins OUR task and its
    // finishAndRemoveTask() destroys the whole app. With it (and the
    // affinity mismatch: ours is "", its is the package default) it gets a
    // disposable task that removes itself, revealing us in the foreground.
    private fun relayOAuthReturn(intent: Intent?) {
        val data = intent?.data ?: return
        if (data.scheme != "ciphernest-open") return
        val rewritten = data.buildUpon().scheme("ciphernest").build()
        try {
            startActivity(
                Intent(
                    this,
                    com.linusu.flutter_web_auth_2.CallbackActivity::class.java,
                )
                    .setData(rewritten)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Exception) {
            // Best effort: worst case matches the old behavior (the user
            // returns to the app manually and sign-in completes there).
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
