package com.example.frontend

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Hardware-enforced biometric wrap of the vault seed.
 *
 * The 64-byte seed is AES-256-GCM encrypted under a key that lives inside
 * AndroidKeyStore with setUserAuthenticationRequired(true) — auth-per-use, so
 * BOTH the encrypt at arm time and the decrypt at unlock time are only
 * possible through a BiometricPrompt.CryptoObject with a fresh BIOMETRIC_STRONG
 * authentication. The TEE (or StrongBox when present) enforces this; nothing
 * app-side can bypass it. The wrapped blob never leaves this class — Dart only
 * ever sees the raw seed, once per arm/unlock.
 *
 * Enrollment changes (fingerprint added/removed, PIN changed, lock screen
 * removed) permanently destroy the key by design; every entry point maps that
 * to a single 'invalidated' outcome the Dart side turns into wipe-and-message.
 */
class BiometricSeedVault(private val activity: FragmentActivity) {

    companion object {
        private const val KEY_ALIAS = "ciphernest_bio_seed_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val PREFS_FILE = "ciphernest_bio"
        private const val PREF_BLOB = "blob"
        private const val PREF_IV = "iv"
        private const val PREF_BACKING = "backing"
        private const val CIPHER = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }

    private val prefs
        get() = activity.getSharedPreferences(PREFS_FILE, Context.MODE_PRIVATE)

    // ------------------------------------------------------------------
    // Probes (synchronous, no prompt, no side effects)
    // ------------------------------------------------------------------

