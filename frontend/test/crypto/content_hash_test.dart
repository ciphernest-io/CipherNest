import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ciphernest/services/encryption_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';

/// Content-hash identity (#1). The plaintext SHA-256 is what lets the app
/// decide a local gallery file IS a vaulted file by bytes, not by name. Two
/// guarantees matter here:
///   * The hash equals a reference SHA-256 of the SAME plaintext (so it is
///     comparable across devices, computed anywhere).
///   * The streamed path (video) yields the SAME hash as the whole-file path
///     over identical bytes, computed in a single pass over the source.
void main() {
  setUp(() async {
    final kp = await X25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    KeyManagerService().installKeysForTest(keyPair: kp, publicKey: pub);
  });

  Uint8List randomBytes(int n, [int seed = 1234]) {
    final rnd = Random(seed);
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }

  Future<String> referenceHex(Uint8List bytes) async {
    final digest = await Sha256().hash(bytes);
    final sb = StringBuffer();
    for (final b in digest.bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  group('hashPlaintext', () {
    test('matches a reference SHA-256 of the same bytes', () async {
      final data = randomBytes(40 * 1024);
      expect(await EncryptionService.hashPlaintext(data),
          await referenceHex(data));
    });

    test('empty buffer hashes to the SHA-256 empty digest', () async {
      // Well-known constant — guards against a subtle hex-encoding bug.
      expect(await EncryptionService.hashPlaintext(Uint8List(0)),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });

    test('a single-byte change changes the hash', () async {
      final a = randomBytes(4096);
      final b = Uint8List.fromList(a)..[0] ^= 0x01;
      expect(await EncryptionService.hashPlaintext(a),
          isNot(await EncryptionService.hashPlaintext(b)));
    });
  });

  group('encryptFileWithHash', () {
    test('hash equals hashPlaintext and ciphertext still round-trips',
        () async {
      final data = randomBytes(200 * 1024);
      final res = await EncryptionService.encryptFileWithHash(data);
      expect(res.hash, await EncryptionService.hashPlaintext(data));
      expect(await EncryptionService.decryptFile(res.encrypted), data);
    });
  });

  group('encryptStreamWithHash (video path)', () {
    test('streamed hash equals whole-file hash over identical bytes',
        () async {
      final data = randomBytes((EncryptionService.plaintextChunkSize * 2.5)
          .round());
      // Feed the source in irregular slices — the single-pass tap must hash
      // the concatenation, independent of chunk boundaries.
      Stream<List<int>> source() async* {
        var i = 0;
        for (final step in [1000, 524288, 7, 300000, 999999]) {
          if (i >= data.length) break;
          final end = min(i + step, data.length);
          yield data.sublist(i, end);
          i = end;
        }
        if (i < data.length) yield data.sublist(i);
      }

      final res = EncryptionService.encryptStreamWithHash(source(),
          totalSize: data.length);
      // Drain the encrypted stream (as an upload would) so the source fully
      // reads and the hash future can complete.
      final encrypted = <int>[];
      await for (final chunk in res.stream) {
        encrypted.addAll(chunk);
      }
      expect(await res.hash, await EncryptionService.hashPlaintext(data));
      // And the drained ciphertext decrypts back to the original.
      expect(await EncryptionService.decryptFile(
          Uint8List.fromList(encrypted)), data);
    });

    test('source error propagates to the hash future', () async {
      Stream<List<int>> failing() async* {
        yield List<int>.filled(1000, 7);
        throw StateError('boom');
      }

      final res = EncryptionService.encryptStreamWithHash(failing(),
          totalSize: 1000);
      // Observe the hash future up front so its error is never momentarily
      // unhandled — it must complete with an error, never hang.
      final hashErrored = res.hash.then<bool>((_) => false, onError: (_) => true);
      // Draining the encrypted stream surfaces the same error.
      await expectLater(res.stream.drain<void>(), throwsA(isA<Object>()));
      expect(await hashErrored, isTrue);
    });
  });
}
