import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ciphernest/services/encryption_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';

/// Format v1 round-trip and integrity. The AAD + counter-nonce + authenticated
/// total_chunks design must reject every chunk-level tamper: reorder,
/// truncate, extend, duplicate, and cross-blob splice.
void main() {
  const chunkSize = EncryptionService.plaintextChunkSize; // 524288
  const encChunk = EncryptionService.encryptedChunkSize; // 524316
  const headerSize = EncryptionService.headerSize; // 81
  const preamble = EncryptionService.bodyPreambleSize; // 20

  setUp(() async {
    final kp = await X25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    KeyManagerService().installKeysForTest(keyPair: kp, publicKey: pub);
  });

  Uint8List randomBytes(int n) {
    final rnd = Random(1234); // deterministic across a run
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }

  group('round trip', () {
    test('multi-chunk file (2.5 chunks)', () async {
      final data = randomBytes((chunkSize * 2.5).round());
      final enc = await EncryptionService.encryptFile(data);
      // header + preamble + 3 chunks (2 full + 1 partial).
      expect(enc.length,
          headerSize + preamble + data.length + 3 * 28);
      final dec = await EncryptionService.decryptFile(enc);
      expect(dec, data);
    });

    test('empty file', () async {
      final enc = await EncryptionService.encryptFile(Uint8List(0));
      expect(enc.length, headerSize + preamble);
      final dec = await EncryptionService.decryptFile(enc);
      expect(dec, isEmpty);
    });

    test('single small chunk (thumbnail-sized)', () async {
      final data = randomBytes(40 * 1024);
      final enc = await EncryptionService.encryptFile(data);
      final dec = await EncryptionService.decryptFile(enc);
      expect(dec, data);
    });
  });

  group('integrity — tampering is rejected', () {
    late Uint8List enc;
    setUp(() async {
      // 3 full chunks so reorder/dup have room.
      enc = await EncryptionService.encryptFile(randomBytes(chunkSize * 3));
    });

    test('chunk reorder fails', () async {
      final t = Uint8List.fromList(enc);
      final c0 = t.sublist(headerSize + preamble, headerSize + preamble + encChunk);
      final c1 = t.sublist(
          headerSize + preamble + encChunk, headerSize + preamble + 2 * encChunk);
      t.setRange(headerSize + preamble, headerSize + preamble + encChunk, c1);
      t.setRange(headerSize + preamble + encChunk,
          headerSize + preamble + 2 * encChunk, c0);
      expect(() => EncryptionService.decryptFile(t), throwsA(anything));
    });

    test('truncation (drop last chunk) fails', () async {
      final t = enc.sublist(0, enc.length - encChunk);
      expect(() => EncryptionService.decryptFile(t), throwsA(anything));
    });

    test('duplication (append a copy of the last chunk) fails', () async {
      final last = enc.sublist(enc.length - encChunk);
      final t = Uint8List.fromList([...enc, ...last]);
      expect(() => EncryptionService.decryptFile(t), throwsA(anything));
    });

    test('cross-blob splice fails (different content_id)', () async {
      // A second blob has a different random content_id; its chunk 0 pasted
      // into the first blob must fail the AAD content_id bind.
      final other = await EncryptionService.encryptFile(randomBytes(chunkSize * 3));
      final otherC0 = other.sublist(
          headerSize + preamble, headerSize + preamble + encChunk);
      final t = Uint8List.fromList(enc);
      t.setRange(headerSize + preamble, headerSize + preamble + encChunk, otherC0);
      expect(() => EncryptionService.decryptFile(t), throwsA(anything));
    });

    test('flipping a body ciphertext byte fails', () async {
      final t = Uint8List.fromList(enc);
      final mid = headerSize + preamble + 100;
      t[mid] ^= 0x01;
      expect(() => EncryptionService.decryptFile(t), throwsA(anything));
    });

    test('flipping the total_chunks field fails', () async {
      final t = Uint8List.fromList(enc);
      // total_chunks is the 4 bytes at headerSize+16.
      t[headerSize + 16 + 3] ^= 0x01;
      expect(() => EncryptionService.decryptFile(t), throwsA(anything));
    });
  });

  group('streaming encrypt matches whole-file decrypt', () {
    test('encryptStream output decrypts', () async {
      final data = randomBytes((chunkSize * 2.2).round());
      final chunks = <int>[];
      await for (final part in EncryptionService.encryptStream(
        Stream.value(data),
        totalSize: data.length,
      )) {
        chunks.addAll(part);
      }
      final dec = await EncryptionService.decryptFile(Uint8List.fromList(chunks));
      expect(dec, data);
    });
  });
}
