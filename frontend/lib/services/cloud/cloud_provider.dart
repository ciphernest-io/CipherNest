import 'dart:typed_data';
import '../../src/models/file_model.dart';
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
  /// [type] is round-tripped via provider-specific metadata (Drive
  /// `appProperties`, OneDrive filename-encoding) so reconcile can restore the
  /// right vault tab when re-listing.
  Future<String?> uploadEncryptedFile({
    required String filename,
    required CnestFileType type,
    String? originalName,
    Uint8List? fileBytes,
    Stream<List<int>>? fileStream,
    int? fileSize,
  });

  Future<Uint8List> downloadFile(String cloudId);

  /// Downloads a byte range [start, endInclusive] of the cloud blob.
  /// Used by the local video streaming server for chunked playback.
  Future<Uint8List> downloadRange(String cloudId, int start, int endInclusive);

  Future<void> deleteFile(String cloudId);

  // Returns generic Maps so we don't depend on provider-specific types.
  // Each entry carries `sealed_meta` (HPKE-sealed name+type) and, during the
  // transition window, legacy plaintext `type` / `original_name`.
  Future<List<Map<String, dynamic>>> listCloudFiles();

  /// Rewrites one vault blob's cloud metadata to the sealed format and
  /// removes the legacy plaintext (Drive: metadata-only files.update;
  /// OneDrive: item rename). Content is never re-uploaded. Used by the
  /// one-time metadata migration; must be idempotent.
  Future<void> sealLegacyMetadata({
    required String cloudId,
    required String cloudName,
    required String sealedMeta,
  });

  /// Lists the backup/ folder (DB snapshots): entries carry `id`, `name`,
  /// `size`, `modified` (ISO-8601 string or null). A missing backup folder
  /// is an empty list, never an error.
  Future<List<Map<String, dynamic>>> listBackups();

  /// Uploads an immutable object into backup/log/ (op-log segments and
  /// compaction snapshots). Returns the cloud id.
  Future<String?> uploadLogObject({
    required String name,
    required Uint8List bytes,
  });

  /// Lists backup/log/: entries carry `id`, `name`, `size`, `uploaded`
  /// (ISO-8601 provider timestamp — used ONLY as the compaction safety
  /// floor, never for conflict resolution). Missing folder = empty list.
  Future<List<Map<String, dynamic>>> listLogObjects();

  // Lookup
  Future<String?> findFileByName(String name);

  // The replacement for "canaryTest"
  Future<bool> checkIntegrity();

  /// Uploads a share blob to a publicly readable location and returns
  /// `(cloudId, downloadUrl)`. Used by ShareService to generate magic links.
  /// Implementations decide where the public location lives (Google: a
  /// "CipherNest Shares" folder in regular Drive; OneDrive: approot with
  /// createLink for anonymous access).
  Future<({String cloudId, String downloadUrl})> uploadPublicShare({
    required String filename,
    required Uint8List bytes,
  });

  /// Deletes a previously created share blob by its cloud id (revoke).
  Future<void> deletePublicShare(String cloudId);
}
