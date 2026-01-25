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

    // Combine: nonce + ciphertext + mac
    return Uint8List.fromList(
      nonce + secretBox.cipherText + secretBox.mac.bytes,
    );
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

  Uint8List _randomBytes(int length) {
    final rnd = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (i) => rnd.nextInt(256)));
  }
}