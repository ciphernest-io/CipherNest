import 'dart:typed_data';
import '../../src/models/file_model.dart';
import 'account_registry.dart';
import 'cloud_account.dart';
import 'cloud_provider.dart';
import 'google_drive_provider.dart';
import 'onedrive_provider.dart';

/// Facade over the active CloudProvider. The provider is selected based on
/// whichever account is currently active in [AccountRegistry].
/// When the active account changes, the provider is re-instantiated.
class CloudService {
  static final CloudService _instance = CloudService._internal();
  factory CloudService() => _instance;
  CloudService._internal();

  CloudProvider? _provider;
  String? _providerForAccountId;

  CloudProvider _getProvider() {
    final active = AccountRegistry().activeAccount;
    if (active == null) {
      throw Exception('No active cloud account. Sign in first.');
    }
    if (_providerForAccountId == active.id && _provider != null) {
      return _provider!;
    }
    _provider = _buildProvider(active);
    _providerForAccountId = active.id;
    return _provider!;
  }

  CloudProvider _buildProvider(CloudAccount account) {
    switch (account.providerType) {
      case CloudAccount.providerGoogle:
        return GoogleDriveProvider(account: account);
      case CloudAccount.providerOneDrive:
        return OneDriveProvider(account: account);
      default:
        throw Exception('Unsupported provider type: ${account.providerType}');
    }
  }

  /// Convenience getter for screens that need to display the active email.
  String? get currentEmail => AccountRegistry().activeAccount?.email;

  int get activeProviderType =>
      AccountRegistry().activeAccount?.providerType ?? 0;

  // --- AUTH METHODS ---
  Future<void> signOut() => _getProvider().signOut();
  Future<String?> restoreSession() => _getProvider().restoreSession();

  // --- INTEGRITY ---
  Future<bool> canaryTest() => _getProvider().checkIntegrity();

  // --- FILE OPS ---
  Future<String?> uploadEncryptedFile({
    required String filename,
    required CnestFileType type,
    String? originalName,
    Uint8List? bytes,
    Stream<List<int>>? stream,
    int? size,
  }) {
    return _getProvider().uploadEncryptedFile(
      filename: filename,
      type: type,
      originalName: originalName,
      fileBytes: bytes,
      fileStream: stream,
      fileSize: size,
    );
  }

  Future<Uint8List> downloadFile(String id) => _getProvider().downloadFile(id);
  Future<Uint8List> downloadRange(String id, int start, int endInclusive) =>
      _getProvider().downloadRange(id, start, endInclusive);
  Future<void> deleteFile(String id) => _getProvider().deleteFile(id);
  Future<List<Map<String, dynamic>>> listCloudFiles() =>
      _getProvider().listCloudFiles();

  // --- LOOKUP ---
  Future<String?> findFileByName(String name) =>
      _getProvider().findFileByName(name);

  // --- PUBLIC SHARE ---
  Future<({String cloudId, String downloadUrl})> uploadPublicShare({
    required String filename,
    required Uint8List bytes,
  }) =>
      _getProvider().uploadPublicShare(filename: filename, bytes: bytes);

  Future<void> deletePublicShare(String cloudId) =>
      _getProvider().deletePublicShare(cloudId);

  /// Resets the cached provider. Call this if the active account changes
  /// outside of AccountRegistry's normal flow (rare).
  void reset() {
    _provider = null;
    _providerForAccountId = null;
  }
}
