import 'dart:typed_data';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../../services/encryption_service.dart';
import 'cloud_account.dart';
import 'cloud_provider.dart';

class GoogleDriveProvider implements CloudProvider {
  @override
  CloudAccount account;

  GoogleDriveProvider({required this.account});

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      drive.DriveApi.driveAppdataScope,
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
    required bool isImage,
    String? originalName,
    Uint8List? fileBytes,
    Stream<List<int>>? fileStream,
    int? fileSize,
  }) async {
    final api = await _getApi();

    final driveFile = drive.File()
      ..name = filename
      ..parents = ['appDataFolder']
      ..mimeType = 'application/octet-stream'
      ..appProperties = {
        'type': isImage ? 'image' : 'document',
        'original_name': originalName ?? filename,
      };

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

    final fileList = await api.files.list(
      q: "trashed = false and name contains '.cnest'",
      spaces: 'appDataFolder',
      $fields: 'files(id, name, size, createdTime, appProperties)',
      pageSize: 1000,
    );

    return fileList.files?.map((f) => {
          'id': f.id,
          'name': f.name,
          'size': f.size,
          'created': f.createdTime?.toIso8601String(),
          'type': f.appProperties?['type'],
          'original_name': f.appProperties?['original_name'],
        }).toList() ??
        [];
  }

  @override
  Future<String?> findFileByName(String name) async {
    final api = await _getApi();
    final fileList = await api.files.list(
      q: "trashed = false and name = '$name'",
      spaces: 'appDataFolder',
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
    try {
      if (_authHeaders == null) {
        final email = await restoreSession();
        if (email == null) return false;
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
      await EncryptionService.verifyKey(Uint8List.fromList(chunk));
      return true;
    } catch (e) {
      debugPrint('Integrity Check Failed: $e');
      return false;
    }
  }

  // ---- PUBLIC SHARE (uploads to user's regular Drive, anyone-with-link) ----

  static const String _sharesFolderName = 'CipherNest Shares';
  String? _cachedSharesFolderId;

  Future<String> _ensureSharesFolder() async {
    if (_cachedSharesFolderId != null) return _cachedSharesFolderId!;
    final api = await _getApi();
    // Look for existing folder
    final lookup = await api.files.list(
      q: "mimeType = 'application/vnd.google-apps.folder' "
          "and name = '$_sharesFolderName' "
          "and trashed = false "
          "and 'root' in parents",
      $fields: 'files(id)',
      pageSize: 1,
    );
    if (lookup.files != null && lookup.files!.isNotEmpty) {
      _cachedSharesFolderId = lookup.files!.first.id;
      return _cachedSharesFolderId!;
    }
    // Create it
    final folderMeta = drive.File()
      ..name = _sharesFolderName
      ..mimeType = 'application/vnd.google-apps.folder'
      ..parents = ['root'];
    final created = await api.files.create(folderMeta);
    _cachedSharesFolderId = created.id!;
    return _cachedSharesFolderId!;
  }

  @override
  Future<({String cloudId, String downloadUrl})> uploadPublicShare({
    required String filename,
    required Uint8List bytes,
  }) async {
    final api = await _getApi();
    final folderId = await _ensureSharesFolder();

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

    // Public, no-auth URL pattern. Works without API key for anyone with link.
    // drive.usercontent.google.com is Google's direct-content host. Going
    // through it with `confirm=t` skips the "Drive can't scan this file"
    // HTML interstitial that the older drive.google.com/uc URL serves for
    // anonymous downloads of binary blobs.
    final downloadUrl =
        'https://drive.usercontent.google.com/download?id=$fileId&export=download&authuser=0&confirm=t';
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
