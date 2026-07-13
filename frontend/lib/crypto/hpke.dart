import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

/// HPKE — Hybrid Public Key Encryption, RFC 9180.
///
/// Ciphersuite (fixed): **DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
/// AES-128-GCM** — the suite with official RFC 9180 Appendix A.1 test
/// vectors (see test/crypto/hpke_test.dart). X25519 caps the asymmetric
/// path at ~128-bit security regardless of the AEAD, so AES-128-GCM for the
/// key wrap loses nothing real and buys byte-exact spec conformance. File
/// *bodies* are AES-256-GCM elsewhere; this suite wraps only the 32-byte
/// per-file key.
///
/// Base mode (no PSK, no sender auth), single-shot seal/open at sequence 0.
/// That's all CipherNest needs: each file key is sealed once to the vault's
/// long-term X25519 public key. Sealing needs only the public key — this is
/// what lets background sync encrypt while the vault is locked.
///
/// This is a from-scratch implementation of the RFC's labeled KDF, DHKEM,
/// and key schedule over the `cryptography` package's HMAC-SHA256, X25519,
/// and AES-GCM primitives. Every intermediate (shared_secret,
/// key_schedule_context, key, base_nonce) is asserted against RFC 9180 A.1.
class Hpke {
  Hpke._();

  // Suite identifiers (RFC 9180 §7.1).
  static const int _kemId = 0x0020; // DHKEM(X25519, HKDF-SHA256)
  static const int _kdfId = 0x0001; // HKDF-SHA256
  static const int _aeadId = 0x0001; // AES-128-GCM

  // Lengths (bytes).
  static const int nSecret = 32; // KEM shared secret
  static const int nEnc = 32; // serialized ephemeral public key
  static const int nPk = 32;
  static const int nSk = 32;
  static const int nH = 32; // HKDF-SHA256 output
  static const int nK = 16; // AES-128-GCM key
  static const int nN = 12; // AES-128-GCM nonce
  static const int nT = 16; // AES-128-GCM tag

  static final X25519 _x25519 = X25519();
  static final Hmac _hmac = Hmac.sha256();
  static final AesGcm _aead = AesGcm.with128bits();

  static final Uint8List _hpkeV1 =
      Uint8List.fromList('HPKE-v1'.codeUnits);

  /// suite_id for the KEM: "KEM" || I2OSP(kem_id, 2).
  static final Uint8List _suiteKem =
      Uint8List.fromList([...'KEM'.codeUnits, ..._i2osp(_kemId, 2)]);

  /// suite_id for HPKE: "HPKE" || I2OSP(kem_id,2) || I2OSP(kdf_id,2) ||
  /// I2OSP(aead_id,2).
  static final Uint8List _suiteHpke = Uint8List.fromList([
    ...'HPKE'.codeUnits,
    ..._i2osp(_kemId, 2),
    ..._i2osp(_kdfId, 2),
    ..._i2osp(_aeadId, 2),
  ]);

  // ---------------------------------------------------------------------------
  // Public API — file-key wrapping
  // ---------------------------------------------------------------------------

  /// Application info string bound into every file-key seal. Frozen forever
  /// once a real vault exists — changing it orphans every file.
  static final Uint8List fileKeyInfo =
      Uint8List.fromList('ciphernest/filekey/v1'.codeUnits);

  /// Seal a 32-byte per-file key to the vault's public key. Returns the
  /// encapsulated ephemeral key (`enc`, 32 bytes) and the AEAD ciphertext
  /// (`ct`, 48 bytes = 32 wrapped key + 16 tag). No secret key material is
  /// needed — this is the encrypt-while-locked primitive.
  static Future<HpkeSealed> sealFileKey(
    SimplePublicKey recipientPublicKey,
    Uint8List fileKey,
  ) async {
    final (enc, ct) = await _seal(
      recipientPublicKey,
      info: fileKeyInfo,
      aad: _empty,
      pt: fileKey,
    );
    return HpkeSealed(enc: enc, ct: ct);
  }

