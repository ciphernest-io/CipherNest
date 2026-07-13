package com.example.frontend

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
    }
}
