import 'dart:typed_data';
import 'cloud_account.dart';

/// Abstract base for cloud storage providers (Google Drive, OneDrive, Dropbox).
/// Each provider is bound to ONE [CloudAccount] passed in its constructor.
/// Token refresh is the provider's internal concern — it should write back to
/// AccountRegistry whenever tokens change.
abstract class CloudProvider {
  /// The account this provider instance is bound to.
  CloudAccount get account;

  String? get currentUser;

  /// First-time sign-in. Implementations should be invoked via a static helper
  /// (e.g. `OneDriveProvider.signInNewAccount()`) that performs OAuth, then
  /// returns a fully-formed CloudAccount the caller can register.
  /// This instance method is for re-validating an already-bound account.
  Future<void> signIn();
  Future<void> signOut();

  /// Called on app startup to revive an existing session if possible.
  /// Returns the user identifier (email) if successful.
  Future<String?> restoreSession();

  /// Uploads a file.
  /// Provide [fileBytes] for small files (images).
  /// Provide [fileStream] and [fileSize] for large files (videos).
  Future<String?> uploadEncryptedFile({
    required String filename,
    required bool isImage,
    String? originalName,
    Uint8List? fileBytes,
    Stream<List<int>>? fileStream,
    int? fileSize,
  });

  Future<Uint8List> downloadFile(String cloudId);
  Future<void> deleteFile(String cloudId);

  // Returns generic Maps so we don't depend on provider-specific types.
  Future<List<Map<String, dynamic>>> listCloudFiles();

  // Lookup
  Future<String?> findFileByName(String name);

  // The replacement for "canaryTest"
  Future<bool> checkIntegrity();
}