  /// Open a sealed file key with the vault's private key (requires an
  /// unlocked vault).
  static Future<Uint8List> openFileKey(
    SimpleKeyPair recipientKeyPair,
    Uint8List enc,
    Uint8List ct,
  ) {
    return _open(
      recipientKeyPair,
      enc: enc,
      ct: ct,
      info: fileKeyInfo,
      aad: _empty,
    );
  }

  // ---------------------------------------------------------------------------
  // Public API — generic sealed payloads (domain-separated by info string)
  // ---------------------------------------------------------------------------

  /// Seal an arbitrary small payload to the vault public key under a caller-
  /// supplied [info] string. Same base-mode single-shot construction as the
  /// file-key wrap; the distinct info string is the domain separator that
  /// keeps these ciphertexts and file-key wraps mutually un-decryptable.
  /// Public-key-only, so this works while the vault is locked.
  static Future<HpkeSealed> sealPayload(
    SimplePublicKey recipientPublicKey,
    Uint8List info,
    Uint8List plaintext,
  ) async {
    final (enc, ct) = await _seal(
      recipientPublicKey,
      info: info,
      aad: _empty,
      pt: plaintext,
    );
    return HpkeSealed(enc: enc, ct: ct);
  }

  /// Open a payload sealed by [sealPayload] with the same [info] string.
  static Future<Uint8List> openPayload(
    SimpleKeyPair recipientKeyPair,
    Uint8List info,
    Uint8List enc,
    Uint8List ct,
  ) {
    return _open(
      recipientKeyPair,
      enc: enc,
      ct: ct,
      info: info,
      aad: _empty,
    );
  }

  // ---------------------------------------------------------------------------
  // RFC 9180 §5.1 — DeriveKeyPair (used for our vault keypair from the seed)
  // ---------------------------------------------------------------------------

  /// Deterministically derive an X25519 keypair from input keying material,
  /// exactly as RFC 9180 §7.1.2 specifies for DHKEM(X25519). CipherNest
  /// feeds this the HKDF output of the BIP-39 seed, so the same mnemonic
  /// always reproduces the same vault keypair.
  static Future<SimpleKeyPair> deriveKeyPair(Uint8List ikm) async {
    return _x25519.newKeyPairFromSeed(await _deriveSk(ikm));
  }

  /// The raw X25519 private scalar per RFC 9180 §7.1.2 — the LabeledExpand
  /// output, *before* X25519 clamping. The `cryptography` package clamps this
  /// when it constructs the keypair (so the keypair's reported private bytes
  /// differ), but the derivation itself is what the spec fixes, and it is
  /// what the A.1 vectors publish as skEm/skRm.
  static Future<Uint8List> _deriveSk(Uint8List ikm) async {
    final dkpPrk = await _labeledExtract(_empty, _suiteKem, 'dkp_prk', ikm);
    return _labeledExpand(dkpPrk, _suiteKem, 'sk', _empty, nSk);
  }

  // ---------------------------------------------------------------------------
  // Seal / Open (base mode, single-shot, seq = 0)
  // ---------------------------------------------------------------------------

  static Future<(Uint8List enc, Uint8List ct)> _seal(
    SimplePublicKey pkR, {
    required Uint8List info,
    required Uint8List aad,
    required Uint8List pt,
    SimpleKeyPair? ephemeral,
  }) async {
    final (sharedSecret, enc) = await _encap(pkR, ephemeral: ephemeral);
    final ks = await _keySchedule(sharedSecret, info);
    // seq = 0 → nonce = base_nonce XOR 0 = base_nonce.
    final box = await _aead.encrypt(
      pt,
      secretKey: SecretKey(ks.key),
      nonce: ks.baseNonce,
      aad: aad,
    );
    final ct = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return (enc, ct);
  }

