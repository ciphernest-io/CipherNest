import 'dart:math';
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

  /// The size of the on-disk header: 4-byte length prefix + encrypted file key.
  /// Encrypted file key = 12 (nonce) + 32 (AES-256 key bytes) + 16 (MAC) = 60 bytes.
  static const int headerSize = 4 + 60;

  /// Source plaintext chunk size (exposed for streaming server math).
  static const int plaintextChunkSize = _chunkSize;

  /// Encrypted chunk size on disk = plaintext + 12-byte nonce + 16-byte MAC.
  /// Last chunk may be smaller (only the plaintext portion shrinks).
  static const int encryptedChunkSize = _encryptedChunkSize;

  static int calculateEncryptedSize(int originalSize) {
    final numChunks = (originalSize / _chunkSize).ceil();
    final totalOverhead = numChunks * _chunkOverhead;
    return headerSize + originalSize + totalOverhead;
  }

  /// Decrypts the encrypted file key from the on-disk header bytes.
  /// [headerBytes] must be at least [headerSize] long.
  /// Returns the file's per-file SecretKey for chunk decryption.
  static Future<SecretKey> decryptFileKeyFromHeader(Uint8List headerBytes) async {
    final masterKey = KeyManagerService().masterKey;
    final headerLen = ByteData.sublistView(headerBytes.sublist(0, 4))
        .getUint32(0, Endian.big);
    if (headerBytes.length < 4 + headerLen) {
      throw Exception('Header bytes too short');
    }
    final encryptedFileKey = headerBytes.sublist(4, 4 + headerLen);
    final fileKeyBytes = await _cipher.decrypt(encryptedFileKey, masterKey);
    return SecretKey(fileKeyBytes);
  }

  // ---------------------------------------------------------------------------
  // SHARING HELPERS
  // ---------------------------------------------------------------------------

  /// Generates a random 256-bit share key. Caller is responsible for sending
  /// it to the recipient out-of-band (URL fragment, password derivation).
  static Future<SecretKey> generateShareKey() async {
    final algorithm = AesGcm.with256bits();
    return algorithm.newSecretKey();
  }

  /// Re-wraps the original file's key with [shareKey] so the share blob can
  /// reuse the same encrypted body with only a different header.
  ///
  /// Returns the new 64-byte header bytes: 4-byte length prefix + encrypted
  /// file key (encrypted with [shareKey] instead of master key).
  static Future<Uint8List> wrapFileKeyForShare(
    SecretKey fileKey,
    SecretKey shareKey,
  ) async {
    final fileKeyBytes = await fileKey.extractBytes();
    final wrapped = await _cipher.encrypt(
      Uint8List.fromList(fileKeyBytes),
      shareKey,
    );
    final lenHeader = ByteData(4)..setUint32(0, wrapped.length, Endian.big);
    return Uint8List.fromList(lenHeader.buffer.asUint8List() + wrapped);
  }

  /// Derives a 256-bit symmetric key from a user-chosen password.
  /// Uses the same Argon2id parameters as the master-key flow for consistency.
  /// Caller must persist [salt] alongside the share blob (recipient will need
  /// it to derive the same key from the same password).
  static Future<SecretKey> derivePasswordKey(
    String password,
    Uint8List salt,
  ) async {
    final argon2 = Argon2id(
      parallelism: 1,
      memory: 65536, // 64 MB
      iterations: 2,
      hashLength: 32,
    );
    return argon2.deriveKeyFromPassword(password: password, nonce: salt);
  }

  /// Generates a fresh 16-byte random salt for password-protected shares.
  static Uint8List generatePasswordSalt() {
    final rnd = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(16, (_) => rnd.nextInt(256)),
    );
  }

  // ---------------------------------------------------------------------------
  // RANGE DECRYPTION (used by VideoStreamingServer)
  // ---------------------------------------------------------------------------

  /// Decrypts a contiguous run of encrypted chunks given an already-recovered
  /// [fileKey]. [encryptedChunks] is the raw byte slice covering N full chunks
  /// followed by an optional final partial chunk.
  ///
  /// [chunkCount]: how many chunks are present in the slice.
  /// [lastChunkEncryptedSize]: if the last chunk is shorter than the standard
  ///   524316 bytes (i.e. it's the file's tail), pass its actual encrypted
  ///   size here. Otherwise pass null (all chunks are full-sized).
  ///
  /// Returns the concatenated plaintext for the chunks.
  static Future<Uint8List> decryptChunkRange(
    Uint8List encryptedChunks,
    SecretKey fileKey,
    int chunkCount, {
    int? lastChunkEncryptedSize,
  }) async {
    final out = BytesBuilder(copy: false);
    int offset = 0;
    for (int i = 0; i < chunkCount; i++) {
      final isLast = i == chunkCount - 1;
      final size = (isLast && lastChunkEncryptedSize != null)
          ? lastChunkEncryptedSize
          : _encryptedChunkSize;
      if (offset + size > encryptedChunks.length) {
        throw Exception('Chunk slice underflow at chunk $i');
      }
      final chunk = encryptedChunks.sublist(offset, offset + size);
      final plain = await _cipher.decrypt(chunk, fileKey);
      out.add(plain);
      offset += size;
    }
    return out.takeBytes();
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