import 'dart:convert';
import 'dart:math';

import 'package:bip39/bip39.dart' as bip39;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class KeyManagerService {
  static final KeyManagerService _instance = KeyManagerService._internal();
  factory KeyManagerService() => _instance;
  KeyManagerService._internal();

  /// Set to true by [createAccount], cleared after the user completes the
  /// recovery-phrase type-back. Its presence at login time signals the app
  /// to resume the interrupted signup by re-showing the phrase.
  static const _kSignupInProgress = 'signup_in_progress_v1';

  /// True once the recovery-phrase type-back has been completed for the
  /// current vault. When this flips, the encrypted-mnemonic blob below is
  /// wiped — we never keep the phrase on disk one second longer than we
  /// have to.
  static const _kRecoveryShown = 'recovery_shown_v1';

  /// AES-GCM(master-key, plaintext=mnemonic) cipher text.
  static const _kEncryptedMnemonic = 'encrypted_mnemonic';
  static const _kEncryptedMnemonicNonce = 'encrypted_mnemonic_nonce';
  static const _kEncryptedMnemonicMac = 'encrypted_mnemonic_mac';

  final _storage = const FlutterSecureStorage();
  final LocalAuthentication _localAuth = LocalAuthentication();
  final _argon2 = Argon2id(
    parallelism: 1,
    memory: 65536, // 64 MB
    iterations: 2,
    hashLength: 32,
  );

  /// The Master Key currently loaded in memory.
  /// If null, the user is locked out (needs to log in).
  SecretKey? _masterKey;

  /// Returns the master key if unlocked, otherwise throws error.
  SecretKey get masterKey {
    if (_masterKey == null) throw Exception('Vault is locked.');
    return _masterKey!;
  }

  /// Checks if an account exists on this device.
  Future<bool> hasAccount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey('encrypted_mk');
  }

  /// CREATION: Generates a new Master Key from a 12-word mnemonic.
  /// Returns the mnemonic so the user can write it down.
  ///
  /// Also persists the mnemonic encrypted-under-the-master-key and sets a
  /// signup-in-progress flag. If the user kills the app between here and
  /// completing the recovery-phrase type-back, the login screen can decrypt
  /// the pending mnemonic on next unlock and resume the flow, so nobody
  /// loses their vault to a mid-signup crash.
  Future<String> createAccount(String password) async {
    // 1. Generate 12-word mnemonic (BIP-39)
    final mnemonic = bip39.generateMnemonic();

    // 2. Derive the Master Key (32 bytes) from the mnemonic
    // We use the seed, taken as 32 bytes for AES-256
    final seed = bip39.mnemonicToSeed(mnemonic);
    final masterKeyBytes = seed.sublist(0, 32);
    _masterKey = SecretKey(masterKeyBytes);

    // 3. Save directly to SecureStorage for "Remember Me" access
    await _storage.write(
      key: 'master_key_raw',
      value: base64Encode(masterKeyBytes),
    );

    // 4. Encrypt the MK with the Password (for Cloud Backup & Login)
    await _encryptAndSaveKeyBlob(password, masterKeyBytes);

    // 5. Persist encrypted mnemonic + signup-in-progress flag (crash-safety).
    await _encryptAndSaveMnemonicBlob(mnemonic);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSignupInProgress, true);
    await prefs.setBool(_kRecoveryShown, false);

    return mnemonic;
  }

  /// RESTORE: Recovers account using the 12-word mnemonic and sets a new password.
  Future<void> recoverAccount(String mnemonic, String newPassword) async {
    if (!bip39.validateMnemonic(mnemonic)) {
      throw Exception('Invalid recovery phrase');
    }

    final seed = bip39.mnemonicToSeed(mnemonic);
    final masterKeyBytes = seed.sublist(0, 32);
    _masterKey = SecretKey(masterKeyBytes);

    // Update SecureStorage
    await _storage.write(
      key: 'master_key_raw', 
      value: base64Encode(masterKeyBytes)
    );

    // Update the Password-Encrypted Blob
    await _encryptAndSaveKeyBlob(newPassword, masterKeyBytes);
  }

  /// LOGIN: Unlocks the app using the password.
  /// (Used if the raw key is wiped from SecureStorage or on a new install context)
  Future<bool> login(String password) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // 1. Fetch the encrypted blob and salt
      final encryptedMkBase64 = prefs.getString('encrypted_mk');
      final saltBase64 = prefs.getString('mk_salt');
      final nonceBase64 = prefs.getString('mk_nonce');

      if (encryptedMkBase64 == null || saltBase64 == null || nonceBase64 == null) {
        return false; // No account found
      }

      // 2. Derive KEK (Key Encryption Key) from Password
      final salt = base64Decode(saltBase64);
      final kek = await _deriveKeyFromPassword(password, salt);

      // 3. Decrypt the Master Key
      final algorithm = AesGcm.with256bits();
      final secretBox = SecretBox(
        base64Decode(encryptedMkBase64),
        nonce: base64Decode(nonceBase64),
        mac: Mac(base64Decode(prefs.getString('mk_mac') ?? '')),
      );

      final clearText = await algorithm.decrypt(
        secretBox,
        secretKey: kek,
      );

      _masterKey = SecretKey(clearText);
      return true;
    } catch (e) {
      // Decryption failed (Wrong password)
      return false;
    }
  }

  Future<bool> get canCheckBiometrics async {
    try {
      return await _localAuth.canCheckBiometrics && 
             await _localAuth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// PROMPT: Asks user for FaceID/Fingerprint to unlock the Master Key
  Future<bool> authenticateWithBiometrics() async {
    try {
      final isAvailable = await canCheckBiometrics;
      if (!isAvailable) return false;

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Scan to unlock your Vault',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (authenticated) {
        // If success, try to load the key from Secure Storage
        return await attemptBiometricUnlock();
      }
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// AUTO-LOGIN: Tries to load the key from SecureStorage.
  Future<bool> attemptBiometricUnlock() async {
    final mkBase64 = await _storage.read(key: 'master_key_raw');
    if (mkBase64 != null) {
      _masterKey = SecretKey(base64Decode(mkBase64));
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Signup-in-progress crash-recovery
  // ---------------------------------------------------------------------------

  /// True iff the app is in the middle of a signup: master key exists but
  /// the recovery-phrase type-back never completed. Used by the login screen
  /// to route back to the phrase view after unlock.
  Future<bool> hasSignupInProgress() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool(_kSignupInProgress) ?? false) &&
        !(prefs.getBool(_kRecoveryShown) ?? false);
  }

  /// Decrypts and returns the pending mnemonic if a signup was interrupted.
  /// Requires the master key to already be unlocked in memory (via [login]
  /// or a biometric unlock). Returns null if there is no pending mnemonic,
  /// the blob is missing / corrupted, or decryption fails for any reason.
  Future<String?> retrieveMnemonicIfPending() async {
    if (_masterKey == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final cipher = prefs.getString(_kEncryptedMnemonic);
    final nonce = prefs.getString(_kEncryptedMnemonicNonce);
    final mac = prefs.getString(_kEncryptedMnemonicMac);
    if (cipher == null || nonce == null || mac == null) return null;
    try {
      final secretBox = SecretBox(
        base64Decode(cipher),
        nonce: base64Decode(nonce),
        mac: Mac(base64Decode(mac)),
      );
      final clearText = await AesGcm.with256bits().decrypt(
        secretBox,
        secretKey: _masterKey!,
      );
      return utf8.decode(clearText);
    } catch (_) {
      return null;
    }
  }

  /// Called by the recovery-phrase screen once the type-back completes.
  /// Wipes the encrypted mnemonic (no reason to keep it after this), sets
  /// the recovery-shown flag, and clears the signup-in-progress flag.
  Future<void> markRecoveryShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRecoveryShown, true);
    await prefs.setBool(_kSignupInProgress, false);
    await prefs.remove(_kEncryptedMnemonic);
    await prefs.remove(_kEncryptedMnemonicNonce);
    await prefs.remove(_kEncryptedMnemonicMac);
  }

  /// Encrypts the mnemonic under the master key. Called only from within
  /// [createAccount] while `_masterKey` is guaranteed non-null.
  Future<void> _encryptAndSaveMnemonicBlob(String mnemonic) async {
    final algorithm = AesGcm.with256bits();
    final nonce = _randomBytes(12);
    final secretBox = await algorithm.encrypt(
      utf8.encode(mnemonic),
      secretKey: _masterKey!,
      nonce: nonce,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kEncryptedMnemonic,
      base64Encode(secretBox.cipherText),
    );
    await prefs.setString(_kEncryptedMnemonicNonce, base64Encode(nonce));
    await prefs.setString(
      _kEncryptedMnemonicMac,
      base64Encode(secretBox.mac.bytes),
    );
  }

  // --- HELPERS ---

  Future<void> _encryptAndSaveKeyBlob(String password, Uint8List masterKeyBytes) async {
    // 1. Generate Salt for Password Hashing
    final salt = _randomBytes(16);
    
    // 2. Derive KEK
    final kek = await _deriveKeyFromPassword(password, salt);

    // 3. Encrypt the Master Key
    final algorithm = AesGcm.with256bits();
    final nonce = _randomBytes(12);
    final secretBox = await algorithm.encrypt(
      masterKeyBytes,
      secretKey: kek,
      nonce: nonce,
    );

    // 4. Save everything to SharedPrefs (publicly accessible on phone, but encrypted)
    // In a real app, this 'blob' is what we upload to Google Drive.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('encrypted_mk', base64Encode(secretBox.cipherText));
    await prefs.setString('mk_nonce', base64Encode(nonce));
    await prefs.setString('mk_mac', base64Encode(secretBox.mac.bytes));
    await prefs.setString('mk_salt', base64Encode(salt));
  }

  Future<SecretKey> _deriveKeyFromPassword(String password, Uint8List salt) async {
    final secretKey = await _argon2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    return secretKey;
  }

  Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (i) => rnd.nextInt(256)));
  }
  
  /// Helper to get raw bytes for storage/upload if needed
  Future<Uint8List> getMasterKeyBytes() async {
     if (_masterKey == null) throw Exception('Locked');
     return Uint8List.fromList(await _masterKey!.extractBytes());
  }
}