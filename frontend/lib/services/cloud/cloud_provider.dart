import 'dart:typed_data';

abstract class CloudProvider {
  String? get currentUser;

  // Auth
  Future<void> signIn();
  Future<void> signOut();
  Future<String?> restoreSession();

  // Core Ops
  /// Uploads a file. 
  /// Provide [fileBytes] for small files (images).
  /// Provide [fileStream] and [fileSize] for large files (videos).
  Future<String?> uploadEncryptedFile({
    required String filename,
    required bool isImage,
    Uint8List? fileBytes,
    Stream<List<int>>? fileStream,
    int? fileSize,
  });

  Future<Uint8List> downloadFile(String cloudId);
  Future<void> deleteFile(String cloudId);
  
  // Returns generic Maps so we don't depend on 'drive.File'
  Future<List<Map<String, dynamic>>> listCloudFiles(); 

  // The replacement for "canaryTest"
  Future<bool> checkIntegrity(); 
}