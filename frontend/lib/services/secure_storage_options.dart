import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The one secure-storage handle every service uses.
///
/// `encryptedSharedPreferences: true` moves values into Jetpack
/// EncryptedSharedPreferences, whose master key lives in the Keystore, instead
/// of the plugin's default of AES-encrypted values in an ordinary preferences
/// file with an RSA-wrapped key (MASVS F-14). The plugin migrates existing
/// entries on first open and falls back to the old store if the encrypted one
/// cannot be initialised, so an upgrade never loses the seed.
///
/// This matters more since vaults can be created without a password: for
/// those, this store holds the seed itself.
const FlutterSecureStorage kSecureStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);
