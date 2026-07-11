import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ciphernest/crypto/aes_gcm.dart';
import 'package:ciphernest/services/encryption_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';

/// End-to-end magic-link share round trip, exercising the EXACT crypto of
/// ShareService.createShare (sender) and both viewers' decrypt path. If this
/// passes, the share FORMAT is correct and any real-world failure is
/// environmental (stale deployed web viewer, wrong file format on cloud).
void main() {
  setUp(() async {
    final kp = await X25519().newKeyPair();
    final pub = await kp.extractPublicKey();
    KeyManagerService().installKeysForTest(keyPair: kp, publicKey: pub);
  });

  Uint8List randomBytes(int n) {
    final rnd = Random(99);
    return Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  }

  /// Replicates ShareService.createShare's blob assembly (steps 2–5).
  Future<Uint8List> buildShareBlob(
    Uint8List vaultBlob,
    SecretKey shareKey, {
    Uint8List? salt,
  }) async {
    final fileKey =
        await EncryptionService.decryptFileKeyFromHeader(vaultBlob);
    final wrapped =
        await EncryptionService.wrapFileKeyForShare(fileKey, shareKey);
    final region = salt == null
        ? wrapped
        : Uint8List.fromList([...salt, ...wrapped]);
    final header = BytesBuilder(copy: false)
      ..addByte(EncryptionService.formatVersion)
      ..add((ByteData(4)..setUint32(0, region.length, Endian.big))
          .buffer
          .asUint8List())
      ..add(region);
    final headerBytes = header.toBytes();
    final body = vaultBlob.sublist(EncryptionService.headerSize);
    return Uint8List.fromList([...headerBytes, ...body]);
  }

  /// Replicates the viewer's _decryptShareBlob (Flutter + web share.js).
  Future<Uint8List> viewerDecrypt(
    Uint8List shareBlob,
    SecretKey shareKey, {
    required bool passwordMode,
  }) async {
    expect(shareBlob[0], EncryptionService.formatVersion);
    final regionLen =
        ByteData.sublistView(shareBlob, 1, 5).getUint32(0, Endian.big);
    final regionEnd = 5 + regionLen;
    final wrappedKey = passwordMode
        ? shareBlob.sublist(5 + 16, regionEnd)
        : shareBlob.sublist(5, regionEnd);
    final fileKeyBytes = await AesGcmCipher().decrypt(wrappedKey, shareKey);
    final fileKey = SecretKey(fileKeyBytes);
    return EncryptionService.decryptBody(
        shareBlob.sublist(regionEnd), fileKey);
  }

  test('plain share (random key) round trips', () async {
    final data = randomBytes(700 * 1024); // 2 chunks
    final vaultBlob = await EncryptionService.encryptFile(data);

    final shareKey = await EncryptionService.generateShareKey();
    final shareBlob = await buildShareBlob(vaultBlob, shareKey);
    final out = await viewerDecrypt(shareBlob, shareKey, passwordMode: false);
    expect(out, data);
  });

  test('password share round trips', () async {
    final data = randomBytes(40 * 1024); // 1 chunk
    final vaultBlob = await EncryptionService.encryptFile(data);

    final salt = EncryptionService.generatePasswordSalt();
    final shareKey =
        await EncryptionService.derivePasswordKey('hunter2', salt);
    final shareBlob = await buildShareBlob(vaultBlob, shareKey, salt: salt);
    final out = await viewerDecrypt(shareBlob, shareKey, passwordMode: true);
    expect(out, data);
  });

  test('wrong share key fails to unwrap', () async {
    final data = randomBytes(1024);
    final vaultBlob = await EncryptionService.encryptFile(data);
    final shareKey = await EncryptionService.generateShareKey();
    final shareBlob = await buildShareBlob(vaultBlob, shareKey);

    final wrongKey = await EncryptionService.generateShareKey();
    expect(
      () => viewerDecrypt(shareBlob, wrongKey, passwordMode: false),
      throwsA(anything),
    );
  });
}