    /** noLockScreen | noHardware | noneEnrolled | unavailable | available */
    fun capability(): String {
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure) return "noLockScreen"
        return when (BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> "available"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "noHardware"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "noneEnrolled"
            else -> "unavailable" // HW busy, security update required, unknown
        }
    }

    /**
     * armed | missing | invalidated. Initializes a decrypt cipher (the only
     * reliable invalidation probe) but never prompts and never wipes — the
     * wipe policy lives in one place, on the Dart side.
     */
    fun checkArmed(): String {
        val iv = prefs.getString(PREF_IV, null)
        val blob = prefs.getString(PREF_BLOB, null)
        if (iv == null || blob == null) return "missing"
        val key = loadKey() ?: return "invalidated" // blob without key: OEM deleted it
        return try {
            Cipher.getInstance(CIPHER).init(
                Cipher.DECRYPT_MODE, key,
                GCMParameterSpec(GCM_TAG_BITS, Base64.decode(iv, Base64.NO_WRAP)),
            )
            "armed"
        } catch (e: KeyPermanentlyInvalidatedException) {
            "invalidated"
        } catch (e: Exception) {
            "invalidated" // any other abnormality funnels to the same recovery path
        }
    }

    // ------------------------------------------------------------------
    // Arm (encrypt seed) — prompts
    // ------------------------------------------------------------------

    fun enable(
        seed: ByteArray,
        title: String,
        subtitle: String,
        negativeButton: String,
        result: MethodChannel.Result,
    ) {
        val cipher: Cipher
        try {
            // Always start from a fresh key: a stale invalidated key under the
            // same alias would throw at init, and an old key must never outlive
            // a re-arm anyway.
            deleteKey()
            val (key, backing) = generateKey()
            cipher = Cipher.getInstance(CIPHER)
            // Keystore generates the GCM IV (randomized encryption is required
            // for Keystore AES keys — supplying our own IV throws). Read
            // cipher.iv after init and persist it beside the ciphertext.
            cipher.init(Cipher.ENCRYPT_MODE, key)
            prefs.edit().putString(PREF_BACKING, backing).apply()
        } catch (e: Exception) {
            deleteKey()
            result.error("failed", "Keystore key generation failed: ${e.message}", null)
            return
        }

        prompt(title, subtitle, negativeButton, cipher,
            onSuccess = { authedCipher ->
                try {
                    val sealed = authedCipher.doFinal(seed)
                    seed.fill(0) // best effort; JVM heap caveat documented
                    prefs.edit()
                        .putString(PREF_BLOB, Base64.encodeToString(sealed, Base64.NO_WRAP))
                        .putString(PREF_IV, Base64.encodeToString(authedCipher.iv, Base64.NO_WRAP))
                        .apply()
                    result.success(true)
                } catch (e: Exception) {
                    deleteKey()
                    clearBlob()
                    result.error("failed", "Seal failed: ${e.message}", null)
                }
            },
            onError = { code, message ->
                // No orphaned armed key without a blob.
                deleteKey()
                clearBlob()
                result.error(code, message, null)
            })
    }

    // ------------------------------------------------------------------
    // Unlock (decrypt seed) — prompts
    // ------------------------------------------------------------------

    fun unlock(
        title: String,
        subtitle: String,
        negativeButton: String,
        result: MethodChannel.Result,
    ) {
        val ivB64 = prefs.getString(PREF_IV, null)
        val blobB64 = prefs.getString(PREF_BLOB, null)
        if (ivB64 == null || blobB64 == null) {
            result.error("keyMissing", "No biometric wrap present", null)
            return
        }
        val key = loadKey()
        if (key == null) {
            // Some OEMs delete the key on lock-screen changes instead of
            // invalidating it — same user story, same recovery path.
            result.error("keyMissing", "Keystore key gone", null)
            return
        }
        val cipher: Cipher
        try {
            cipher = Cipher.getInstance(CIPHER)
            cipher.init(
                Cipher.DECRYPT_MODE, key,
                GCMParameterSpec(GCM_TAG_BITS, Base64.decode(ivB64, Base64.NO_WRAP)),
            )
        } catch (e: KeyPermanentlyInvalidatedException) {
            result.error("invalidated", "Device security settings changed", null)
            return
        } catch (e: Exception) {
            result.error("failed", "Cipher init failed: ${e.message}", null)
            return
        }

        prompt(title, subtitle, negativeButton, cipher,
            onSuccess = { authedCipher ->
                try {
                    val seed = authedCipher.doFinal(Base64.decode(blobB64, Base64.NO_WRAP))
                    result.success(seed)
                } catch (e: Exception) {
                    result.error("failed", "Unseal failed: ${e.message}", null)
                }
            },
            onError = { code, message -> result.error(code, message, null) })
    }

    // ------------------------------------------------------------------
    // Teardown — idempotent, never prompts
    // ------------------------------------------------------------------

    fun disable() {
        deleteKey()
        clearBlob()
    }

    // ------------------------------------------------------------------
    // BiometricPrompt plumbing
    // ------------------------------------------------------------------

    private fun prompt(
        title: String,
        subtitle: String,
        negativeButton: String,
        cipher: Cipher,
        onSuccess: (Cipher) -> Unit,
        onError: (code: String, message: String) -> Unit,
    ) {
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText(negativeButton)
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .build()
        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    result: BiometricPrompt.AuthenticationResult,
                ) {
                    val c = result.cryptoObject?.cipher
                    if (c == null) onError("failed", "No authenticated cipher")
                    else onSuccess(c)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    onError(mapPromptError(errorCode), errString.toString())
                }
                // onAuthenticationFailed (a single unrecognized finger) is
                // deliberately not terminal — the prompt keeps listening.
            },
        )
        prompt.authenticate(info, BiometricPrompt.CryptoObject(cipher))
    }

    private fun mapPromptError(code: Int): String = when (code) {
        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
        BiometricPrompt.ERROR_USER_CANCELED,
        BiometricPrompt.ERROR_CANCELED,
        -> "userCanceled"
        BiometricPrompt.ERROR_LOCKOUT -> "lockout"
        BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "lockoutPermanent"
        BiometricPrompt.ERROR_NO_BIOMETRICS -> "noneEnrolled"
        BiometricPrompt.ERROR_NO_DEVICE_CREDENTIAL -> "noLockScreen"
        else -> "failed"
    }

    // ------------------------------------------------------------------
    // Keystore plumbing
    // ------------------------------------------------------------------

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun loadKey(): SecretKey? = try {
        keyStore().getKey(KEY_ALIAS, null) as? SecretKey
    } catch (e: Exception) {
        null
    }

    private fun deleteKey() {
        try {
            keyStore().deleteEntry(KEY_ALIAS)
        } catch (e: Exception) {
            // Missing entry or Keystore hiccup — teardown must never throw.
        }
    }

    private fun clearBlob() {
        prefs.edit().remove(PREF_BLOB).remove(PREF_IV).remove(PREF_BACKING).apply()
    }

    /** Returns the key and which hardware backs it ("strongbox" | "tee"). */
    private fun generateKey(): Pair<SecretKey, String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return generateKeyApi28()
        return Pair(generateKeyWithSpec(baseSpec().build()), "tee")
    }

    // StrongBox types are API 28+; keep every reference inside this method so
    // older verifiers never see the class.
    private fun generateKeyApi28(): Pair<SecretKey, String> {
        return try {
            val spec = baseSpec()
                .setUnlockedDeviceRequired(true)
                .setIsStrongBoxBacked(true)
                .build()
            Pair(generateKeyWithSpec(spec), "strongbox")
        } catch (e: android.security.keystore.StrongBoxUnavailableException) {
            val spec = baseSpec()
                .setUnlockedDeviceRequired(true)
                .build()
            Pair(generateKeyWithSpec(spec), "tee")
        }
    }

    private fun baseSpec(): KeyGenParameterSpec.Builder {
        val b = KeyGenParameterSpec.Builder(
            KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Auth-per-use, biometric class 3 only. The key is unusable outside
            // a BiometricPrompt.CryptoObject authentication.
            b.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            // Legacy equivalent of auth-per-use on API 24-29.
            @Suppress("DEPRECATION")
            b.setUserAuthenticationValidityDurationSeconds(-1)
        }
        return b
    }

    private fun generateKeyWithSpec(spec: KeyGenParameterSpec): SecretKey {
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        kg.init(spec)
        return kg.generateKey()
    }
}
