/// Segment codec: seal/open round trip, the encrypt-while-locked law,
/// tamper rejection, and name parsing.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/key_manager_service.dart';
import 'package:ciphernest/services/sync/hlc.dart';
import 'package:ciphernest/services/sync/segment_codec.dart';
import 'package:ciphernest/services/sync/sync_op.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SimpleKeyPair keyPair;

  setUp(() async {
    keyPair = await X25519().newKeyPair();
    KeyManagerService().installKeysForTest(
      keyPair: keyPair,
      publicKey: await keyPair.extractPublicKey(),
    );
  });

  List<SyncOp> sampleOps() => [
        const SyncOp(
          kind: SyncOpKind.createFile,
          deviceId: 'aaaa-bbbb',
          seq: 0,
          hlc: Hlc(1000, 0),
          targetId: 'f1',
          name: 'x.jpg',
        ),
        const SyncOp(
          kind: SyncOpKind.deleteFile,
          deviceId: 'aaaa-bbbb',
          seq: 1,
          hlc: Hlc(1000, 1),
          targetId: 'f1',
        ),
      ];

  test('seal/open round trip preserves every op field', () async {
    final sealed = await SegmentCodec.seal(sampleOps());
    expect(sealed, isNotNull);
    final opened = await SegmentCodec.tryOpen(sealed!);
    expect(opened, isNotNull);
    expect(opened!.length, 2);
    expect(opened[0].kind, SyncOpKind.createFile);
    expect(opened[0].opKey, 'aaaa-bbbb:0');
    expect(opened[0].hlc, const Hlc(1000, 0));
    expect(opened[0].name, 'x.jpg');
    expect(opened[1].kind, SyncOpKind.deleteFile);
  });

  test('ENCRYPT-WHILE-LOCKED: a locked vault can seal but not open',
      () async {
    KeyManagerService().lock(); // private key gone, public key resident

    final sealed = await SegmentCodec.seal(sampleOps());
    expect(sealed, isNotNull,
        reason: 'sealing is public-key-only — the core architecture');

    final opened = await SegmentCodec.tryOpen(sealed!);
    expect(opened, isNull,
        reason: 'opening requires the unlocked vault, always');
  });

  test('tampered segment is rejected, not partially decoded', () async {
    final sealed = await SegmentCodec.seal(sampleOps());
    final tampered = Uint8List.fromList(sealed!);
    tampered[tampered.length - 5] ^= 0xFF; // flip a body byte
    expect(await SegmentCodec.tryOpen(tampered), isNull);
  });

  test('foreign-vault segment is rejected', () async {
    final sealed = await SegmentCodec.seal(sampleOps());
    final foreign = await X25519().newKeyPair();
    KeyManagerService().installKeysForTest(
      keyPair: foreign,
      publicKey: await foreign.extractPublicKey(),
    );
    expect(await SegmentCodec.tryOpen(sealed!), isNull);
  });

  test('empty op list round-trips (a heartbeat segment is legal)', () async {
    final sealed = await SegmentCodec.seal(const []);
    final opened = await SegmentCodec.tryOpen(sealed!);
    expect(opened, isEmpty);
  });

  group('segment names', () {
    test('round trip with uuid device ids (hyphens, no underscores)', () {
      const deviceId = '1f2e3d4c-aaaa-bbbb-cccc-1234567890ab';
      final name = SegmentCodec.segmentName(deviceId, 42);
      expect(name, 'ops_${deviceId}_42.cnest');
      final parsed = SegmentCodec.parseName(name);
      expect(parsed, isNotNull);
      expect(parsed!.deviceId, deviceId);
      expect(parsed.seq, 42);
    });

    test('rejects foreign names', () {
      expect(SegmentCodec.parseName('db_backup_x.cnest'), isNull);
      expect(SegmentCodec.parseName('ops_.cnest'), isNull);
      expect(SegmentCodec.parseName('ops_dev_x.cnest'), isNull,
          reason: 'non-numeric seq');
      expect(SegmentCodec.parseName('ops_dev_1.txt'), isNull);
      expect(SegmentCodec.parseName('randomfile.cnest'), isNull);
    });
  });
}
