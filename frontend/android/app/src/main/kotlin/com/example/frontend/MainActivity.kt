package com.example.frontend

import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceFragmentActivity = FlutterFragmentActivity (BiometricPrompt
// requires a FragmentActivity) + the media-session plumbing background
// playback needs.
class MainActivity : AudioServiceFragmentActivity() {

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
                else -> result.notImplemented()
            }
        }
    }
}
