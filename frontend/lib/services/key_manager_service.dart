import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'biometric_unlock_service.dart';
import 'secure_storage_options.dart';

/// Key management for CipherNest's split-key architecture.
///
/// ## One root secret
/// The BIP-39 seed (64 bytes) is the single root. Everything derives from it
/// by HKDF-SHA256 with frozen, domain-separated info strings:
///
///   * `ciphernest/x25519/v1` → the vault's long-term **X25519 keypair**.
///     Files are sealed to the public half via HPKE ([Hpke]); the private
///     half is required only to open (decrypt).
///   * `ciphernest/local/v1`  → `k_local`, which encrypts on-device
///     secrets (currently the pending-mnemonic crash-recovery blob).
///
/// The info strings are load-bearing forever: once a real vault exists, a
/// typo here would permanently orphan it. A frozen-mnemonic test
/// (test/crypto/key_derivation_test.dart) pins them.
///
/// ## Encrypt while locked
/// The public key lives in Keystore-wrapped secure storage and is loaded
/// even when the vault is locked, so background sync can encrypt and upload
/// with **no secret key material in memory**. Its confidentiality is
/// irrelevant but its integrity is critical: on every real unlock we
/// re-derive it from the seed and byte-compare against the stored value —
/// a mismatch means someone swapped the key and we refuse to proceed.
///
/// ## Lock is real
/// [lock] zeroes the private key and `k_local`; only [unlock] (password →
/// Argon2id → seed) or [unlockWithBiometric] brings them back. There is no
/// silent path to the private key — the biometric-shaped bypass the old build
/// shipped is gone.
///
/// ## Biometric unlock is a second wrap, not a second root
/// The same 64-byte seed carries a second wrap: AES-256-GCM under an
/// AndroidKeyStore key with setUserAuthenticationRequired(true), usable only
/// through a BiometricPrompt.CryptoObject (TEE/StrongBox-enforced, see
/// BiometricSeedVault.kt). Both unlock paths converge on the identical
/// derive-and-verify sequence, so the anti-tamper public-key check applies
/// equally. The password wrap remains the sole root of trust: enrollment
/// changes destroy the Keystore key by design (anti-tamper), and recovery is
/// always "type your password, re-arm if you like".
///
/// Threat-model note: during arm/unlock the seed transits the platform
/// channel and is briefly resident in both the Dart and JVM heaps. Neither
/// runtime supports reliable zeroization (we overwrite our copies anyway).
/// This is the same exposure class as the password path — one more transit
/// of an already-transiting secret, not a new class of exposure.
class KeyManagerService {
  static final KeyManagerService _instance = KeyManagerService._internal();
  factory KeyManagerService() => _instance;
  KeyManagerService._internal();

  // --- Frozen derivation labels. NEVER change these. ---
  static const String infoX25519 = 'ciphernest/x25519/v1';
  static const String infoLocal = 'ciphernest/local/v1';
  /// RevenueCat App User ID material. Frozen forever from the moment the
  /// first purchase is bound to it: changing this string derives a different
  /// ID, which orphans that subscription permanently, and there is no
  /// server-side record we control to repair it with.
  static const String infoBilling = 'ciphernest/billing/v1';

  // --- Secure storage (Keystore-wrapped). ---
  static const _kVaultPub = 'vault_pub_v1';

  // --- Passwordless vault (no app password chosen at setup). ---
  // The seed and mnemonic live in FlutterSecureStorage, which on Android is
  // EncryptedSharedPreferences under an AndroidKeyStore master key: hardware
  // backed, non-exportable, and readable by this app with NO user
  // authentication. That is exactly the intended posture — "anyone holding the
  // unlocked phone has the vault" — while a dump of the flash still yields
  // nothing, because the key cannot leave the Keystore.
  //
  // Deliberately NOT the biometric key: that one carries
  // setUserAuthenticationRequired(true) and dies on enrollment changes, which
  // would turn "I added a fingerprint" into total vault loss for a user who
  // never chose a password. This key survives enrollment changes and is
  // destroyed only by uninstall or clear-data.
  static const _kSeedNoAuth = 'seed_noauth_v1';
  static const _kMnemonicNoAuth = 'mnemonic_noauth_v1';
  // Mode flag. Absent reads as password mode, so every existing install
  // migrates as a no-op.
  static const _kPasswordless = 'passwordless_v1';

  // --- Password-wrapped seed blob (SharedPreferences). ---
  static const _kSeedBlob = 'seed_blob_v1';
  static const _kSeedNonce = 'seed_blob_nonce_v1';
  static const _kSeedMac = 'seed_blob_mac_v1';
  static const _kSeedSalt = 'seed_blob_salt_v1';

