import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the device can do, right now.
enum BiometricCapability { available, noHardware, noneEnrolled, noLockScreen, unavailable }

/// State of the on-device biometric wrap.
enum BiometricArmedState { armed, missing, invalidated }

/// Typed failure surface of the platform channel.
enum BiometricUnlockError {
  invalidated,
  keyMissing,
  userCanceled,
  lockout,
  lockoutPermanent,
  noneEnrolled,
  noLockScreen,
  failed,
}

class BiometricUnlockException implements Exception {
  final BiometricUnlockError code;
  final String? message;
  const BiometricUnlockException(this.code, [this.message]);
  @override
  String toString() => 'BiometricUnlockException(${code.name}): $message';
}

/// Thin Dart wrapper over the Kotlin Keystore vault (BiometricSeedVault.kt).
///
/// This class knows nothing about key derivation — it moves the raw 64-byte
/// seed across the channel and back, maps platform error codes to typed
/// exceptions, and owns the `biometric_enabled_v2` UI flag. All seed-touching
/// orchestration lives in KeyManagerService.
///
/// The hardware guarantees live entirely on the native side: the wrapping key
/// is generated inside AndroidKeyStore with setUserAuthenticationRequired and
/// is only usable through a BiometricPrompt.CryptoObject — there is no Dart
/// code path that can reach the seed without a fresh strong-biometric auth.
class BiometricUnlockService {
  static final BiometricUnlockService _instance = BiometricUnlockService._();
  factory BiometricUnlockService() => _instance;
  BiometricUnlockService._();

  static const _channel = MethodChannel('ciphernest/biometric_seed');

  /// Deliberately NOT `biometric_enabled_v1` — that key belongs to the
  /// deleted software-prompt implementation and may be stale-true on
  /// upgraded installs.
  static const _kEnabledFlag = 'biometric_enabled_v2';

  Future<BiometricCapability> capability() async {
    final s = await _channel.invokeMethod<String>('capability');
    return BiometricCapability.values.firstWhere(
      (v) => v.name == s,
      orElse: () => BiometricCapability.unavailable,
    );
  }

  /// Probes the Keystore key without prompting. Detection only — the caller
  /// decides whether to wipe (policy lives in KeyManagerService).
  Future<BiometricArmedState> checkArmed() async {
    final s = await _channel.invokeMethod<String>('checkArmed');
    return BiometricArmedState.values.firstWhere(
      (v) => v.name == s,
      orElse: () => BiometricArmedState.invalidated,
    );
  }

  /// Wraps [seed] under a fresh hardware key. Shows a biometric prompt (the
  /// encrypt operation itself requires authentication — that is the proof
  /// the TEE path works on this device). Throws [BiometricUnlockException].
  Future<void> wrapSeed(Uint8List seed) async {
    try {
      await _channel.invokeMethod<bool>('enable', {
        'seed': seed,
        'title': 'Enable fingerprint unlock',
        'subtitle': 'Confirm your fingerprint to finish setup',
        'negativeButton': 'Cancel',
      });
    } on PlatformException catch (e) {
      throw _map(e);
    }
  }

  /// Unwraps and returns the 64-byte seed after a successful biometric
  /// authentication. Throws [BiometricUnlockException]; `invalidated` /
  /// `keyMissing` mean the wrap is dead (enrollment change) and must be
  /// torn down by the caller.
  Future<Uint8List> unwrapSeed() async {
    try {
      final seed = await _channel.invokeMethod<Uint8List>('unlock', {
        'title': 'Unlock CipherNest',
        'subtitle': '',
        'negativeButton': 'Use password',
      });
      if (seed == null || seed.length != 64) {
        throw const BiometricUnlockException(
            BiometricUnlockError.failed, 'Bad seed from platform');
      }
      return seed;
    } on PlatformException catch (e) {
      throw _map(e);
    }
  }

  /// Destroys the Keystore key and the wrapped blob. Idempotent; never
  /// throws — teardown must always succeed from the caller's perspective.
  Future<void> teardown() async {
    try {
      await _channel.invokeMethod<bool>('disable');
    } catch (_) {
      // Best effort. A failed native cleanup leaves at worst an unusable
      // key that the next enable() deletes before regenerating.
    }
  }

  Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabledFlag) ?? false;
  }

  Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledFlag, value);
  }

  BiometricUnlockException _map(PlatformException e) {
    final code = BiometricUnlockError.values.firstWhere(
      (v) => v.name == e.code,
      orElse: () => BiometricUnlockError.failed,
    );
    return BiometricUnlockException(code, e.message);
  }
}
