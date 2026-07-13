import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/crypto/hpke.dart';
import 'package:ciphernest/services/cloud/sealed_metadata.dart';
import 'package:ciphernest/services/key_manager_service.dart';
import 'package:ciphernest/src/models/file_model.dart';

/// Covers the four paths the approval demanded: seal/open round trip,
/// reconcile resolution with sealed metadata, legacy-plaintext fallback,
/// and open-failure → UUID fallback. Also pins the Drive appProperties
/// chunking against the 124-byte per-property cap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair vaultKeyPair;

  setUp(() async {
    vaultKeyPair = await X25519().newKeyPair();
    final publicKey = await vaultKeyPair.extractPublicKey();
    // SealedMetadata reads keys from the KeyManagerService singleton.
    KeyManagerService().installKeysForTest(
      keyPair: vaultKeyPair,
      publicKey: publicKey,
    );
  });

  group('seal / open round trip', () {
    test('name and type survive', () async {
      final sealed = await SealedMetadata.seal(
        name: 'biopsy_results.pdf',
        type: CnestFileType.document,
      );
      expect(sealed, isNotNull);
      final opened = await SealedMetadata.tryOpen(sealed!);
      expect(opened, isNotNull);
      expect(opened!.name, 'biopsy_results.pdf');
      expect(opened.type, CnestFileType.document);
    });

    test('unicode names survive', () async {
      const name = 'وثيقة سرّية 📷.jpg';
      final sealed =
          await SealedMetadata.seal(name: name, type: CnestFileType.image);
      final opened = await SealedMetadata.tryOpen(sealed!);
      expect(opened!.name, name);
    });

    test('sealed blob contains no plaintext trace of the name', () async {
      final sealed = await SealedMetadata.seal(
        name: 'divorce_settlement.pdf',
        type: CnestFileType.document,
      );
      expect(sealed, isNot(contains('divorce')));
      // And its base64url-decoded bytes don't either.
      final raw = base64Url.decode(
          sealed! + '=' * ((4 - sealed.length % 4) % 4));
      expect(
        String.fromCharCodes(raw).contains('divorce'),
        isFalse,
      );
    });

    test('long names truncate inside the payload on a UTF-8 boundary',
        () async {
      final longName = '📷' * 100; // 4 bytes each = 400 bytes
      final sealed =
          await SealedMetadata.seal(name: longName, type: CnestFileType.image);
      final opened = await SealedMetadata.tryOpen(sealed!);
      expect(opened, isNotNull);
      final nameBytes = utf8.encode(opened!.name);
      expect(nameBytes.length, lessThanOrEqualTo(SealedMetadata.maxNameBytes));
      // Valid UTF-8 all the way through (utf8.decode would have thrown in
      // tryOpen otherwise) and composed of whole emoji.
      expect(opened.name, isNot(contains('�')));
    });

    test('seal is public-key-only: works with a locked vault', () async {
      final publicKey = await vaultKeyPair.extractPublicKey();
      // Locked = private key gone, public key resident (background sync).
      KeyManagerService().installKeysForTest(
        keyPair: vaultKeyPair,
        publicKey: publicKey,
      );
      KeyManagerService().lock();
      final sealed =
          await SealedMetadata.seal(name: 'x.jpg', type: CnestFileType.image);
      expect(sealed, isNotNull, reason: 'encrypt-locked must survive');
      // ...and tryOpen while locked degrades to null, never throws.
      expect(await SealedMetadata.tryOpen(sealed!), isNull);
    });
  });

  group('open failure paths', () {
    test('garbage input → null, never a throw', () async {
      expect(await SealedMetadata.tryOpen('not-base64!!'), isNull);
      expect(await SealedMetadata.tryOpen(''), isNull);
      expect(
          await SealedMetadata.tryOpen(base64UrlEncode(Uint8List(10))), isNull);
    });

    test('foreign vault key → null (tamper/corruption path)', () async {
      final sealed = await SealedMetadata.seal(
          name: 'secret.jpg', type: CnestFileType.image);
      // Re-key the vault: the blob was sealed to the OLD key.
      final foreign = await X25519().newKeyPair();
      KeyManagerService().installKeysForTest(
        keyPair: foreign,
        publicKey: await foreign.extractPublicKey(),
      );
      expect(await SealedMetadata.tryOpen(sealed!), isNull);
    });
  });

  group('Drive appProperties chunking', () {
    test('every chunk respects the 124-byte key+value cap and round-trips',
        () async {
      final sealed = await SealedMetadata.seal(
        name: 'a_reasonably_long_filename_for_chunking_test_2026.heic',
        type: CnestFileType.image,
      );
      final chunks = SealedMetadata.chunkForAppProperties(sealed!);
      expect(chunks.length, greaterThan(1));
      for (final e in chunks.entries) {
        expect(utf8.encode(e.key).length + utf8.encode(e.value).length,
            lessThanOrEqualTo(124));
      }
      expect(SealedMetadata.fromAppProperties(chunks), sealed);
    });

    test('absent / cleared properties → null', () {
      expect(SealedMetadata.fromAppProperties(null), isNull);
      expect(SealedMetadata.fromAppProperties({'original_name': ''}), isNull);
    });
  });

  group('reconcile resolution ladder (CloudNameResolver)', () {
    test('sealed metadata wins', () async {
      final sealed = await SealedMetadata.seal(
          name: 'holiday.mp4', type: CnestFileType.image);
      final opened = await SealedMetadata.tryOpen(sealed!);
      final r = CloudNameResolver.resolve(
        hadSealed: true,
        sealedOpened: opened,
        legacyName: 'stale_legacy_name.mp4',
        legacyType: 'document',
        stem: 'uuid-1234',
      );
      expect(r.name, 'holiday.mp4');
      expect(r.type, CnestFileType.image);
      expect(r.unreadable, isFalse);
    });

    test('legacy plaintext fallback during transition', () {
      final r = CloudNameResolver.resolve(
        hadSealed: false,
        sealedOpened: null,
        legacyName: 'song.mp3',
        legacyType: 'audio',
        stem: 'uuid-1234',
      );
      expect(r.name, 'song.mp3');
      expect(r.type, CnestFileType.audio);
      expect(r.unreadable, isFalse);
    });

    test('open failure with no legacy rescue → UUID name + unreadable flag',
        () {
      final r = CloudNameResolver.resolve(
        hadSealed: true,
        sealedOpened: null, // sealed blob present but would not open
        legacyName: null,
        legacyType: null,
        stem: 'ab12cd34-uuid',
      );
      expect(r.name, 'ab12cd34-uuid');
      expect(r.unreadable, isTrue);
    });

    test('bare blob (no metadata at all) → UUID name, not unreadable', () {
      final r = CloudNameResolver.resolve(
        hadSealed: false,
        sealedOpened: null,
        legacyName: null,
        legacyType: null,
        stem: 'ab12cd34-uuid',
      );
      expect(r.name, 'ab12cd34-uuid');
      expect(r.unreadable, isFalse);
    });

    test('document mis-tag heals to audio by extension (legacy behavior kept)',
        () {
      final r = CloudNameResolver.resolve(
        hadSealed: false,
        sealedOpened: null,
        legacyName: 'track.mp3',
        legacyType: 'document',
        stem: 'uuid',
      );
      expect(r.type, CnestFileType.audio);
    });
  });

  group('HPKE payload domain separation', () {
    test('meta blobs cannot be opened as file keys and vice versa', () async {
      final pub = await vaultKeyPair.extractPublicKey();
      final sealed = await Hpke.sealPayload(
        pub,
        SealedMetadata.metaInfo,
        Uint8List.fromList(utf8.encode('{"v":1,"n":"x","t":"image"}')),
      );
      // Opening under the file-key info string must fail authentication.
      expect(
        () => Hpke.openFileKey(vaultKeyPair, sealed.enc, sealed.ct),
        throwsA(anything),
      );
    });
  });
}
