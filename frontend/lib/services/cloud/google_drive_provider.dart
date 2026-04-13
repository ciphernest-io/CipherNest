import 'dart:typed_data';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import '../../services/encryption_service.dart';
import 'cloud_provider.dart';

class GoogleDriveProvider implements CloudProvider {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      drive.DriveApi.driveAppdataScope,
      drive.DriveApi.driveFileScope,
    ],
  );
  
  GoogleSignInAccount? _currentUserAccount;
  Map<String, String>? _authHeaders;

  @override
  String? get currentUser => _currentUserAccount?.email;

  Future<drive.DriveApi> _getApi() async {
    _authHeaders ??= await _currentUserAccount?.authHeaders;
    if (_authHeaders == null) {
       await restoreSession();
       if (_authHeaders == null) throw Exception("Not authenticated");
    }
    final client = GoogleAuthClient(_authHeaders!);
    return drive.DriveApi(client);
  }

  @override
  Future<void> signIn() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account != null) {
        _currentUserAccount = account;
        _authHeaders = await account.authHeaders;
      }
    } catch (e) {
      debugPrint("Sign In Error: $e");
      rethrow;
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
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        _currentUserAccount = account;
        _authHeaders = await account.authHeaders;
        return account.email;
      }
    } catch (e) {
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

    // LOGIC: Choose between RAM (bytes) or STREAM (video)
    if (fileBytes != null) {
      media = drive.Media(
        Future.value(fileBytes).asStream().asBroadcastStream(),
        fileBytes.length,
      );
    } else if (fileStream != null && fileSize != null) {
      media = drive.Media(fileStream, fileSize);
    } else {
      throw Exception("No data provided for upload");
    }

    final result = await api.files.create(
      driveFile,
      uploadMedia: media,
    );
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
    }).toList() ?? [];
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
      if (_currentUserAccount == null) await signIn();
      
      final list = await listCloudFiles();
      if (list.isEmpty) return true;

      final fileId = list.first['id'];
      final api = await _getApi();
      final media = await api.files.get(
        fileId, 
        downloadOptions: drive.DownloadOptions.fullMedia
      ) as drive.Media;
      
      final chunk = await media.stream.first;
      await EncryptionService.verifyKey(Uint8List.fromList(chunk));
      return true;
    } catch (e) {
      debugPrint("Integrity Check Failed: $e");
      return false;
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