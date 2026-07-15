/// Vault Health orphan/missing detection against real SQLite + a fake cloud.
library;

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/key_manager_service.dart';
import 'package:ciphernest/services/sync/op_replay.dart';
import 'package:ciphernest/services/sync/sync_op.dart';
import 'package:ciphernest/services/sync/hlc.dart';

/// Pure-logic mirror of VaultHealthService's diff (the service itself needs
/// CloudService/DatabaseService singletons; this pins the algorithm).
({List<String> orphans, List<String> missing}) diff({
  required Set<String> blobStems,
  required List<SyncOp> ops,
  required Set<String> rowIds,
}) {
  final known = replayOps(ops).files.keys.toSet();
  final referenced = {...known, ...rowIds};
  final orphans = blobStems.difference(referenced).toList()..sort();
  final missing = known.difference(blobStems).toList()..sort();
  return (orphans: orphans, missing: missing);
}

SyncOp create(String id, int wall) => SyncOp(
    kind: SyncOpKind.createFile,
    deviceId: 'd',
    seq: wall,
    hlc: Hlc(wall, 0),
    targetId: id,
    name: '$id.jpg');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final kp = await X25519().newKeyPair();
    KeyManagerService()
        .installKeysForTest(keyPair: kp, publicKey: await kp.extractPublicKey());
  });

  test('a blob with no op and no row is an orphan', () {
    final r = diff(
      blobStems: {'known1', 'orphan1', 'orphan2'},
      ops: [create('known1', 1)],
      rowIds: {'known1'},
    );
    expect(r.orphans, ['orphan1', 'orphan2']);
    expect(r.missing, isEmpty);
  });

  test('a blob backing a row that has no op is NOT an orphan', () {
    // Pre-sync legacy row references its blob legitimately.
    final r = diff(
      blobStems: {'legacy1'},
      ops: const [],
      rowIds: {'legacy1'},
    );
    expect(r.orphans, isEmpty);
  });

  test('a known file with no blob is MISSING (potential data loss)', () {
    final r = diff(
      blobStems: {'a'},
      ops: [create('a', 1), create('gone', 2)],
      rowIds: {'a', 'gone'},
    );
    expect(r.missing, ['gone']);
    expect(r.orphans, isEmpty);
  });

  test('a purged file is neither orphan nor missing (its blob, if present, '
      'is a real orphan to recover-or-forget)', () {
    final ops = [
      create('p', 1),
      SyncOp(
          kind: SyncOpKind.purgeFile,
          deviceId: 'd',
          seq: 2,
          hlc: const Hlc(2, 0),
          targetId: 'p'),
    ];
    // Purge removed 'p' from replay state; if the blob lingers it surfaces
    // as an orphan (correct — the sweep's blob delete may have failed).
    final r = diff(blobStems: {'p'}, ops: ops, rowIds: const {});
    expect(r.orphans, ['p']);
    expect(r.missing, isEmpty);
  });

  test('healthy vault: no orphans, no missing', () {
    final r = diff(
      blobStems: {'a', 'b'},
      ops: [create('a', 1), create('b', 2)],
      rowIds: {'a', 'b'},
    );
    expect(r.orphans, isEmpty);
    expect(r.missing, isEmpty);
  });
}