  static Future<Uint8List> _open(
    SimpleKeyPair skR, {
    required Uint8List enc,
    required Uint8List ct,
    required Uint8List info,
    required Uint8List aad,
  }) async {
    final sharedSecret = await _decap(enc, skR);
    final ks = await _keySchedule(sharedSecret, info);
    if (ct.length < nT) throw ArgumentError('HPKE ciphertext too short');
    final cipherText = ct.sublist(0, ct.length - nT);
    final mac = Mac(ct.sublist(ct.length - nT));
    final pt = await _aead.decrypt(
      SecretBox(cipherText, nonce: ks.baseNonce, mac: mac),
      secretKey: SecretKey(ks.key),
    );
    return Uint8List.fromList(pt);
  }

  // ---------------------------------------------------------------------------
  // DHKEM (RFC 9180 §4.1)
  // ---------------------------------------------------------------------------

  static Future<(Uint8List sharedSecret, Uint8List enc)> _encap(
    SimplePublicKey pkR, {
    SimpleKeyPair? ephemeral,
  }) async {
    final skE = ephemeral ?? await _x25519.newKeyPair();
    final pkE = await skE.extractPublicKey();
    final dh = await _dh(skE, pkR);
    final enc = Uint8List.fromList(pkE.bytes);
    final pkRm = Uint8List.fromList(pkR.bytes);
    final kemContext = Uint8List.fromList([...enc, ...pkRm]);
    final sharedSecret = await _extractAndExpand(dh, kemContext);
    return (sharedSecret, enc);
  }

  static Future<Uint8List> _decap(Uint8List enc, SimpleKeyPair skR) async {
    final pkE = SimplePublicKey(enc, type: KeyPairType.x25519);
    final dh = await _dh(skR, pkE);
    final pkR = await skR.extractPublicKey();
    final pkRm = Uint8List.fromList(pkR.bytes);
    final kemContext = Uint8List.fromList([...enc, ...pkRm]);
    return _extractAndExpand(dh, kemContext);
  }

  static Future<Uint8List> _dh(SimpleKeyPair sk, SimplePublicKey pk) async {
    final shared =
        await _x25519.sharedSecretKey(keyPair: sk, remotePublicKey: pk);
    return Uint8List.fromList(await shared.extractBytes());
  }

  static Future<Uint8List> _extractAndExpand(
    Uint8List dh,
    Uint8List kemContext,
  ) async {
    final eaePrk = await _labeledExtract(_empty, _suiteKem, 'eae_prk', dh);
    return _labeledExpand(
      eaePrk,
      _suiteKem,
      'shared_secret',
      kemContext,
      nSecret,
    );
  }

  // ---------------------------------------------------------------------------
  // Key schedule (RFC 9180 §5.1, mode_base = 0x00)
  // ---------------------------------------------------------------------------

  static Future<_KeySchedule> _keySchedule(
    Uint8List sharedSecret,
    Uint8List info,
  ) async {
    final pskIdHash =
        await _labeledExtract(_empty, _suiteHpke, 'psk_id_hash', _empty);
    final infoHash =
        await _labeledExtract(_empty, _suiteHpke, 'info_hash', info);
    final ksContext =
        Uint8List.fromList([0x00, ...pskIdHash, ...infoHash]);
    // psk = "" in base mode.
    final secret =
        await _labeledExtract(sharedSecret, _suiteHpke, 'secret', _empty);
    final key = await _labeledExpand(secret, _suiteHpke, 'key', ksContext, nK);
    final baseNonce =
        await _labeledExpand(secret, _suiteHpke, 'base_nonce', ksContext, nN);
    return _KeySchedule(
      key: key,
      baseNonce: baseNonce,
      context: ksContext,
      secret: secret,
    );
  }

  // ---------------------------------------------------------------------------
  // Labeled KDF (RFC 9180 §4)
  // ---------------------------------------------------------------------------

  static Future<Uint8List> _labeledExtract(
    Uint8List salt,
    Uint8List suiteId,
    String label,
    Uint8List ikm,
  ) {
    final labeledIkm = Uint8List.fromList([
      ..._hpkeV1,
      ...suiteId,
      ...label.codeUnits,
      ...ikm,
    ]);
    return _extract(salt, labeledIkm);
  }