  // --- Password-wrapped mnemonic blob (SharedPreferences). ---
  // Persistent (unlike the k_local crash-recovery blob below, which is wiped
  // after signup). Lets Settings › "View recovery phrase" reveal the words
  // after a password re-prompt. Storing the phrase adds no capability a
  // password holder lacks — the password already unwraps the seed, which IS
  // full vault access. Only present on vaults created/restored after this
  // shipped.
  static const _kMnemonicPwBlob = 'mnemonic_pw_blob_v1';
  static const _kMnemonicPwNonce = 'mnemonic_pw_nonce_v1';
  static const _kMnemonicPwMac = 'mnemonic_pw_mac_v1';
  static const _kMnemonicPwSalt = 'mnemonic_pw_salt_v1';

  // --- Unlock throttle (SharedPreferences). ---
  // Argon2id at 64 MiB already makes a guess cost a second or so of device
  // time, but nothing stopped an unlimited run of guesses from the lock
  // screen. After [_kMaxFreeFailures] wrong passwords each further failure
  // doubles a persisted wait, so a kill-and-relaunch does not reset it
  // (MASVS F-15).
  static const _kUnlockFailures = 'unlock_failures_v1';
  static const _kUnlockLockedUntil = 'unlock_locked_until_v1';
  static const int _kMaxFreeFailures = 5;
  static const Duration _kFirstLockout = Duration(seconds: 30);
  static const Duration _kMaxLockout = Duration(minutes: 15);

  // --- Crash-recovery: mnemonic encrypted under k_local. ---
  static const _kSignupInProgress = 'signup_in_progress_v1';
  static const _kRecoveryShown = 'recovery_shown_v1';
  static const _kEncryptedMnemonic = 'encrypted_mnemonic';
  static const _kEncryptedMnemonicNonce = 'encrypted_mnemonic_nonce';
  static const _kEncryptedMnemonicMac = 'encrypted_mnemonic_mac';

  final _storage = kSecureStorage;
  final _argon2 = Argon2id(
    parallelism: 1,
    memory: 65536, // 64 MB
    iterations: 2,
    hashLength: 32,
  );

  /// The vault's full X25519 keypair. Present only while unlocked — this is
  /// the decrypt capability.
  SimpleKeyPair? _vaultKeyPair;

  /// The vault's X25519 public key. Present whenever we can encrypt —
  /// including a locked background isolate.
  SimplePublicKey? _vaultPublicKey;

  /// Local secret for on-device blobs. Present only while unlocked.
  SecretKey? _kLocal;

  /// Raw billing-ID material. Present only while unlocked, like the private
  /// key — the seed is never retained, so this cannot be recomputed later.
  Uint8List? _billingIdBytes;

  /// The RevenueCat App User ID, or null while the vault is locked.
  ///
  /// base64url without padding: 43 characters from `A-Za-z0-9-_`, which
  /// RevenueCat accepts and which can never be mistaken for an email
  /// address. One-way — this is HKDF output, not the seed.
  String? get billingId => _billingIdBytes == null
      ? null
      : base64Url.encode(_billingIdBytes!).replaceAll('=', '');

  /// True when the private key is in memory (decryption is possible).
  bool get isUnlocked => _vaultKeyPair != null;

  /// True when the public key is available (encryption is possible), whether
  /// or not the vault is unlocked.
  bool get canEncrypt => _vaultPublicKey != null;

  /// The vault keypair for opening (decrypting) file keys. Throws if locked.
  SimpleKeyPair get vaultKeyPair {
    final kp = _vaultKeyPair;
    if (kp == null) throw StateError('Vault is locked.');
    return kp;
  }

  /// The vault public key for sealing (encrypting) file keys. Throws if not
  /// yet loaded (call [unlock], [loadPublicKeyForEncrypt], or create/recover).
  SimplePublicKey get vaultPublicKey {
    final pk = _vaultPublicKey;
    if (pk == null) throw StateError('Vault public key not loaded.');
    return pk;
  }

