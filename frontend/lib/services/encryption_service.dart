import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import '../crypto/aes_gcm.dart';
import 'key_manager_service.dart';

class EncryptionService {
  static final AesGcmCipher _cipher = AesGcmCipher();
  
  static const int _chunkSize = 512 * 1024; // 512 KB source chunks
  static const int _nonceSize = 12;
  static const int _macSize = 16;
  static const int _chunkOverhead = _nonceSize + _macSize; 
  // The size of a chunk AFTER encryption
  static const int _encryptedChunkSize = _chunkSize + _chunkOverhead; 

  // --- EXISTING SINGLE-SHOT METHODS (Keep for Images) ---
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

  static Future<void> verifyKey(Uint8List partialData) async {
    final masterKey = KeyManagerService().masterKey;
    final headerSizeBytes = partialData.sublist(0, 4);
    final headerSize = ByteData.sublistView(headerSizeBytes).getUint32(0, Endian.big);
    if (partialData.length < 4 + headerSize) throw Exception('Data too short');
    final encryptedFileKey = partialData.sublist(4, 4 + headerSize);
    await _cipher.decrypt(encryptedFileKey, masterKey);
  }

  // --- STREAMING METHODS (For Video) ---

  static int calculateEncryptedSize(int originalSize) {
    const headerSize = 4 + 60; 
    final numChunks = (originalSize / _chunkSize).ceil();
    final totalOverhead = numChunks * _chunkOverhead;
    return headerSize + originalSize + totalOverhead;
  }

  static Stream<List<int>> encryptStream(Stream<List<int>> source) async* {
    final masterKey = KeyManagerService().masterKey;
    final algorithm = AesGcm.with256bits();
    final fileKey = await algorithm.newSecretKey();

    // 1. Header
    final fileKeyBytes = await fileKey.extractBytes();
    final encryptedFileKey = await _cipher.encrypt(Uint8List.fromList(fileKeyBytes), masterKey);
    final headerSize = ByteData(4)..setUint32(0, encryptedFileKey.length, Endian.big);
    yield headerSize.buffer.asUint8List() + encryptedFileKey;

    // 2. Body
    var buffer = <int>[];
    await for (final chunk in source) {
      buffer.addAll(chunk);
      while (buffer.length >= _chunkSize) {
        final rawChunk = Uint8List.fromList(buffer.sublist(0, _chunkSize));
        buffer = buffer.sublist(_chunkSize);
        final encryptedChunk = await _cipher.encrypt(rawChunk, fileKey);
        yield encryptedChunk;
      }
    }
    if (buffer.isNotEmpty) {
      final lastChunk = Uint8List.fromList(buffer);
      final encryptedLastChunk = await _cipher.encrypt(lastChunk, fileKey);
      yield encryptedLastChunk;
    }
  }

  /// NEW: Decrypts a stream (or list of bytes) chunk-by-chunk.
  /// This fixes the "Wrong MAC" error for large files.
  static Stream<List<int>> decryptToStream(Uint8List encryptedData) async* {
    final masterKey = KeyManagerService().masterKey;
    
    // 1. Parse Header
    final headerSizeBytes = encryptedData.sublist(0, 4);
    final headerSize = ByteData.sublistView(headerSizeBytes).getUint32(0, Endian.big);
    final encryptedFileKey = encryptedData.sublist(4, 4 + headerSize);
    
    // 2. Recover File Key
    final fileKeyBytes = await _cipher.decrypt(encryptedFileKey, masterKey);
    final fileKey = SecretKey(fileKeyBytes);

    // 3. Process Body Chunks
    int offset = 4 + headerSize;
    final totalLength = encryptedData.length;

    while (offset < totalLength) {
      // Determine chunk size (standard chunk or whatever is left at the end)
      final remaining = totalLength - offset;
      final currentChunkSize = remaining < _encryptedChunkSize ? remaining : _encryptedChunkSize;
      
      final chunk = encryptedData.sublist(offset, offset + currentChunkSize);
      
      // Decrypt this specific chunk
      final decryptedChunk = await _cipher.decrypt(chunk, fileKey);
      yield decryptedChunk;

      offset += currentChunkSize;
    }
  }
}