  static Future<Uint8List> _labeledExpand(
    Uint8List prk,
    Uint8List suiteId,
    String label,
    Uint8List info,
    int length,
  ) {
    final labeledInfo = Uint8List.fromList([
      ..._i2osp(length, 2),
      ..._hpkeV1,
      ...suiteId,
      ...label.codeUnits,
      ...info,
    ]);
    return _expand(prk, labeledInfo, length);
  }

  // ---------------------------------------------------------------------------
  // HKDF primitives over HMAC-SHA256 (RFC 5869)
  // ---------------------------------------------------------------------------

  /// HKDF-Extract. Empty salt is replaced by nH zero bytes — HMAC zero-pads
  /// the key to the block size, so this is byte-identical to RFC 5869's
  /// "salt defaults to a string of HashLen zeros".
  static Future<Uint8List> _extract(Uint8List salt, Uint8List ikm) async {
    final key = salt.isEmpty ? Uint8List(nH) : salt;
    final mac = await _hmac.calculateMac(ikm, secretKey: SecretKey(key));
    return Uint8List.fromList(mac.bytes);
  }

  /// HKDF-Expand.
  static Future<Uint8List> _expand(
    Uint8List prk,
    Uint8List info,
    int length,
  ) async {
    final secretKey = SecretKey(prk);
    final out = BytesBuilder(copy: false);
    var t = <int>[];
    var counter = 1;
    while (out.length < length) {
      final mac = await _hmac.calculateMac(
        [...t, ...info, counter],
        secretKey: secretKey,
      );
      t = mac.bytes;
      out.add(t);
      counter++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  static List<int> _i2osp(int value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = v & 0xff;
      v >>= 8;
    }
    return out;
  }

  static final Uint8List _empty = Uint8List(0);

  // ---------------------------------------------------------------------------
  // Test-only hooks for RFC 9180 A.1 conformance (see hpke_test.dart)
  // ---------------------------------------------------------------------------

  @visibleForTesting
  static Future<Uint8List> deriveSkForTest(Uint8List ikm) => _deriveSk(ikm);

  @visibleForTesting
  static Future<(Uint8List enc, Uint8List ct)> sealForTest({
    required SimplePublicKey pkR,
    required Uint8List info,
    required Uint8List aad,
    required Uint8List pt,
    required SimpleKeyPair ephemeral,
  }) =>
      _seal(pkR, info: info, aad: aad, pt: pt, ephemeral: ephemeral);

  @visibleForTesting
  static Future<HpkeKeyScheduleDebug> keyScheduleForTest(
    SimplePublicKey pkR,
    SimpleKeyPair ephemeral,
    Uint8List info,
  ) async {
    final (sharedSecret, enc) = await _encap(pkR, ephemeral: ephemeral);
    final ks = await _keySchedule(sharedSecret, info);
    return HpkeKeyScheduleDebug(
      enc: enc,
      sharedSecret: sharedSecret,
      keyScheduleContext: ks.context,
      secret: ks.secret,
      key: ks.key,
      baseNonce: ks.baseNonce,
    );
  }
}

/// Result of sealing a file key: the encapsulated ephemeral public key and
/// the AEAD ciphertext over the key.
class HpkeSealed {
  final Uint8List enc;
  final Uint8List ct;
  const HpkeSealed({required this.enc, required this.ct});
}

class _KeySchedule {
  final Uint8List key;
  final Uint8List baseNonce;
  final Uint8List context;
  final Uint8List secret;
  const _KeySchedule({
    required this.key,
    required this.baseNonce,
    required this.context,
    required this.secret,
  });
}

/// Exposed intermediates for the RFC A.1 conformance test.
@visibleForTesting
class HpkeKeyScheduleDebug {
  final Uint8List enc;
  final Uint8List sharedSecret;
  final Uint8List keyScheduleContext;
  final Uint8List secret;
  final Uint8List key;
  final Uint8List baseNonce;
  const HpkeKeyScheduleDebug({
    required this.enc,
    required this.sharedSecret,
    required this.keyScheduleContext,
    required this.secret,
    required this.key,
    required this.baseNonce,
  });
}
