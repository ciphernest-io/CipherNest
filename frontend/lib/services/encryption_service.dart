import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../crypto/aes_gcm.dart';
import '../crypto/hpke.dart';
import 'key_manager_service.dart';

/// CipherNest file format **v1**. One format, no legacy path.
///
/// ## Header (81 bytes)
/// ```
/// [1]  version = 0x01
/// [32] enc          — HPKE encapsulated ephemeral X25519 public key
/// [48] sealed key   — HPKE seal of the 32-byte AES-256 file key
/// ```
/// The file key is sealed to the vault's X25519 **public** key via HPKE
/// (RFC 9180, see [Hpke]). Sealing needs no secret material, so background
/// sync can encrypt while the vault is locked; opening needs the vault
/// private key (an unlocked vault).
///
/// ## Body
/// ```
/// [16] content_id       — random, plaintext, survives share re-wrap
/// [4]  total_chunks (BE)
/// chunk i (stride 524316, last shorter):
///   [12] nonce = BE96(i)   [ciphertext ≤524288]   [16 tag]
///   AAD = content_id ‖ BE32(i) ‖ BE32(total_chunks)
/// ```
/// Every chunk is AES-256-GCM with a counter nonce and AAD that binds it to
/// its content id, index, and total count. This makes reorder, truncation,
/// duplication, and cross-blob splicing all fail authentication — integrity,
/// not just confidentiality.
///
/// The body ciphertext is identical in a vault blob and a share blob; sharing
/// only swaps the header (file key re-wrapped under a symmetric share key),
/// so [decryptBody] serves both.
class EncryptionService {
  static final AesGcmCipher _cipher = AesGcmCipher();

  static const int _chunkSize = 512 * 1024; // 524288 plaintext per chunk
  static const int _nonceSize = 12;
  static const int _macSize = 16;
  static const int _chunkOverhead = _nonceSize + _macSize; // 28
  static const int _encryptedChunkSize = _chunkSize + _chunkOverhead; // 524316

  /// Current format version byte. Every CipherNest blob starts with this.
  static const int formatVersion = 0x01;

  /// On-disk header length: version(1) + HPKE enc(32) + sealed key(48).
  static const int headerSize = 1 + Hpke.nEnc + (Hpke.nK * 2 + Hpke.nT);
  // = 1 + 32 + (32 wrapped key + 16 tag) = 81.

  /// Body preamble: content_id(16) + total_chunks(4).
  static const int bodyPreambleSize = 16 + 4; // 20

  /// Source plaintext chunk size (exposed for the streaming server).
  static const int plaintextChunkSize = _chunkSize;

  /// Encrypted chunk size on disk. Last chunk may be smaller.
  static const int encryptedChunkSize = _encryptedChunkSize;

  static int calculateEncryptedSize(int originalSize) {
    final numChunks = originalSize == 0 ? 0 : (originalSize / _chunkSize).ceil();
    return headerSize +
        bodyPreambleSize +
        originalSize +
        numChunks * _chunkOverhead;
  }

  // ---------------------------------------------------------------------------
  // Header (HPKE seal / open)
  // ---------------------------------------------------------------------------

  static Future<Uint8List> _buildHeader(Uint8List fileKeyBytes) async {
    final sealed =
        await Hpke.sealFileKey(KeyManagerService().vaultPublicKey, fileKeyBytes);
    final out = BytesBuilder(copy: false);
    out.addByte(formatVersion);
    out.add(sealed.enc); // 32
    out.add(sealed.ct); // 48
    return out.toBytes();
  }

  /// Recovers the per-file key from the on-disk header. Requires an unlocked
  /// vault (needs the X25519 private key). [headerBytes] must be at least
  /// [headerSize] long.
  static Future<SecretKey> decryptFileKeyFromHeader(
    Uint8List headerBytes,
  ) async {
    if (headerBytes.length < headerSize) {
      throw Exception('Header bytes too short');
    }
    if (headerBytes[0] != formatVersion) {
      throw Exception('Unsupported format version ${headerBytes[0]}');
    }
    final enc = headerBytes.sublist(1, 1 + Hpke.nEnc);
    final ct = headerBytes.sublist(1 + Hpke.nEnc, headerSize);
    final fileKeyBytes =
        await Hpke.openFileKey(KeyManagerService().vaultKeyPair, enc, ct);
    return SecretKey(fileKeyBytes);
  }