  Future<bool> hasAccount() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_kSeedBlob)) return true;
    // A passwordless vault never writes the password-wrapped blob.
    return prefs.getBool(_kPasswordless) ?? false;
  }

  /// True when the vault was created with "Continue without password".
  /// Drives both the unlock route and whether biometric unlock is offered
  /// at all: there is no password to fall back to, so arming a key that
  /// dies on enrollment change would be a trap.
  Future<bool> isPasswordless() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPasswordless) ?? false;
  }

  // ---------------------------------------------------------------------------
  // Account creation / recovery
  // ---------------------------------------------------------------------------

  /// Generates a new vault from a fresh 12-word mnemonic. Returns the
  /// mnemonic so the user can write it down. Persists the encrypted seed
  /// (password-wrapped), the public key, and a crash-recovery mnemonic blob.
  Future<String> createAccount(String password) async {
    final mnemonic = bip39.generateMnemonic();
    final seed = bip39.mnemonicToSeed(mnemonic); // 64 bytes
    await _installSeed(seed, password);
    await _encryptAndSaveMnemonicBlob(mnemonic);
    await _encryptAndSaveMnemonicPwBlob(password, mnemonic);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSignupInProgress, true);
    await prefs.setBool(_kRecoveryShown, false);
    _signupPassword = password;
    _signupPasswordless = false;
    return mnemonic;
  }

  /// Generates a new vault with NO app password. The seed is held only by the
  /// Keystore-backed secure store, so the app can open it unattended. The
  /// mnemonic is kept beside it so Settings can still reveal the phrase.
  ///
  /// The recovery phrase remains the sole root of trust, exactly as in
  /// password mode. Nothing about restore, a second device or the billing
  /// identity changes.
  Future<String> createAccountWithoutPassword() async {
    final mnemonic = bip39.generateMnemonic();
    final seed = bip39.mnemonicToSeed(mnemonic); // 64 bytes
    await _installSeedNoPassword(seed, mnemonic);
    await _encryptAndSaveMnemonicBlob(mnemonic);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSignupInProgress, true);
    await prefs.setBool(_kRecoveryShown, false);
    _signupPasswordless = true;
    return mnemonic;
  }

  /// Derives the vault keys from [seed] and parks the seed in secure storage
  /// instead of password-wrapping it. Writes the mode flag LAST, so a crash
  /// mid-install leaves a vault that still reads as password mode and simply
  /// has no usable blob, rather than one that claims to be passwordless with
  /// nothing behind it.
  Future<void> _installSeedNoPassword(Uint8List seed, String mnemonic) async {
    final keys = await _deriveKeys(seed);
    _vaultKeyPair = keys.keyPair;
    _vaultPublicKey = keys.publicKey;
    _kLocal = keys.kLocal;
    _billingIdBytes = keys.billingId;

    await _storage.write(
      key: _kVaultPub,
      value: base64Encode(keys.publicKey.bytes),
    );
    await _storage.write(key: _kSeedNoAuth, value: base64Encode(seed));
    await _storage.write(key: _kMnemonicNoAuth, value: mnemonic);
    await _clearPasswordBlob();

    // Same rule as _installSeed: a fresh vault never inherits a stale wrap.
    await disableBiometric();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPasswordless, true);
  }

  /// Opens a passwordless vault. Runs the identical derive-and-verify sequence
  /// as [unlock], so the anti-tamper public-key check applies equally.
  Future<bool> unlockWithoutPassword() async {
    final raw = await _storage.read(key: _kSeedNoAuth);
    if (raw == null) return false;
    final seed = base64Decode(raw);

    final keys = await _deriveKeys(seed);
    await _verifyStoredPublicKey(keys.publicKey);

    _vaultKeyPair = keys.keyPair;
    _vaultPublicKey = keys.publicKey;
    _kLocal = keys.kLocal;
    _billingIdBytes = keys.billingId;
    return true;
  }

  /// The stored phrase for a passwordless vault. Null in password mode, where
  /// the password-wrapped blob is used instead.
  Future<String?> revealMnemonicNoAuth() => _storage.read(key: _kMnemonicNoAuth);

  /// The password the user chose at signup, held in memory for the length
  /// of the signup session so that "I already have a phrase" on the phrase
  /// screen can stage a restore WITHOUT asking for it again (MTR#2 A3/A6).
  /// Cleared on lock, wipe, and staged-recovery commit/discard. Never
  /// logged.
  String? _signupPassword;

  /// True while a signup made with "Continue without password" is in its
  /// hand-off window. Distinguishes "chose no password" from "the password
  /// was dropped on lock": only the first may stage a passwordless restore.
  bool _signupPasswordless = false;

  /// True while [createAccount]'s password is still held for reuse.
  /// True while the signup's choice, a password or none, is still held for
  /// the "Have a phrase?" hand-off, so a restore can be staged the same way.
  bool get hasSignupPassword =>
      _signupPassword != null || _signupPasswordless;

  /// Abandons the in-progress signup vault (nothing has been uploaded yet)
  /// and stages [mnemonic] as a recovery candidate under the SAME password
  /// the user just chose. Persists nothing: the caller's cloud canary
  /// decides whether [commitStagedRecovery] runs.
  Future<void> abandonSignupForRestore(String mnemonic) async {
    // Null for a signup that chose "Continue without password", in which
    // case the restore is staged passwordless too and the choice carries
    // over. Null because a lock dropped the password is a different thing
    // and stays an error, as before.
    final password = _signupPassword;
    if (password == null && !_signupPasswordless) {
      throw StateError('No signup password held to reuse.');
    }
    await wipeVault();
    await stageRecovery(mnemonic, password);
  }

  /// Restores a vault from its mnemonic and sets a new password.
  Future<void> recoverAccount(String mnemonic, String newPassword) async {
    if (!bip39.validateMnemonic(mnemonic)) {
      throw Exception('Invalid recovery phrase');
    }
    final seed = bip39.mnemonicToSeed(mnemonic);
    await _installSeed(seed, newPassword);
    await _encryptAndSaveMnemonicPwBlob(newPassword, mnemonic);
  }

  // ---------------------------------------------------------------------------
  // Staged recovery (keys in memory, nothing persisted)
  // ---------------------------------------------------------------------------

  /// Candidate recovery awaiting ownership proof. The old restore flow
  /// PERSISTED an unverified seed before any check — a wrong-but-valid
  /// phrase permanently overwrote seed_blob_v1 and the only way out was a
  /// reinstall (MTR#1 F9).
  Uint8List? _stagedSeed;
  String? _stagedPassword;
  String? _stagedMnemonic;

  /// True while a staged (uncommitted) recovery is loaded.
  bool get hasStagedRecovery => _stagedSeed != null;

  /// Derives the candidate vault keys into MEMORY ONLY, so the canary and
  /// snapshot probes run against them, and holds the seed + password for
  /// [commitStagedRecovery]. Persists nothing: no seed blob, no public key,
  /// no biometric teardown. Call [discardStagedRecovery] on any exit that
  /// doesn't commit.
  Future<void> stageRecovery(String mnemonic, [String? newPassword]) async {
    if (!bip39.validateMnemonic(mnemonic)) {
      throw Exception('Invalid recovery phrase');
    }
    discardStagedRecovery();
    final seed = bip39.mnemonicToSeed(mnemonic);
    final keys = await _deriveKeys(seed);
    _vaultKeyPair = keys.keyPair;
    _vaultPublicKey = keys.publicKey;
    _kLocal = keys.kLocal;
    _billingIdBytes = keys.billingId;
    _stagedSeed = seed;
    _stagedPassword = newPassword;
    _stagedMnemonic = mnemonic;
  }

  /// Persists the staged recovery — the phrase proved it owns the vault (or
  /// the user explicitly chose to found a new vault with it). The in-memory
  /// keys stay resident (already derived from this seed).
  Future<void> commitStagedRecovery() async {
    final seed = _stagedSeed;
    if (seed == null) {
      throw StateError('No staged recovery to commit.');
    }
    final password = _stagedPassword;
    final mnemonic = _stagedMnemonic;
    await _storage.write(
      key: _kVaultPub,
      value: base64Encode(_vaultPublicKey!.bytes),
    );
    if (password != null) {
      await _encryptAndSaveSeedBlob(password, seed);
      if (mnemonic != null) {
        await _encryptAndSaveMnemonicPwBlob(password, mnemonic);
      }
      await _clearPasswordlessMaterial();
    } else {
      // "Continue without password" on the restore path: the same posture
      // as a passwordless signup. The mode flag is written last so a crash
      // before it leaves a vault that still reads as password mode.
      await _storage.write(key: _kSeedNoAuth, value: base64Encode(seed));
      if (mnemonic != null) {
        await _storage.write(key: _kMnemonicNoAuth, value: mnemonic);
      }
      await _clearPasswordBlob();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPasswordless, true);
    }
    // Same rule as _installSeed: a new seed never inherits a biometric wrap.
    await disableBiometric();
    seed.fillRange(0, seed.length, 0);
    _stagedSeed = null;
    _stagedPassword = null;
    _stagedMnemonic = null;
    _signupPassword = null;
    _signupPasswordless = false;
  }

  /// A vault is in exactly one mode. Installing one mode removes the other's
  /// material, so a stale blob can never be picked up by the wrong unlock path.
  Future<void> _clearPasswordlessMaterial() async {
    await _storage.delete(key: _kSeedNoAuth);
    await _storage.delete(key: _kMnemonicNoAuth);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPasswordless);
  }

  Future<void> _clearPasswordBlob() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _kSeedBlob,
      _kSeedNonce,
      _kSeedMac,
      _kSeedSalt,
      _kMnemonicPwBlob,
      _kMnemonicPwNonce,
      _kMnemonicPwMac,
      _kMnemonicPwSalt,
    ]) {
      await prefs.remove(key);
    }
  }

  /// Drops a staged recovery and the in-memory keys derived from it.
  /// Idempotent; safe to call when nothing is staged.
  void discardStagedRecovery() {
    final seed = _stagedSeed;
    if (seed == null) return;
    seed.fillRange(0, seed.length, 0);
    _stagedSeed = null;
    _stagedPassword = null;
    _stagedMnemonic = null;
    _vaultKeyPair = null;
    _vaultPublicKey = null;
    _kLocal = null;
  }

  // ---------------------------------------------------------------------------
  // Vault wipe (the primitive sign-out/forget/start-over flows build on)
  // ---------------------------------------------------------------------------

  /// Destroys every key artifact on this device: in-memory keys, the
  /// password-wrapped seed blob, the stored public key, the crash-recovery
  /// mnemonic blob and its flags, and the biometric wrap. Files in the
  /// cloud are untouched — the recovery phrase regains access elsewhere.
  ///
  /// This is deliberately KeyManagerService-scoped; account registry, DB,
  /// and prefs cleanup live in VaultResetService.
  Future<void> wipeVault() async {
    discardStagedRecovery();
    _signupPassword = null;
    _signupPasswordless = false;
    _vaultKeyPair = null;
    _vaultPublicKey = null;
    _kLocal = null;
    await disableBiometric();
    await _storage.delete(key: _kVaultPub);
    await _storage.delete(key: _kSeedNoAuth);
    await _storage.delete(key: _kMnemonicNoAuth);
    final prefs = await SharedPreferences.getInstance();
    for (final key in [
      _kSeedBlob,
      _kSeedNonce,
      _kSeedMac,
      _kSeedSalt,
      _kPasswordless,
      _kUnlockFailures,
      _kUnlockLockedUntil,
      _kSignupInProgress,
      _kRecoveryShown,
      _kEncryptedMnemonic,
      _kEncryptedMnemonicNonce,
      _kEncryptedMnemonicMac,
      _kMnemonicPwBlob,
      _kMnemonicPwNonce,
      _kMnemonicPwMac,
      _kMnemonicPwSalt,
    ]) {
      await prefs.remove(key);
    }
  }

  /// Derives the vault keys from [seed], writes the public key to secure
  /// storage, and password-wraps the seed. Loads all keys into memory.
  Future<void> _installSeed(Uint8List seed, String password) async {
    final keys = await _deriveKeys(seed);
    _vaultKeyPair = keys.keyPair;
    _vaultPublicKey = keys.publicKey;
    _kLocal = keys.kLocal;
    _billingIdBytes = keys.billingId;

    await _storage.write(
      key: _kVaultPub,
      value: base64Encode(keys.publicKey.bytes),
    );
    await _encryptAndSaveSeedBlob(password, seed);
    await _clearPasswordlessMaterial();

    // A fresh vault must never inherit a biometric wrap: a stale wrap from a
    // previous vault would biometric-unlock the OLD seed and detonate the
    // public-key integrity check with a message the user can't act on.
    await disableBiometric();
  }

  // ---------------------------------------------------------------------------
  // Unlock / lock
  // ---------------------------------------------------------------------------

  /// Unlocks the vault with the password. Derives every key from the seed,
  /// then **verifies** the re-derived public key matches the one in secure
  /// storage. Returns false on a wrong password; throws
  /// [PublicKeyMismatchException] if the stored public key was tampered with.
  Future<bool> unlock(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final lockedUntil = prefs.getInt(_kUnlockLockedUntil) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockedUntil > now) {
      throw UnlockThrottledException(Duration(milliseconds: lockedUntil - now));
    }

    final seed = await _decryptSeedBlob(password);
    if (seed == null) {
      // Wrong password, or no account. Count it either way; a missing blob
      // cannot be unlocked by any password so the count is harmless there.
      final failures = (prefs.getInt(_kUnlockFailures) ?? 0) + 1;
      await prefs.setInt(_kUnlockFailures, failures);
      if (failures >= _kMaxFreeFailures) {
        final steps = failures - _kMaxFreeFailures;
        var wait = _kFirstLockout * (1 << (steps > 10 ? 10 : steps));
        if (wait > _kMaxLockout) wait = _kMaxLockout;
        await prefs.setInt(_kUnlockLockedUntil,
            DateTime.now().millisecondsSinceEpoch + wait.inMilliseconds);
      }
      return false;
    }

    final keys = await _deriveKeys(seed);
    await _verifyStoredPublicKey(keys.publicKey);

    _vaultKeyPair = keys.keyPair;
    _vaultPublicKey = keys.publicKey;
    _kLocal = keys.kLocal;
    _billingIdBytes = keys.billingId;
    await prefs.remove(_kUnlockFailures);
    await prefs.remove(_kUnlockLockedUntil);
    return true;
  }

  /// Remaining lockout after too many wrong passwords, or zero.
  Future<Duration> unlockLockoutRemaining() async {
    final prefs = await SharedPreferences.getInstance();
    final lockedUntil = prefs.getInt(_kUnlockLockedUntil) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    return lockedUntil > now
        ? Duration(milliseconds: lockedUntil - now)
        : Duration.zero;
  }

  /// Re-wraps the on-device seed blob under a new password. The seed — and
  /// therefore the vault keys and the recovery phrase — is UNCHANGED; only
  /// the password that unlocks the local seed blob changes. Returns false if
  /// [current] is wrong. The biometric wrap holds the same seed under its own
  /// Keystore key, so it keeps working untouched.
  Future<bool> changePassword(String current, String newPassword) async {
    final seed = await _decryptSeedBlob(current);
    if (seed == null) return false;
    try {
      await _encryptAndSaveSeedBlob(newPassword, seed);
      // Re-wrap the persistent mnemonic blob (if any) under the new password
      // so "View recovery phrase" keeps working after a password change.
      final mnemonic = await revealMnemonic(current);
      if (mnemonic != null) {
        await _encryptAndSaveMnemonicPwBlob(newPassword, mnemonic);
      }
      return true;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// Loads ONLY the public key from secure storage — the encrypt-only path
  /// used by the background sync isolate. Structurally cannot load the
  /// private key. Returns false if no public key is stored.
  Future<bool> loadPublicKeyForEncrypt() async {
    if (_vaultPublicKey != null) return true;
    final b64 = await _storage.read(key: _kVaultPub);
    if (b64 == null) return false;
    _vaultPublicKey =
        SimplePublicKey(base64Decode(b64), type: KeyPairType.x25519);
    return true;
  }

  /// Zeroes the private key and local secret. The public key stays resident
  /// so background encryption keeps working. Locked = encrypt-only.
  ///
  /// The Keystore biometric wrap deliberately survives a lock — surviving
  /// locks is its entire purpose. Its key is auth-per-use hardware-gated, so
  /// a locked app holds no usable decrypt capability.
  void lock() {
    _vaultKeyPair = null;
    _kLocal = null;
    _billingIdBytes = null;
    _signupPassword = null;
    _signupPasswordless = false;
  }

  // ---------------------------------------------------------------------------
  // Biometric unlock (second wrap of the same seed — see class doc)
  // ---------------------------------------------------------------------------

  /// Arms biometric unlock. The seed exists in memory only during a password
  /// entry, so enabling ALWAYS requires the password — there is no other
  /// legitimate moment to re-wrap it. Shows a biometric prompt (the encrypt
  /// itself needs a fresh authentication).
  ///
  /// Returns false on a wrong password. Throws [BiometricUnlockException]
  /// for prompt-level failures (canceled, lockout, …).
  Future<bool> enableBiometric(String password) async {
    final seed = await _decryptSeedBlob(password);
    if (seed == null) return false;
    try {
      await BiometricUnlockService().wrapSeed(seed);
      await BiometricUnlockService().setEnabled(true);
      return true;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// Unlocks the vault via the hardware-backed biometric wrap. Runs the
  /// SAME derive-and-verify sequence as the password path, including the
  /// stored-public-key anti-tamper check.
  ///
  /// Throws [BiometricInvalidatedException] when Android destroyed the key
  /// (fingerprint enrolled/removed, PIN changed, lock screen removed) — the
  /// wrap and flag are already wiped when this surfaces, and the password
  /// path is untouched. Other prompt failures rethrow as
  /// [BiometricUnlockException] for the UI to route to password entry.
  Future<bool> unlockWithBiometric() async {
    Uint8List seed;
    try {
      seed = await BiometricUnlockService().unwrapSeed();
    } on BiometricUnlockException catch (e) {
      if (e.code == BiometricUnlockError.invalidated ||
          e.code == BiometricUnlockError.keyMissing) {
        await disableBiometric();
        throw const BiometricInvalidatedException();
      }
      rethrow;
    }
    try {
      final keys = await _deriveKeys(seed);
      await _verifyStoredPublicKey(keys.publicKey);
      _vaultKeyPair = keys.keyPair;
      _vaultPublicKey = keys.publicKey;
      _kLocal = keys.kLocal;
      _billingIdBytes = keys.billingId;
      return true;
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// Disarms biometric unlock: destroys the Keystore key and wrapped blob,
  /// clears the flag. Idempotent, never throws.
  Future<void> disableBiometric() async {
    await BiometricUnlockService().teardown();
    await BiometricUnlockService().setEnabled(false);
  }

  // ---------------------------------------------------------------------------
  // Key derivation (frozen)
  // ---------------------------------------------------------------------------

  static Future<_DerivedKeys> _deriveKeys(Uint8List seed) async {
    final x25519Seed = await _hkdf(seed, infoX25519, 32);
    final kLocalBytes = await _hkdf(seed, infoLocal, 32);
    final billingBytes = await _hkdf(seed, infoBilling, 32);
    final keyPair = await X25519().newKeyPairFromSeed(x25519Seed);
    final publicKey = await keyPair.extractPublicKey();
    return _DerivedKeys(
      keyPair: keyPair,
      publicKey: publicKey,
      kLocal: SecretKey(kLocalBytes),
      billingId: billingBytes,
    );
  }

  /// HKDF-SHA256 with empty salt; domain separation comes from [info]. The
  /// seed is already uniformly random high-entropy keying material, so an
  /// empty salt is standard practice for splitting one root into subkeys.
  static Future<Uint8List> _hkdf(Uint8List ikm, String info, int length) async {
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final derived = await hkdf.deriveKey(
      secretKey: SecretKey(ikm),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  /// Pure derivation for the frozen-mnemonic test — no storage, no state.
  /// Returns the vault public key, k_local and the billing ID so the test can
  /// pin them and catch any drift in the frozen info strings.
  @visibleForTesting
  static Future<({Uint8List publicKey, Uint8List kLocal, Uint8List billingId})>
      deriveVaultKeysForTest(Uint8List seed) async {
    final keys = await _deriveKeys(seed);
    return (
      publicKey: Uint8List.fromList(keys.publicKey.bytes),
      kLocal: Uint8List.fromList(await keys.kLocal.extractBytes()),
      billingId: keys.billingId,
    );
  }

  /// Injects in-memory keys directly, bypassing storage — for format/crypto
  /// tests that exercise encrypt/decrypt without a device.
  @visibleForTesting
  void installKeysForTest({
    required SimpleKeyPair keyPair,
    required SimplePublicKey publicKey,
    SecretKey? kLocal,
  }) {
    _vaultKeyPair = keyPair;
    _vaultPublicKey = publicKey;
    _kLocal = kLocal;
  }

  Future<void> _verifyStoredPublicKey(SimplePublicKey derived) async {
    final stored = await _storage.read(key: _kVaultPub);
    if (stored == null) {
      // First unlock after an interrupted install — write it now.
      await _storage.write(key: _kVaultPub, value: base64Encode(derived.bytes));
      return;
    }
    if (!_constantTimeEquals(base64Decode(stored), derived.bytes)) {
      throw const PublicKeyMismatchException();
    }
  }

  // ---------------------------------------------------------------------------
  // Password-wrapped seed blob
  // ---------------------------------------------------------------------------

  Future<void> _encryptAndSaveSeedBlob(String password, Uint8List seed) async {
    final salt = _randomBytes(16);
    final kek = await _deriveKeyFromPassword(password, salt);
    final nonce = _randomBytes(12);
    final box = await AesGcm.with256bits()
        .encrypt(seed, secretKey: kek, nonce: nonce);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSeedBlob, base64Encode(box.cipherText));
    await prefs.setString(_kSeedNonce, base64Encode(nonce));
    await prefs.setString(_kSeedMac, base64Encode(box.mac.bytes));
    await prefs.setString(_kSeedSalt, base64Encode(salt));
  }

  /// Returns the 64-byte seed, or null on wrong password / missing blob.
  Future<Uint8List?> _decryptSeedBlob(String password) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final blob = prefs.getString(_kSeedBlob);
      final salt = prefs.getString(_kSeedSalt);
      final nonce = prefs.getString(_kSeedNonce);
      final mac = prefs.getString(_kSeedMac);
      if (blob == null || salt == null || nonce == null || mac == null) {
        return null;
      }
      final kek = await _deriveKeyFromPassword(password, base64Decode(salt));
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(blob),
          nonce: base64Decode(nonce),
          mac: Mac(base64Decode(mac)),
        ),
        secretKey: kek,
      );
      return Uint8List.fromList(clear);
    } catch (_) {
      return null; // wrong password
    }
  }

  // ---------------------------------------------------------------------------
  // Crash-recovery mnemonic blob (encrypted under k_local)
  // ---------------------------------------------------------------------------

  Future<bool> hasSignupInProgress() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(_kSignupInProgress) ?? false) &&
        !(prefs.getBool(_kRecoveryShown) ?? false);
  }

  /// Decrypts the pending mnemonic if a signup was interrupted. Requires the
  /// vault to be unlocked (k_local present).
  Future<String?> retrieveMnemonicIfPending() async {
    final kLocal = _kLocal;
    if (kLocal == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final cipher = prefs.getString(_kEncryptedMnemonic);
    final nonce = prefs.getString(_kEncryptedMnemonicNonce);
    final mac = prefs.getString(_kEncryptedMnemonicMac);
    if (cipher == null || nonce == null || mac == null) return null;
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(cipher),
          nonce: base64Decode(nonce),
          mac: Mac(base64Decode(mac)),
        ),
        secretKey: kLocal,
      );
      return utf8.decode(clear);
    } catch (_) {
      return null;
    }
  }

  Future<void> markRecoveryShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRecoveryShown, true);
    await prefs.setBool(_kSignupInProgress, false);
    await prefs.remove(_kEncryptedMnemonic);
    await prefs.remove(_kEncryptedMnemonicNonce);
    await prefs.remove(_kEncryptedMnemonicMac);
  }

  Future<void> _encryptAndSaveMnemonicBlob(String mnemonic) async {
    final kLocal = _kLocal;
    if (kLocal == null) throw StateError('k_local not loaded');
    final nonce = _randomBytes(12);
    final box = await AesGcm.with256bits()
        .encrypt(utf8.encode(mnemonic), secretKey: kLocal, nonce: nonce);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEncryptedMnemonic, base64Encode(box.cipherText));
    await prefs.setString(_kEncryptedMnemonicNonce, base64Encode(nonce));
    await prefs.setString(_kEncryptedMnemonicMac, base64Encode(box.mac.bytes));
  }

  /// Persists the mnemonic encrypted under a password-derived key (Argon2id),
  /// so it can be revealed later. Parallel to the seed blob and wrapped under
  /// the SAME password.
  Future<void> _encryptAndSaveMnemonicPwBlob(
      String password, String mnemonic) async {
    final salt = _randomBytes(16);
    final kek = await _deriveKeyFromPassword(password, salt);
    final nonce = _randomBytes(12);
    final box = await AesGcm.with256bits()
        .encrypt(utf8.encode(mnemonic), secretKey: kek, nonce: nonce);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMnemonicPwBlob, base64Encode(box.cipherText));
    await prefs.setString(_kMnemonicPwNonce, base64Encode(nonce));
    await prefs.setString(_kMnemonicPwMac, base64Encode(box.mac.bytes));
    await prefs.setString(_kMnemonicPwSalt, base64Encode(salt));
  }

  /// True when a persistent, password-wrapped mnemonic blob exists — i.e.
  /// the vault was created or restored after view-phrase shipped. Older
  /// vaults return false and cannot reveal their words.
  Future<bool> canRevealMnemonic() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kMnemonicPwBlob) != null;
  }

  /// Decrypts and returns the recovery phrase for a correct [password], or
  /// null on a wrong password / when no persistent blob exists.
  Future<String?> revealMnemonic(String password) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final blob = prefs.getString(_kMnemonicPwBlob);
      final salt = prefs.getString(_kMnemonicPwSalt);
      final nonce = prefs.getString(_kMnemonicPwNonce);
      final mac = prefs.getString(_kMnemonicPwMac);
      if (blob == null || salt == null || nonce == null || mac == null) {
        return null;
      }
      final kek = await _deriveKeyFromPassword(password, base64Decode(salt));
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(
          base64Decode(blob),
          nonce: base64Decode(nonce),
          mac: Mac(base64Decode(mac)),
        ),
        secretKey: kek,
      );
      return utf8.decode(clear);
    } catch (_) {
      return null; // wrong password
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<SecretKey> _deriveKeyFromPassword(String password, List<int> salt) {
    // Same Argon2id call the share-password KDF uses (see
    // EncryptionService.derivePasswordKey).
    return _argon2.deriveKeyFromPassword(password: password, nonce: salt);
  }

  Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => rnd.nextInt(256)));
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class _DerivedKeys {
  final SimpleKeyPair keyPair;
  final SimplePublicKey publicKey;
  final SecretKey kLocal;
  final Uint8List billingId;
  const _DerivedKeys({
    required this.keyPair,
    required this.publicKey,
    required this.kLocal,
    required this.billingId,
  });
}

