import 'dart:typed_data';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'encryption_service.dart';

class DriveService {
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      drive.DriveApi.driveAppdataScope,
      drive.DriveApi.driveFileScope,
    ],
  );

  static GoogleSignInAccount? _currentUser;

  /// Returns the signed-in email
  static String? get currentEmail => _currentUser?.email;

  static Future<drive.DriveApi> _getDriveApi() async {
    // Attempt silent sign-in if we don't have a user
    _currentUser ??= await _googleSignIn.signInSilently();
    // If silent failed, try interactive (only if we aren't in a background process)
    // For now, we assume the user is logged in.
    if (_currentUser == null) {
      throw Exception('User not signed in to Google Drive');
    }

    final authHeaders = await _currentUser!.authHeaders;
    final client = GoogleAuthClient(authHeaders);
    return drive.DriveApi(client);
  }

  /// Explicitly initializes the session (Used by HomeScreen)
  static Future<String?> restoreSession() async {
    try {
      _currentUser = await _googleSignIn.signInSilently();
      return _currentUser?.email;
    } catch (e) {
      return null;
    }
  }

  static Future<GoogleSignInAccount?> signIn() async {
    // This triggers the popup where the user selects their account
    _currentUser = await _googleSignIn.signIn();
    return _currentUser;
  }

  // --- CANARY TEST ---
  static Future<bool> canaryTest() async {
    try {
      // Ensure we are signed in
      if (_currentUser == null) {
         _currentUser = await _googleSignIn.signIn();
         if (_currentUser == null) return false;
      }
      
      final list = await listCloudFiles(limit: 1);
      if (list.isEmpty) return true; 

      final fileId = list.first.id!;
      final driveApi = await _getDriveApi();
      final drive.Media? response = await driveApi.files.get(
        fileId,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media?;
      
      if (response == null) return false;
      final List<int> chunk = await response.stream.first; 
      await EncryptionService.verifyKey(Uint8List.fromList(chunk));
      return true;
    } catch (e) {
      print("Canary Test Failed: $e");
      return false;
    }
  }

  // --- OPERATIONS ---

  static Future<String?> uploadEncryptedFile({
    required Uint8List encryptedBytes,
    required String filename,
    required bool isImage, // <--- NEW PARAMETER
  }) async {
    final driveApi = await _getDriveApi();

    final media = drive.Media(
      Stream.value(encryptedBytes),
      encryptedBytes.length,
    );

    final file = drive.File()
      ..name = filename
      ..parents = ['appDataFolder']
      ..mimeType = 'application/octet-stream'
      // CRITICAL FIX: Add metadata so we know it's an image later
      ..appProperties = {
        'type': isImage ? 'image' : 'document',
        'original_name': filename, 
      };

    final response = await driveApi.files.create(
      file,
      uploadMedia: media,
    );
    
    return response.id;
  }

  static Future<Uint8List> downloadFile(String fileId) async {
    final driveApi = await _getDriveApi();

    final metadata = await driveApi.files.get(
      fileId,
      $fields: 'size',
    ) as drive.File;

    final expectedSize = int.parse(metadata.size ?? '0');

    final drive.Media? response = await driveApi.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media?;

    if (response == null) throw Exception('File not found');

    final BytesBuilder builder = BytesBuilder(copy: false);
    await response.stream.forEach((chunk) {
      builder.add(chunk);
    });

    final data = builder.takeBytes();

    if (data.length != expectedSize) {
      throw Exception('Download incomplete! Try again.');
    }

    return data;
  }

  static Future<List<drive.File>> listCloudFiles({int limit = 1000}) async {
    final driveApi = await _getDriveApi();
    
    final fileList = await driveApi.files.list(
      q: "trashed = false and name contains '.cnest'",
      spaces: 'appDataFolder',
      // Fetch appProperties to know the file type
      $fields: "files(id, name, size, createdTime, appProperties)", 
      pageSize: limit,
    );

    return fileList.files ?? [];
  }

  static Future<void> deleteFile(String fileId) async {
    final driveApi = await _getDriveApi();
    await driveApi.files.delete(fileId);
  }

  static Future<void> signOut() async {
    await _googleSignIn.disconnect(); // Disconnects and revokes current token
    _currentUser = null;
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