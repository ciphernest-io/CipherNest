import 'dart:typed_data';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../../services/database_backup_service.dart';
import '../../services/encryption_service.dart';
import '../../src/models/file_model.dart';
import 'cloud_account.dart';
import 'cloud_provider.dart';
import 'drive_layout.dart';
import 'sealed_metadata.dart';

class GoogleDriveProvider implements CloudProvider {
  @override
  CloudAccount account;

  GoogleDriveProvider({required this.account});

  /// ONLY `drive.file`. This is a non-sensitive scope (no CASA / restricted-
  /// scope assessment) and — critically — it limits the app to files IT
  /// created. CipherNest cannot read the rest of the user's Drive, enforced
  /// by Google, not by our promise. The vault lives in a visible
  /// `My Drive/CipherNest/` tree (data portability, no lock-in), which
  /// `drive.file` fully supports for app-created files.
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      drive.DriveApi.driveFileScope,
    ],
  );

  GoogleSignInAccount? _currentUserAccount;
  Map<String, String>? _authHeaders;

  @override
  String? get currentUser => _currentUserAccount?.email ?? account.email;

  /// Static helper for the cloud-selection screen to add a brand-new Google
  /// account. Returns a CloudAccount ready to register, or null if the user
  /// cancels the sign-in flow.
  static Future<CloudAccount?> signInNewAccount() async {
    try {
      // Disconnect any prior sign-in so the account picker is shown
      await _googleSignIn.signOut();
      final acct = await _googleSignIn.signIn();
      if (acct == null) return null;
      // Force the plugin to materialise auth headers now, so the first
      // signInSilently() that fires from _getApi() right after this returns
      // hits a warm cache. Without this, Google's silent-sign-in can return
      // null or a stale token on the first call after signIn(), which
      // surfaces up the stack as a spurious "wrong phrase" dialog on the
      // canary check.
      await acct.authHeaders;
      return CloudAccount(
        providerType: CloudAccount.providerGoogle,
        email: acct.email,
      );
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      rethrow;
    }
  }

  Future<drive.DriveApi> _getApi() async {
    if (_authHeaders == null) {
      await restoreSession();
      if (_authHeaders == null) throw Exception('Not authenticated');
    }
    final client = GoogleAuthClient(_authHeaders!);
    return drive.DriveApi(client);
  }

  @override
  Future<void> signIn() async {
    // Re-validate this account by silently signing in
    final email = await restoreSession();
    if (email == null) {
      // Fall back to interactive sign-in if silent fails
      final acct = await _googleSignIn.signIn();
      if (acct != null) {
        _currentUserAccount = acct;
        _authHeaders = await acct.authHeaders;
      }
    }
  }

  @override
  Future<void> signOut() async {
    await _googleSignIn.disconnect();
    _currentUserAccount = null;
    _authHeaders = null;
  }

  @override
  Future<String?> restoreSession() async {
    try {
      final acct = await _googleSignIn.signInSilently();
      if (acct != null) {
        _currentUserAccount = acct;
        _authHeaders = await acct.authHeaders;
        return acct.email;
      }
    } catch (_) {
      // Silent fail allowed
    }
    return null;
  }

  @override
  Future<String?> uploadEncryptedFile({
    required String filename,
    required CnestFileType type,
    String? originalName,
    Uint8List? fileBytes,
    Stream<List<int>>? fileStream,
    int? fileSize,
  }) async {
    final api = await _getApi();
    final tree = await _ensureTree();
    // DB snapshots (per-device `db_backup_<id>.cnest` or the legacy fixed
    // name) go to backup/; everything else (vault files + thumbs) to vault/.
    final parentId = DatabaseBackupService.isBackupFile(filename)
        ? tree.backupId
        : tree.vaultId;

    // Filename + type travel ONLY as an HPKE-sealed blob, chunked across
    // appProperties (m0..mN) to fit Drive's 124-byte per-property cap.
    // Sealing is public-key-only, so locked background sync still works.
    // The DB backup keeps its fixed name and carries no metadata.
    Map<String, String>? props;
    if (parentId == tree.vaultId) {
      final sealed = await SealedMetadata.seal(
        name: originalName ?? filename,
        type: type,
      );
      if (sealed != null) props = SealedMetadata.chunkForAppProperties(sealed);
    }

    final driveFile = drive.File()
      ..name = filename
      ..parents = [parentId]
      ..mimeType = 'application/octet-stream'
      ..appProperties = props;

    drive.Media? media;

    if (fileBytes != null) {
      media = drive.Media(
        Future.value(fileBytes).asStream().asBroadcastStream(),
        fileBytes.length,
      );
    } else if (fileStream != null && fileSize != null) {
      media = drive.Media(fileStream, fileSize);
    } else {
      throw Exception('No data provided for upload');
    }

    final result = await api.files.create(driveFile, uploadMedia: media);
    return result.id;
  }

  @override
  Future<Uint8List> downloadFile(String cloudId) async {
    final api = await _getApi();

    final metadata = await api.files.get(cloudId, $fields: 'size') as drive.File;
    final expectedSize = int.parse(metadata.size ?? '0');

    final media = await api.files.get(
      cloudId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final BytesBuilder builder = BytesBuilder(copy: false);
    await media.stream.forEach((chunk) {
      builder.add(chunk);
    });

    final data = builder.takeBytes();
    if (data.length != expectedSize) throw Exception('Download incomplete');

    return data;
  }

  @override
  Future<Uint8List> downloadRange(String cloudId, int start, int endInclusive) async {
    // Force auth refresh
    await _getApi();
    final headers = Map<String, String>.from(_authHeaders!);
    headers['Range'] = 'bytes=$start-$endInclusive';
    final url = 'https://www.googleapis.com/drive/v3/files/$cloudId?alt=media';
    final resp = await http.get(Uri.parse(url), headers: headers);
    if (resp.statusCode != 206 && resp.statusCode != 200) {
      throw Exception('Google range download failed: ${resp.statusCode}');
    }
    return resp.bodyBytes;
  }

  @override
  Future<void> deleteFile(String cloudId) async {
    final api = await _getApi();
    await api.files.delete(cloudId);
  }

  @override
  Future<List<Map<String, dynamic>>> listCloudFiles() async {
    final api = await _getApi();

    // Drive caps a page at 1000 entries, and a vault of ~500 photos already
    // overflows that (every photo is a file + thumbnail pair). Files dropped
    // here would be treated as remote deletions by the reconcile diff, so
    // every page must be walked.
    final tree = await _ensureTree();
    final out = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final fileList = await api.files.list(
        // Only vault/ blobs — backup/ and shares/ live in sibling folders,
        // so they never pollute the reconcile diff.
        q: "trashed = false and '${tree.vaultId}' in parents "
            "and name contains '.cnest'",
        $fields:
            'nextPageToken, files(id, name, size, createdTime, appProperties)',
        pageSize: 1000,
        pageToken: pageToken,
      );
      for (final f in fileList.files ?? const <drive.File>[]) {
        // Legacy plaintext props are read during the transition window and
        // normalized so a migration-cleared '' reads as absent.
        String? legacy(String key) {
          final v = f.appProperties?[key];
          return (v == null || v.isEmpty) ? null : v;
        }

        out.add({
          'id': f.id,
          'name': f.name,
          'cloud_name': f.name,
          'size': f.size,
          'created': f.createdTime?.toIso8601String(),
          'sealed_meta': SealedMetadata.fromAppProperties(f.appProperties),
          'type': legacy('type'),
          'original_name': legacy('original_name'),
        });
      }
      pageToken = fileList.nextPageToken;
    } while (pageToken != null);

    return out;
  }

  @override
  Future<List<Map<String, dynamic>>> listBackups() async {
    final api = await _getApi();
    final tree = await _ensureTree();
    final out = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final fileList = await api.files.list(
        q: "trashed = false and '${tree.backupId}' in parents",
        $fields: 'nextPageToken, files(id, name, size, modifiedTime)',
        pageSize: 100,
        pageToken: pageToken,
      );
      for (final f in fileList.files ?? const <drive.File>[]) {
        out.add({
          'id': f.id,
          'name': f.name,
          'size': f.size,
          'modified': f.modifiedTime?.toIso8601String(),
        });
      }
      pageToken = fileList.nextPageToken;
    } while (pageToken != null);
    return out;
  }

  String? _cachedLogFolderId;

  Future<String> _ensureLogFolder() async {
    final cached = _cachedLogFolderId;
    if (cached != null) return cached;
    final api = await _getApi();
    final tree = await _ensureTree();
    final id =
        await _ensureFolder(api, DriveLayout.logFolder, tree.backupId);
    _cachedLogFolderId = id;
    return id;
  }

  @override
  Future<String?> uploadLogObject({
    required String name,
    required Uint8List bytes,
  }) async {
    final api = await _getApi();
    final logId = await _ensureLogFolder();
    final driveFile = drive.File()
      ..name = name
      ..parents = [logId]
      ..mimeType = 'application/octet-stream';
    final media = drive.Media(
      Future.value(bytes).asStream().asBroadcastStream(),
      bytes.length,
    );
    final result = await api.files.create(driveFile, uploadMedia: media);
    return result.id;
  }

  @override
  Future<List<Map<String, dynamic>>> listLogObjects() async {
    final api = await _getApi();
    final logId = await _ensureLogFolder();
    final out = <Map<String, dynamic>>[];
    String? pageToken;
    do {
      final fileList = await api.files.list(
        q: "trashed = false and '$logId' in parents",
        $fields: 'nextPageToken, files(id, name, size, createdTime)',
        pageSize: 1000,
        pageToken: pageToken,
      );
      for (final f in fileList.files ?? const <drive.File>[]) {
        out.add({
          'id': f.id,
          'name': f.name,
          'size': f.size,
          'uploaded': f.createdTime?.toIso8601String(),
        });
      }
      pageToken = fileList.nextPageToken;
    } while (pageToken != null);
    return out;
  }

  @override
  Future<void> sealLegacyMetadata({
    required String cloudId,
    required String cloudName,
    required String sealedMeta,
  }) async {
    final api = await _getApi();
    // Metadata-only files.update — the blob content is never re-uploaded.
    // The googleapis map can't carry nulls, so the legacy plaintext keys are
    // overwritten with '' (cleared); listCloudFiles normalizes '' to absent.
    final patch = drive.File()
      ..appProperties = {
        ...SealedMetadata.chunkForAppProperties(sealedMeta),
        'original_name': '',
        'type': '',
      };
    await api.files.update(patch, cloudId);
  }

  @override
  Future<String?> findFileByName(String name) async {
    final api = await _getApi();
    // drive.file limits results to app-created files, and the names we look
    // up (the DB backup) are unique, so an unscoped name match is safe.
    final fileList = await api.files.list(
      q: "trashed = false and name = '$name'",
      $fields: 'files(id)',
      pageSize: 1,
    );
    if (fileList.files != null && fileList.files!.isNotEmpty) {
      return fileList.files!.first.id;
    }
    return null;
  }

  @override
  Future<bool> checkIntegrity() async {
    // No outer try/catch. Only the actual crypto step returns `false` (the
    // real "wrong key" signal). Network / HTTP / auth / stream exceptions
    // propagate so the caller can distinguish transient failures from a
    // genuine wrong-phrase and retry as appropriate.
    if (_authHeaders == null) {
      final email = await restoreSession();
      if (email == null) {
        throw Exception('Silent sign-in returned no session');
      }
    }

    final list = await listCloudFiles();
    if (list.isEmpty) return true;

    final fileId = list.first['id'];
    final api = await _getApi();
    final media = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;
    final chunk = await media.stream.first;

    try {
      await EncryptionService.verifyKey(Uint8List.fromList(chunk));
      return true;
    } catch (e) {
      debugPrint('Canary crypto fail (wrong key for this vault): $e');
      return false;
    }
  }

  // ---- VISIBLE VAULT FOLDER TREE (My Drive/CipherNest/...) ----

  _DriveTree? _cachedTree;

  /// Ensures `CipherNest/{vault,backup,shares}` exists (creating what's
  /// missing) and drops the plaintext README the first time. Cached per
  /// provider instance. Idempotent and safe to call before every op.
  Future<_DriveTree> _ensureTree() async {
    final cached = _cachedTree;
    if (cached != null) return cached;
    final api = await _getApi();
    final rootId = await _ensureFolder(api, DriveLayout.rootFolder, 'root');
    final vaultId = await _ensureFolder(api, DriveLayout.vaultFolder, rootId);
    final backupId = await _ensureFolder(api, DriveLayout.backupFolder, rootId);
    final sharesId = await _ensureFolder(api, DriveLayout.sharesFolder, rootId);
    await _ensureReadme(api, rootId);
    final tree = _DriveTree(
      rootId: rootId,
      vaultId: vaultId,
      backupId: backupId,
      sharesId: sharesId,
    );
    _cachedTree = tree;
    return tree;
  }

  Future<String> _ensureFolder(
    drive.DriveApi api,
    String name,
    String parentId,
  ) async {
    final lookup = await api.files.list(
      q: "mimeType = 'application/vnd.google-apps.folder' "
          "and name = '$name' and trashed = false "
          "and '$parentId' in parents",
      $fields: 'files(id)',
      pageSize: 1,
    );
    if (lookup.files != null && lookup.files!.isNotEmpty) {
      return lookup.files!.first.id!;
    }
    final created = await api.files.create(
      drive.File()
        ..name = name
        ..mimeType = 'application/vnd.google-apps.folder'
        ..parents = [parentId],
    );
    return created.id!;
  }

  Future<void> _ensureReadme(drive.DriveApi api, String rootId) async {
    final existing = await api.files.list(
      q: "name = '${DriveLayout.readmeName}' and trashed = false "
          "and '$rootId' in parents",
      $fields: 'files(id)',
      pageSize: 1,
    );
    if (existing.files != null && existing.files!.isNotEmpty) return;
    final bytes = Uint8List.fromList(DriveLayout.readmeContents.codeUnits);
    await api.files.create(
      drive.File()
        ..name = DriveLayout.readmeName
        ..parents = [rootId]
        ..mimeType = 'text/plain',
      uploadMedia: drive.Media(
        Future.value(bytes).asStream().asBroadcastStream(),
        bytes.length,
      ),
    );
  }

  // ---- PUBLIC SHARE (CipherNest/shares/, anyone-with-link) ----

  @override
  Future<({String cloudId, String downloadUrl})> uploadPublicShare({
    required String filename,
    required Uint8List bytes,
  }) async {
    final api = await _getApi();
    final folderId = (await _ensureTree()).sharesId;

    final driveFile = drive.File()
      ..name = filename
      ..parents = [folderId]
      ..mimeType = 'application/octet-stream';

    final media = drive.Media(
      Future.value(bytes).asStream().asBroadcastStream(),
      bytes.length,
    );

    final created = await api.files.create(driveFile, uploadMedia: media);
    final fileId = created.id!;

    // Make it readable by anyone with the link
    await api.permissions.create(
      drive.Permission()
        ..type = 'anyone'
        ..role = 'reader',
      fileId,
    );

    // Fetch Drive's canonical anonymous download URL. `webContentLink` is
    // populated once the file has anyone/reader permission and works for
    // truly-anonymous recipients (no Google session required). The
    // previous hand-constructed URL used `authuser=0`, which asked Drive
    // to "use the first Google account signed in on this browser"; for
    // anonymous recipients that resolved to a sign-in HTML page instead
    // of the encrypted bytes, breaking the web viewer.
    final withLink = await api.files.get(
      fileId,
      $fields: 'webContentLink',
    ) as drive.File;
    final downloadUrl = withLink.webContentLink ??
        // Fallback if Drive doesn't populate the field (rare edge case).
        // This form works for small files anonymously; large files may
        // require the confirmation-token dance which we don't do here.
        'https://drive.google.com/uc?export=download&id=$fileId';
    return (cloudId: fileId, downloadUrl: downloadUrl);
  }

  @override
  Future<void> deletePublicShare(String cloudId) async {
    final api = await _getApi();
    try {
      await api.files.delete(cloudId);
    } catch (e) {
      debugPrint('deletePublicShare error: $e');
    }
  }
}

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();
  GoogleAuthClient(this._headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

/// Cached folder ids for the visible `CipherNest/` tree.
class _DriveTree {
  final String rootId;
  final String vaultId;
  final String backupId;
  final String sharesId;
  const _DriveTree({
    required this.rootId,
    required this.vaultId,
    required this.backupId,
    required this.sharesId,
  });
}