/// Thrown when Android permanently destroyed the biometric Keystore key —
/// fired by enrollment changes (fingerprint added/removed), PIN changes, or
/// lock-screen removal. This is the OS's anti-tamper working as designed.
/// By the time this surfaces the wrap is already wiped; the password wrap is
/// untouched and remains the source of truth. Zero data loss.
class BiometricInvalidatedException implements Exception {
  const BiometricInvalidatedException();
  @override
  String toString() =>
      'Your device security settings changed. Sign in with your password to '
      're-enable fingerprint unlock.';
}

/// Thrown when the vault public key in secure storage doesn't match the one
/// re-derived from the seed on unlock — an integrity failure that must halt
/// syncing and alert the user.
class PublicKeyMismatchException implements Exception {
  const PublicKeyMismatchException();
  @override
  String toString() =>
      'Vault public key mismatch: stored key does not match the recovery '
      'seed. Encryption is halted to protect your data.';
}

/// Thrown by [KeyManagerService.unlock] while a lockout from repeated wrong
/// passwords is in force. [remaining] is how long until the next attempt is
/// accepted.
class UnlockThrottledException implements Exception {
  UnlockThrottledException(this.remaining);
  final Duration remaining;

  @override
  String toString() {
    final s = remaining.inSeconds + 1;
    return s >= 60
        ? 'Too many attempts. Try again in ${(s / 60).ceil()} min.'
        : 'Too many attempts. Try again in $s s.';
  }
}