  /// Probe that the header opens under the current vault key. Throws on
  /// failure. Used by the canary integrity check at account setup.
  static Future<void> verifyKey(Uint8List partialData) async {
    await decryptFileKeyFromHeader(partialData);
  }

  // ---------------------------------------------------------------------------
  // Whole-file (bytes) encrypt / decrypt
  // ---------------------------------------------------------------------------

  static Future<Uint8List> encryptFile(Uint8List fileBytes) async {
    final fileKey = await AesGcm.with256bits().newSecretKey();
    final fileKeyBytes = Uint8List.fromList(await fileKey.extractBytes());
    final contentId = _randomBytes(16);
    final totalChunks =
        fileBytes.isEmpty ? 0 : (fileBytes.length / _chunkSize).ceil();

    final out = BytesBuilder(copy: false);
    out.add(await _buildHeader(fileKeyBytes));
    out.add(_buildPreamble(contentId, totalChunks));
    for (var i = 0; i < totalChunks; i++) {
      final start = i * _chunkSize;
      final end = min(start + _chunkSize, fileBytes.length);
      final chunk = Uint8List.sublistView(fileBytes, start, end);
      out.add(await _cipher.encryptChunk(
        chunk,
        fileKey,
        _chunkNonce(i),
        _chunkAad(contentId, i, totalChunks),
      ));
    }
    return out.toBytes();
  }

  static Future<Uint8List> decryptFile(Uint8List encryptedBundle) async {
    final fileKey = await decryptFileKeyFromHeader(encryptedBundle);
    return decryptBody(encryptedBundle.sublist(headerSize), fileKey);
  }

  // ---------------------------------------------------------------------------
  // Streaming encrypt (video / large files) — total size known up front
  // ---------------------------------------------------------------------------

