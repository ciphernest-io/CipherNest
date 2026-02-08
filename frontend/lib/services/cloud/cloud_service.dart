import 'dart:typed_data';
import 'cloud_provider.dart';
import 'google_drive_provider.dart';

class CloudService {
  static final CloudService _instance = CloudService._internal();
  factory CloudService() => _instance;
  CloudService._internal();

  final CloudProvider _provider = GoogleDriveProvider();

  // --- IDENTITY ---
  String? get currentEmail => _provider.currentUser;

  // --- AUTH METHODS (Replacing DriveService auth) ---
  Future<void> signIn() => _provider.signIn();
  Future<void> signOut() => _provider.signOut();
  Future<String?> restoreSession() => _provider.restoreSession();

  // --- INTEGRITY (Replacing DriveService.canaryTest) ---
  Future<bool> canaryTest() => _provider.checkIntegrity();

  // --- FILE OPS (Replacing DriveService ops) ---
  Future<String?> uploadEncryptedFile({
    required String filename,
    required bool isImage,
    required Uint8List bytes,
  }) {
    return _provider.uploadEncryptedFile(
      filename: filename,
      isImage: isImage,
      fileBytes: bytes,
    );
  }

  Future<Uint8List> downloadFile(String id) => _provider.downloadFile(id);
  Future<void> deleteFile(String id) => _provider.deleteFile(id);
  Future<List<Map<String, dynamic>>> listCloudFiles() =>
      _provider.listCloudFiles();
}
