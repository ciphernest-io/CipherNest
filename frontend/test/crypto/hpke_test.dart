import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ciphernest/crypto/hpke.dart';

/// RFC 9180 Appendix A.1 — DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
/// AES-128-GCM, base mode. Byte-exact conformance: if any intermediate
/// drifts, the suite is wrong and everything above it is untrustworthy.
///
/// Vectors fetched verbatim from https://www.rfc-editor.org/rfc/rfc9180.txt.
void main() {
  // --- A.1 base setup ---
  final info = _hex('4f6465206f6e2061204772656369616e2055726e');
  final ikmE =
      _hex('7268600d403fce431561aef583ee1613527cff655c1343f29812e66706df3234');
  final pkEm =
      _hex('37fda3567bdbd628e88668c3c8d7e97d1d1253b6d4ea6d44c150f741f1bf4431');
  final skEm =
      _hex('52c4a758a802cd8b936eceea314432798d5baf2d7e9235dc084ab1b9cfa2f736');
  final ikmR =
      _hex('6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037');
  final pkRm =
      _hex('3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d');
  final skRm =
      _hex('4612c550263fc8ad58375df3f557aac531d26850903e55a9f23f21d8534e8ac8');
  final enc =
      _hex('37fda3567bdbd628e88668c3c8d7e97d1d1253b6d4ea6d44c150f741f1bf4431');
  final sharedSecret =
      _hex('fe0e18c9f024ce43799ae393c7e8fe8fce9d218875e8227b0187c04e7d2ea1fc');
  final keyScheduleContext = _hex(
      '00725611c9d98c07c03f60095cd32d400d8347d45ed67097bbad50fc56da742d07cb6cffde367bb0565ba28bb02c90744a20f5ef37f30523526106f637abb05449');
  final secret =
      _hex('12fff91991e93b48de37e7daddb52981084bd8aa64289c3788471d9a9712f397');
  final key = _hex('4531685d41d65f03dc48f6b8302c05b0');
  final baseNonce = _hex('56d890e5accaaf011cff4b7d');

  // --- A.1 encryption, sequence 0 ---
  final pt =
      _hex('4265617574792069732074727574682c20747275746820626561757479');
  final aad = _hex('436f756e742d30');
  final ct = _hex(
      'f938558b5d72f1a23810b4be2ab4f84331acc02fc97babc53a52ae8218a355a96d8770ac83d07bea87e13c512a');

  group('RFC 9180 A.1 DeriveKeyPair', () {
    // The raw derived scalar (skRm/skEm) is the LabeledExpand output before
    // X25519 clamping; the package clamps on keypair construction, so we
    // assert the raw scalar (proves the labeled KDF) and the public key
    // (proves derivation -> pk). Both are byte-exact against A.1.
    test('recipient ikmR -> (skRm, pkRm)', () async {
      expect(await Hpke.deriveSkForTest(ikmR), skRm, reason: 'skRm');
      final kp = await Hpke.deriveKeyPair(ikmR);
      expect((await kp.extractPublicKey()).bytes, pkRm, reason: 'pkRm');
    });

    test('ephemeral ikmE -> (skEm, pkEm)', () async {
      expect(await Hpke.deriveSkForTest(ikmE), skEm, reason: 'skEm');
      final kp = await Hpke.deriveKeyPair(ikmE);
      expect((await kp.extractPublicKey()).bytes, pkEm, reason: 'pkEm');
    });
  });

  group('RFC 9180 A.1 key schedule', () {
    test('encap + key schedule intermediates', () async {
      final recipient = await Hpke.deriveKeyPair(ikmR);
      final pkR = await recipient.extractPublicKey();
      final ephemeral = await Hpke.deriveKeyPair(ikmE);

      final dbg = await Hpke.keyScheduleForTest(pkR, ephemeral, info);
      expect(dbg.enc, enc, reason: 'enc');
      expect(dbg.sharedSecret, sharedSecret, reason: 'shared_secret');
      expect(dbg.keyScheduleContext, keyScheduleContext,
          reason: 'key_schedule_context');
      expect(dbg.secret, secret, reason: 'secret');
      expect(dbg.key, key, reason: 'key');
      expect(dbg.baseNonce, baseNonce, reason: 'base_nonce');
    });
  });

  group('RFC 9180 A.1 seal (seq 0)', () {
    test('ct matches vector', () async {
      final recipient = await Hpke.deriveKeyPair(ikmR);
      final pkR = await recipient.extractPublicKey();
      final ephemeral = await Hpke.deriveKeyPair(ikmE);

      final (gotEnc, gotCt) = await Hpke.sealForTest(
        pkR: pkR,
        info: info,
        aad: aad,
        pt: pt,
        ephemeral: ephemeral,
      );
      expect(gotEnc, enc, reason: 'enc');
      expect(gotCt, ct, reason: 'ct');
    });
  });

  group('file-key seal/open round trip', () {
    test('seal then open recovers the key', () async {
      final vault = await Hpke.deriveKeyPair(ikmR);
      final pkR = await vault.extractPublicKey();
      final fileKey = Uint8List.fromList(
        List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
      );

      final sealed = await Hpke.sealFileKey(pkR, fileKey);
      expect(sealed.enc.length, 32);
      expect(sealed.ct.length, 48); // 32 key + 16 tag

      final opened = await Hpke.openFileKey(vault, sealed.enc, sealed.ct);
      expect(opened, fileKey);
    });

    test('wrong vault key fails to open', () async {
      final vaultA = await Hpke.deriveKeyPair(ikmR);
      final vaultB = await Hpke.deriveKeyPair(ikmE);
      final pkA = await vaultA.extractPublicKey();
      final fileKey = Uint8List(32);

      final sealed = await Hpke.sealFileKey(pkA, fileKey);
      expect(
        () => Hpke.openFileKey(vaultB, sealed.enc, sealed.ct),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });
  });
}

Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
