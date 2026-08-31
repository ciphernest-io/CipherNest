import 'dart:typed_data';
import 'dart:math';
import 'package:cryptography/cryptography.dart';

class AesGcmCipher {
  final AesGcm _aesGcm = AesGcm.with256bits();

  /// Encrypts data using a SPECIFIC key.
  /// Returns: Nonce (12 bytes) + Ciphertext + MAC (16 bytes)
  Future<Uint8List> encrypt(Uint8List plaintext, SecretKey key) async {
    final nonce = _randomBytes(12); // Standard 96-bit nonce

    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
    );

    // Combine: nonce + ciphertext + mac (preallocated; the list-concat
    // form built a growable intermediate and copied it again).
    return _assemble(nonce, secretBox.cipherText, secretBox.mac.bytes);
  }

  /// Decrypts data using a SPECIFIC key.
  /// Expects format: Nonce (12 bytes) + Ciphertext + MAC (16 bytes)
  Future<Uint8List> decrypt(Uint8List encryptedData, SecretKey key) async {
    if (encryptedData.length < 28) throw Exception('Data too short');

    final nonce = encryptedData.sublist(0, 12);
    final macBytes = encryptedData.sublist(encryptedData.length - 16);
    final cipherText = encryptedData.sublist(12, encryptedData.length - 16);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(macBytes),
    );

    final clearText = await _aesGcm.decrypt(
      secretBox,
      secretKey: key,
    );

    return Uint8List.fromList(clearText);
  }

  /// Encrypt one body chunk with a caller-supplied [nonce] and authenticated
  /// [aad]. Output is nonce(12) || ciphertext || tag(16) — self-contained on
  /// the wire so the streaming server can serve fixed-stride chunks. v1 uses
  /// deterministic counter nonces (BE96(index)); uniqueness is structural
  /// because each file key is fresh and used by exactly one encryptor.
  Future<Uint8List> encryptChunk(
    Uint8List plaintext,
    SecretKey key,
    Uint8List nonce,
    Uint8List aad,
  ) async {
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    return _assemble(nonce, box.cipherText, box.mac.bytes);
  }

  /// nonce(12) || ciphertext || tag(16) into one preallocated buffer — two
  /// fewer full-buffer copies per 512 KiB chunk than `fromList(a + b + c)`.
  static Uint8List _assemble(
    List<int> nonce,
    List<int> cipherText,
    List<int> mac,
  ) {
    final out = Uint8List(nonce.length + cipherText.length + mac.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, nonce.length + cipherText.length, cipherText);
    out.setRange(nonce.length + cipherText.length, out.length, mac);
    return out;
  }

  /// Decrypt one body chunk. Verifies the inline nonce equals [expectedNonce]
  /// (rejecting a swapped/reordered chunk before GCM even runs) and
  /// authenticates [aad] (binding the chunk to its content id, index, and
  /// total count).
  Future<Uint8List> decryptChunk(
    Uint8List data,
    SecretKey key,
    Uint8List expectedNonce,
    Uint8List aad,
  ) async {
    if (data.length < 28) throw Exception('Chunk too short');
    final nonce = data.sublist(0, 12);
    if (!_bytesEqual(nonce, expectedNonce)) {
      throw Exception('Chunk nonce mismatch');
    }
    final macBytes = data.sublist(data.length - 16);
    final cipherText = data.sublist(12, data.length - 16);
    final clearText = await _aesGcm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
      secretKey: key,
      aad: aad,
    );
    return Uint8List.fromList(clearText);
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (i) => rnd.nextInt(256)));
  }
}