  /// Encrypts [source] to the v1 format. [totalSize] is the plaintext byte
  /// count (callers always know it) — required so the preamble can carry the
  /// authenticated total_chunks.
  static Stream<List<int>> encryptStream(
    Stream<List<int>> source, {
    required int totalSize,
  }) async* {
    final fileKey = await AesGcm.with256bits().newSecretKey();
    final fileKeyBytes = Uint8List.fromList(await fileKey.extractBytes());
    final contentId = _randomBytes(16);
    final totalChunks =
        totalSize == 0 ? 0 : (totalSize / _chunkSize).ceil();

    yield await _buildHeader(fileKeyBytes);
    yield _buildPreamble(contentId, totalChunks);

    var buffer = <int>[];
    var index = 0;
    await for (final data in source) {
      buffer.addAll(data);
      while (buffer.length >= _chunkSize) {
        final raw = Uint8List.fromList(buffer.sublist(0, _chunkSize));
        buffer = buffer.sublist(_chunkSize);
        yield await _cipher.encryptChunk(
          raw,
          fileKey,
          _chunkNonce(index),
          _chunkAad(contentId, index, totalChunks),
        );
        index++;
      }
    }
    if (buffer.isNotEmpty) {
      yield await _cipher.encryptChunk(
        Uint8List.fromList(buffer),
        fileKey,
        _chunkNonce(index),
        _chunkAad(contentId, index, totalChunks),
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Body decrypt (shared by vault and share blobs)
  // ---------------------------------------------------------------------------

  /// Decrypts a full body (preamble + all chunks) given the recovered file
  /// key. Verifies the authenticated chunk count, so truncation/extension is
  /// rejected.
  static Future<Uint8List> decryptBody(
    Uint8List body,
    SecretKey fileKey,
  ) async {
    final (contentId, totalChunks) = _readPreamble(body);
    final out = BytesBuilder(copy: false);
    var offset = bodyPreambleSize;
    var index = 0;
    while (offset < body.length) {
      final remaining = body.length - offset;
      final size =
          remaining < _encryptedChunkSize ? remaining : _encryptedChunkSize;
      final chunk = body.sublist(offset, offset + size);
      out.add(await _cipher.decryptChunk(
        chunk,
        fileKey,
        _chunkNonce(index),
        _chunkAad(contentId, index, totalChunks),
      ));
      offset += size;
      index++;
    }
    if (index != totalChunks) {
      throw Exception(
          'Chunk count mismatch: header says $totalChunks, found $index');
    }
    return out.takeBytes();
  }

  /// Decrypts a contiguous run of [chunkCount] encrypted chunks starting at
  /// global chunk [startIndex], for the streaming server's range requests.
  /// [contentId] and [totalChunks] come from the body preamble.
  static Future<Uint8List> decryptChunkRange(
    Uint8List encryptedChunks,
    SecretKey fileKey,
    int chunkCount, {
    required Uint8List contentId,
    required int totalChunks,
    required int startIndex,
    int? lastChunkEncryptedSize,
  }) async {
    final out = BytesBuilder(copy: false);
    var offset = 0;
    for (var i = 0; i < chunkCount; i++) {
      final globalIndex = startIndex + i;
      final isLast = globalIndex == totalChunks - 1;
      final size = (isLast && lastChunkEncryptedSize != null)
          ? lastChunkEncryptedSize
          : _encryptedChunkSize;
      if (offset + size > encryptedChunks.length) {
        throw Exception('Chunk slice underflow at chunk $globalIndex');
      }
      final chunk = encryptedChunks.sublist(offset, offset + size);
      out.add(await _cipher.decryptChunk(
        chunk,
        fileKey,
        _chunkNonce(globalIndex),
        _chunkAad(contentId, globalIndex, totalChunks),
      ));
      offset += size;
    }
    return out.takeBytes();
  }

  /// Reads content_id and total_chunks from a body slice's preamble.
  static (Uint8List, int) readBodyPreamble(Uint8List body) =>
      _readPreamble(body);

  // ---------------------------------------------------------------------------
  // Sharing helpers (symmetric wrap; body format is shared with the vault)
  // ---------------------------------------------------------------------------

  static Future<SecretKey> generateShareKey() =>
      AesGcm.with256bits().newSecretKey();

  /// Symmetrically wraps [fileKey] under [shareKey], returning the raw 60-byte
  /// box (nonce ‖ ciphertext ‖ tag). The share header framing (version,
  /// length, optional salt) is assembled by ShareService — see
  /// [ShareService.createShare] and the share header v1 layout there. The
  /// share's body is the vault body verbatim, so [decryptBody] serves both.
  static Future<Uint8List> wrapFileKeyForShare(
    SecretKey fileKey,
    SecretKey shareKey,
  ) async {
    final fileKeyBytes = Uint8List.fromList(await fileKey.extractBytes());
    return _cipher.encrypt(fileKeyBytes, shareKey);
  }

  static Future<SecretKey> derivePasswordKey(
    String password,
    Uint8List salt,
  ) {
    final argon2 = Argon2id(
      parallelism: 1,
      memory: 65536,
      iterations: 2,
      hashLength: 32,
    );
    return argon2.deriveKeyFromPassword(password: password, nonce: salt);
  }

  static Uint8List generatePasswordSalt() => _randomBytes(16);

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static Uint8List _buildPreamble(Uint8List contentId, int totalChunks) {
    final out = Uint8List(bodyPreambleSize);
    out.setRange(0, 16, contentId);
    ByteData.sublistView(out).setUint32(16, totalChunks, Endian.big);
    return out;
  }

  static (Uint8List, int) _readPreamble(Uint8List body) {
    if (body.length < bodyPreambleSize) {
      throw Exception('Body too short for preamble');
    }
    final contentId = body.sublist(0, 16);
    final totalChunks =
        ByteData.sublistView(body, 16, bodyPreambleSize).getUint32(0, Endian.big);
    return (contentId, totalChunks);
  }

  /// AAD for chunk [index]: content_id ‖ BE32(index) ‖ BE32(total).
  static Uint8List _chunkAad(Uint8List contentId, int index, int totalChunks) {
    final out = Uint8List(24);
    out.setRange(0, 16, contentId);
    final bd = ByteData.sublistView(out);
    bd.setUint32(16, index, Endian.big);
    bd.setUint32(20, totalChunks, Endian.big);
    return out;
  }

  /// BE96(index): the 96-bit counter nonce. Index < 2^32 (a 2-exabyte file
  /// at 512 KiB chunks), so the low 4 bytes hold it and the top 8 are zero.
  static Uint8List _chunkNonce(int index) {
    final out = Uint8List(12);
    ByteData.sublistView(out).setUint32(8, index, Endian.big);
    return out;
  }

  static Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => rnd.nextInt(256)));
  }
}
