import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../crypto/aes_gcm.dart';
import 'key_manager_service.dart';

class EncryptionService {
  static final AesGcmCipher _cipher = AesGcmCipher();

  // ... (Keep encryptFile exactly as it was) ...
  static Future<Uint8List> encryptFile(Uint8List fileBytes) async {
    final masterKey = KeyManagerService().masterKey;
    final algorithm = AesGcm.with256bits();
    final fileKey = await algorithm.newSecretKey();
    final encryptedContent = await _cipher.encrypt(fileBytes, fileKey);
    final fileKeyBytes = await fileKey.extractBytes();
    final encryptedFileKey = await _cipher.encrypt(Uint8List.fromList(fileKeyBytes), masterKey);
    final headerSize = ByteData(4)..setUint32(0, encryptedFileKey.length, Endian.big);
    return Uint8List.fromList(headerSize.buffer.asUint8List() + encryptedFileKey + encryptedContent);
  }

  // ... (Keep decryptFile exactly as it was) ...
  static Future<Uint8List> decryptFile(Uint8List encryptedBundle) async {
    final masterKey = KeyManagerService().masterKey;
    final headerSizeBytes = encryptedBundle.sublist(0, 4);
    final headerSize = ByteData.sublistView(headerSizeBytes).getUint32(0, Endian.big);
    final encryptedFileKey = encryptedBundle.sublist(4, 4 + headerSize);
    final encryptedContent = encryptedBundle.sublist(4 + headerSize);
    final fileKeyBytes = await _cipher.decrypt(encryptedFileKey, masterKey);
    final fileKey = SecretKey(fileKeyBytes);
    return await _cipher.decrypt(encryptedContent, fileKey);
  }

  /// NEW: Used by Canary Test. Tries to decrypt header.
  /// If this fails, it throws an error (meaning WRONG Master Key).
  static Future<void> verifyKey(Uint8List partialData) async {
    final masterKey = KeyManagerService().masterKey;
    
    // Read header size
    final headerSizeBytes = partialData.sublist(0, 4);
    final headerSize = ByteData.sublistView(headerSizeBytes).getUint32(0, Endian.big);

    // Extract encrypted key blob
    // Note: We need to ensure partialData has enough bytes
    if (partialData.length < 4 + headerSize) throw Exception('Data too short for verification');
    
    final encryptedFileKey = partialData.sublist(4, 4 + headerSize);
    
    // Attempt decrypt. If MK is wrong, this throws MAC validation error.
    await _cipher.decrypt(encryptedFileKey, masterKey);
  }
}