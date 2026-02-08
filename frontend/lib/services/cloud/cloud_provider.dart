import 'dart:typed_data';

abstract class CloudProvider {
  String? get currentUser;

  // Auth
  Future<void> signIn();
  Future<void> signOut();
  Future<String?> restoreSession();

  // Core Ops
  Future<String?> uploadEncryptedFile({
    required String filename,
    required bool isImage,
    required Uint8List fileBytes,
  });

  Future<Uint8List> downloadFile(String cloudId);
  Future<void> deleteFile(String cloudId);
  
  // Returns generic Maps so we don't depend on 'drive.File'
  Future<List<Map<String, dynamic>>> listCloudFiles(); 

  // The replacement for "canaryTest"
  Future<bool> checkIntegrity(); 
}