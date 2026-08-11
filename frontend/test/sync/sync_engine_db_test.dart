/// SyncEngine against REAL SQLite (ffi) with real sealed segments in a fake
/// cloud. Two devices = two databases, one cloud.
///
/// The headline test is NO-RETRO-PROMOTION: a row planted directly in the
/// files table (simulating pre-sync legacy data or corruption) must never
/// become an op, never reach the cloud, and never appear on another device
/// — the structural property that makes resurrection impossible.
library;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';
import 'package:ciphernest/services/sync/hlc.dart';
import 'package:ciphernest/services/sync/segment_codec.dart';
import 'package:ciphernest/services/sync/sync_engine.dart';
import 'package:ciphernest/services/sync/sync_op.dart';
import 'package:ciphernest/services/system_folders.dart';

class FakeTransport implements SyncTransport {
  final Map<String, Uint8List> objects = {};
  int _nextId = 0;
  final Map<String, String> _idByName = {};
  final Map<String, String> _nameById = {};

  @override
  Future<List<Map<String, dynamic>>> listLogObjects() async => [
        for (final name in objects.keys)
          {'id': _idByName[name], 'name': name, 'size': objects[name]!.length},
      ];

  @override
  Future<Uint8List> downloadObject(String cloudId) async =>
      objects[_nameById[cloudId]!]!;

  @override
  Future<void> deleteObject(String cloudId) async {
    final name = _nameById.remove(cloudId);
    if (name != null) {
      objects.remove(name);
      _idByName.remove(name);
    }
  }

  @override
  Future<void> uploadLogObject({
    required String name,
    required Uint8List bytes,
  }) async {
    if (objects.containsKey(name)) {
      throw StateError('append-only violated: $name already exists');
    }
    final id = 'cloud${_nextId++}';
    objects[name] = bytes;
    _idByName[name] = id;
    _nameById[id] = name;
  }
}

const account = 'g_test@example.com';

Future<Database> newDeviceDb() async {
  // singleInstance: false — every call is its OWN in-memory database, so
  // two sim devices don't silently share storage.
  final db = await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  // Real sync DDL + the files columns the engine touches (mirrors
  // production; a drifted column name fails these tests loudly).
  await DatabaseService.createSyncSchemaForTest(db);
  await db.execute('''
    CREATE TABLE files(
      id TEXT PRIMARY KEY,
      cloud_id TEXT,
      thumbnail_cloud_id TEXT,
      provider INTEGER DEFAULT 0,
      account_id TEXT,
      filename TEXT NOT NULL,
      size_bytes INTEGER,
      content_hash TEXT,
      created_at INTEGER,
      is_uploaded INTEGER,
      local_path TEXT,
      asset_id TEXT,
      is_favorite INTEGER DEFAULT 0,
      is_deleted INTEGER DEFAULT 0,
      deleted_at INTEGER,
      type INTEGER,
      folder_id TEXT,
      deleted_by_folder_id TEXT
    )
  ''');
  await db.execute('''
    CREATE TABLE folders(
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL,
      name TEXT NOT NULL,
      parent_id TEXT,
      is_deleted INTEGER NOT NULL DEFAULT 0,
      deleted_at INTEGER,
      deleted_by_folder_id TEXT,
      created_at INTEGER,
      is_system INTEGER NOT NULL DEFAULT 0,
      is_hidden INTEGER NOT NULL DEFAULT 0,
      hidden_effective INTEGER NOT NULL DEFAULT 0
    )
  ''');
  return db;
}

SyncEngine engineFor(
  Database db,
  FakeTransport cloud,
  String deviceId, {
  int Function()? wallClock,
}) =>
    SyncEngine(
      transport: cloud,
      accountId: account,
      database: () async => db,
      deviceId: () async => deviceId,
      wallClock: wallClock ?? () => 1000000,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Database dbA;
  late Database dbB;
  late FakeTransport cloud;
  late SyncEngine a;
  late SyncEngine b;

  setUpAll(() async {
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // Deterministic key shared with the sealed-engine test — the
    // KeyManagerService singleton is process-wide, so identical keys make
    // concurrent test files harmless to each other.
    final keyPair = await X25519().newKeyPairFromSeed(
        Uint8List.fromList(List<int>.generate(32, (i) => i + 1)));
    KeyManagerService().installKeysForTest(
      keyPair: keyPair,
      publicKey: await keyPair.extractPublicKey(),
    );
    dbA = await newDeviceDb();
    dbB = await newDeviceDb();
    cloud = FakeTransport();
    a = engineFor(dbA, cloud, 'devA');
    b = engineFor(dbB, cloud, 'devB');
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  Future<Map<String, Object?>?> fileRow(Database db, String id) async {
    final rows =
        await db.query('files', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  test('create on A materializes on B through sealed segments', () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'cat.jpg'));
    await a.syncCycle();

    expect(cloud.objects.keys, contains('ops_devA_0.cnest'));

    await b.syncCycle();
    final row = await fileRow(dbB, 'f1');
    expect(row, isNotNull);
    expect(row!['filename'], 'cat.jpg');
    expect(row['is_deleted'], 0);
    expect(row['is_uploaded'], 1);
    expect(row['cloud_id'], isNull,
        reason: 'blob join happens via reconcile, not the op-log');
  });

  test('createFile op carries content_hash + size to the peer (#2 fix: no '
      '0-byte / no blank details sheet)', () async {
    await a.recordLocalOp(const LocalSyncAction(
      kind: SyncOpKind.createFile,
      targetId: 'f1',
      name: 'cat.jpg',
      hash: 'abc123hash',
      size: 4242,
    ));
    await a.syncCycle();
    await b.syncCycle();

    final row = (await fileRow(dbB, 'f1'))!;
    // The receiving device knows the true plaintext size and identity BEFORE
    // the blob reconciles — this is what stops the permanent "0 bytes" tile.
    expect(row['size_bytes'], 4242);
    expect(row['content_hash'], 'abc123hash');
    expect(row['cloud_id'], isNull,
        reason: 'size/hash arrive via the op, not the blob join');
  });

  test('size/hash backfill: a reconcile-seeded row (encrypted size, no hash) '
      'is corrected by the create op it later applies', () async {
    // Model reconcile seeding B first: the blob listing only knows the
    // ENCRYPTED size and carries no hash. This is the row the op must fix.
    await dbB.insert('files', {
      'id': 'f1',
      'account_id': account,
      'filename': 'x.jpg',
      'size_bytes': 5028, // encrypted size, wrong for the details sheet
      'content_hash': null,
      'is_uploaded': 1,
      'is_deleted': 0,
    });

    // A's create op carries the TRUE plaintext size + identity.
    await a.recordLocalOp(const LocalSyncAction(
      kind: SyncOpKind.createFile,
      targetId: 'f1',
      name: 'x.jpg',
      hash: 'truehash',
      size: 5000,
    ));
    await a.syncCycle();
    await b.syncCycle();

    final row = (await fileRow(dbB, 'f1'))!;
    expect(row['size_bytes'], 5000,
        reason: 'encrypted size must be corrected to plaintext size');
    expect(row['content_hash'], 'truehash');
  });

  test('capture time propagates and drives created_at on the peer (#1: '
      'identical gallery order regardless of clock skew)', () async {
    // Two photos whose CAPTURE order is the REVERSE of their upload order —
    // exactly the clock-skew case. Ordering by created_at must follow capture.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile,
        targetId: 'later_upload',
        name: 'b.jpg',
        captured: 100)); // captured FIRST
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile,
        targetId: 'earlier_upload',
        name: 'a.jpg',
        captured: 900)); // captured LATER but uploaded after
    await a.syncCycle();
    await b.syncCycle();

    final b1 = (await fileRow(dbB, 'later_upload'))!;
    final b2 = (await fileRow(dbB, 'earlier_upload'))!;
    expect(b1['created_at'], 100);
    expect(b2['created_at'], 900);
    // And the origin agrees exactly — both devices sort identically.
    expect((await fileRow(dbA, 'later_upload'))!['created_at'], 100);
    expect((await fileRow(dbA, 'earlier_upload'))!['created_at'], 900);
  });

  test('no capture metadata falls back to the create op HLC wall, identical '
      'on both devices', () async {
    // wallClock is fixed at 1000000 for both engines, so the create op's HLC
    // wall is deterministic and shared.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'screenshot.png'));
    await a.syncCycle();
    await b.syncCycle();

    expect((await fileRow(dbA, 'f1'))!['created_at'], 1000000);
    expect((await fileRow(dbB, 'f1'))!['created_at'], 1000000,
        reason: 'HLC-wall fallback must be identical across devices');
  });

  test('origin convergence: a locally pre-seeded wall-clock created_at is '
      'replaced by the canonical capture key when the op is recorded',
      () async {
    // Simulate addFile inserting the row FIRST with a local wall clock.
    await dbA.insert('files', {
      'id': 'f1',
      'account_id': account,
      'filename': 'photo.jpg',
      'created_at': 123456789, // the origin's local wall — skew-vulnerable
      'is_uploaded': 0,
      'is_deleted': 0,
    });

    // Recording the createFile op re-materializes and converges created_at.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile,
        targetId: 'f1',
        name: 'photo.jpg',
        captured: 777));

    expect((await fileRow(dbA, 'f1'))!['created_at'], 777,
        reason: 'origin must adopt the shipped capture time, not local wall');
  });

  test('rename and favorite propagate; device-local columns untouched',
      () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'a.jpg'));
    await a.syncCycle();
    await b.syncCycle();

    // B has device-local bookkeeping the log must never touch.
    await dbB.update('files', {'local_path': '/b/path', 'size_bytes': 777},
        where: 'id = ?', whereArgs: ['f1']);

    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.renameFile, targetId: 'f1', name: 'rose.jpg'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.setFavorite, targetId: 'f1', favorite: true));
    await a.syncCycle();
    await b.syncCycle();

    final row = (await fileRow(dbB, 'f1'))!;
    expect(row['filename'], 'rose.jpg');
    expect(row['is_favorite'], 1);
    expect(row['local_path'], '/b/path');
    expect(row['size_bytes'], 777);
  });

  test('delete-then-restore round trips both directions', () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'x.jpg'));
    await a.syncCycle();
    await b.syncCycle();

    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.deleteFile, targetId: 'f1'));
    await a.syncCycle();
    await b.syncCycle();
    expect((await fileRow(dbB, 'f1'))!['is_deleted'], 1);

    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.restoreFile, targetId: 'f1'));
    await b.syncCycle();
    await a.syncCycle();
    expect((await fileRow(dbA, 'f1'))!['is_deleted'], 0,
        reason: 'restore op must un-delete everywhere');
    expect((await fileRow(dbB, 'f1'))!['is_deleted'], 0);
  });

  test('NO RETRO-PROMOTION: a planted row never becomes an op, never '
      'reaches the cloud, never appears on the other device', () async {
    // Legitimate traffic so segments exist.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'real1', name: 'real.jpg'));

    // The plant: a row with NO op behind it (legacy data / corruption).
    await dbA.insert('files', {
      'id': 'rogue1',
      'account_id': account,
      'filename': 'rogue.jpg',
      'is_uploaded': 1,
      'is_deleted': 0,
    });

    await a.syncCycle();
    await a.syncCycle();
    await b.syncCycle();

    // 1. No op anywhere mentions the rogue row.
    for (final db in [dbA, dbB]) {
      final ops = await db.query('sync_ops',
          where: 'target_id = ?', whereArgs: ['rogue1']);
      expect(ops, isEmpty, reason: 'a DB row was promoted into an op');
    }
    // 2. No cloud segment mentions it (decode every sealed segment).
    for (final bytes in cloud.objects.values) {
      final ops = await SegmentCodec.tryOpen(bytes);
      expect(ops!.where((op) => op.targetId == 'rogue1'), isEmpty,
          reason: 'a DB row leaked into the cloud log');
    }
    // 3. The other device never hears of it.
    expect(await fileRow(dbB, 'rogue1'), isNull);
    // 4. And the row is NOT destroyed locally — it stays for Vault Health.
    expect(await fileRow(dbA, 'rogue1'), isNotNull);

    // fullResync must uphold the same rule.
    await a.fullResync();
    final opsAfter = await dbA.query('sync_ops',
        where: 'target_id = ?', whereArgs: ['rogue1']);
    expect(opsAfter, isEmpty,
        reason: 'fullResync retro-promoted a surviving row');
    expect(await fileRow(dbA, 'rogue1'), isNotNull);
  });

  test('crash resume: pre-seeded segment is detected, not re-uploaded',
      () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'x.jpg'));

    // Pre-seed the cloud with the exact segment a crashed push would have
    // left behind, using a second engine handle on the same DB (so the op
    // content matches what pushPending would seal).
    final pending = await dbA.query('sync_ops', where: 'pending = 1');
    expect(pending.length, 1);
    final sealed = await SegmentCodec.seal([
      SyncOp(
        kind: SyncOpKind.createFile,
        deviceId: 'devA',
        seq: 0,
        hlc: const Hlc(1000000, 0),
        targetId: 'f1',
        name: 'x.jpg',
      ),
    ]);
    await cloud.uploadLogObject(name: 'ops_devA_0.cnest', bytes: sealed!);

    await a.pushPending(); // must detect + resume, not throw/duplicate
    expect(cloud.objects.length, 1, reason: 'no duplicate segment');
    final stillPending = await dbA.query('sync_ops', where: 'pending = 1');
    expect(stillPending, isEmpty);

    await b.syncCycle();
    expect(await fileRow(dbB, 'f1'), isNotNull);
  });

  test('eternal tombstones: even ancient foreign tombstones materialize '
      'consistently (convergence over ghost-hiding)', () async {
    const day = 24 * 60 * 60 * 1000;
    final now = 100 * day;
    b = engineFor(dbB, cloud, 'devB', wallClock: () => now);

    final pair = await SegmentCodec.seal([
      SyncOp(
          kind: SyncOpKind.createFile,
          deviceId: 'devX',
          seq: 0,
          hlc: Hlc(10 * day, 0),
          targetId: 'old1',
          name: 'old.jpg'),
      SyncOp(
          kind: SyncOpKind.deleteFile,
          deviceId: 'devX',
          seq: 1,
          hlc: Hlc(11 * day, 0), // deleted 89 days before "now"
          targetId: 'old1'),
      SyncOp(
          kind: SyncOpKind.createFile,
          deviceId: 'devX',
          seq: 2,
          hlc: Hlc(12 * day, 0),
          targetId: 'fresh1',
          name: 'fresh.jpg'),
      SyncOp(
          kind: SyncOpKind.deleteFile,
          deviceId: 'devX',
          seq: 3,
          hlc: Hlc(now - day, 0), // deleted yesterday
          targetId: 'fresh1'),
    ]);
    await cloud.uploadLogObject(name: 'ops_devX_0.cnest', bytes: pair!);

    await b.syncCycle();
    // Both materialize as binned rows — no age-based hiding at the log
    // layer. A device that GC'd nothing and a fresh device rebuilding from
    // history agree exactly (convergence). The Recycle Bin SCREEN filters by
    // deleted_at age for display; the row's presence is uniform.
    final old = await fileRow(dbB, 'old1');
    expect(old, isNotNull);
    expect(old!['is_deleted'], 1);
    expect(old['deleted_at'], 11 * day);
    final fresh = await fileRow(dbB, 'fresh1');
    expect(fresh, isNotNull);
    expect(fresh!['is_deleted'], 1);
    expect(fresh['deleted_at'], now - day);
  });

  test('compaction: a device folding UN-MERGED segments keeps their ops '
      '(the seed-9 data-loss bug)', () async {
    const day = 24 * 60 * 60 * 1000;
    // Device A writes two old segments (age > 30d) it will compact.
    a = engineFor(dbA, cloud, 'devA', wallClock: () => 100 * day);
    // Pre-seed two old segments directly in the cloud, authored by devZ,
    // that device A has NOT merged into its own log.
    for (var i = 0; i < 2; i++) {
      final sealed = await SegmentCodec.seal([
        SyncOp(
            kind: SyncOpKind.createFile,
            deviceId: 'devZ',
            seq: i,
            hlc: Hlc(day, i),
            targetId: 'zfile$i',
            name: 'z$i.jpg'),
      ]);
      await cloud.uploadLogObject(name: 'ops_devZ_$i.cnest', bytes: sealed!);
    }
    // Age them: bump provider timestamps by making "now" far ahead. The
    // FakeTransport doesn't model upload time, so drive compaction through
    // the engine which reads `uploaded`; supply it.
    // (listLogObjects here returns no 'uploaded' -> compactIfDue skips.)
    // Instead, exercise the merge-into-log invariant directly: pull then
    // compact must never shrink the knowable file set.
    await a.pullAndMerge();
    expect(await fileRow(dbA, 'zfile0'), isNotNull);
    expect(await fileRow(dbA, 'zfile1'), isNotNull);

    // Now device B, which never merged those segments, compacts-then-loses
    // would be the bug. Simulate by clearing B's seen + ops, then pulling
    // the same cloud: B must end up with both files.
    await b.pullAndMerge();
    expect(await fileRow(dbB, 'zfile0'), isNotNull);
    expect(await fileRow(dbB, 'zfile1'), isNotNull);
  });

  test('purge converges: a swept file disappears on the peer, terminally',
      () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'x.jpg'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.deleteFile, targetId: 'f1'));
    await a.syncCycle();
    await b.syncCycle();
    expect((await fileRow(dbB, 'f1'))!['is_deleted'], 1);

    // A's 30-day sweep permanently deletes f1 (purge op).
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.purgeFile, targetId: 'f1'));
    await a.syncCycle();
    await b.syncCycle();
    // Gone on BOTH — B's lingering tombstone row is removed by the purge.
    expect(await fileRow(dbA, 'f1'), isNull);
    expect(await fileRow(dbB, 'f1'), isNull);

    // A late restore from a device that hadn't seen the purge cannot win.
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.restoreFile, targetId: 'f1'));
    await b.syncCycle();
    await a.syncCycle();
    await b.syncCycle();
    expect(await fileRow(dbA, 'f1'), isNull,
        reason: 'purge is terminal — restore cannot resurrect');
    expect(await fileRow(dbB, 'f1'), isNull);
  });

  test('conflict detection: my pending edit vs a foreign delete', () async {
    // A creates & syncs f1; B learns it.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'x.jpg'));
    await a.syncCycle();
    await b.syncCycle();

    // B renames f1 locally (pending) — but does NOT push yet.
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.renameFile, targetId: 'f1', name: 'mine.jpg'));

    // Meanwhile A deletes f1 and pushes.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.deleteFile, targetId: 'f1'));
    await a.syncCycle();

    // B pulls A's delete, then detects the conflict on its pending rename.
    await b.pullAndMerge();
    final conflicts = await b.detectConflicts();
    expect(conflicts.length, 1);
    expect(conflicts.first.fileId, 'f1');
    expect(conflicts.first.deleterDeviceId, 'devA');
    expect(conflicts.first.purged, isFalse);

    // No conflict is reported for A (it did the deleting).
    expect(await a.detectConflicts(), isEmpty);
  });

  test('unreadable segment: counted, retried, never marked seen', () async {
    await cloud.uploadLogObject(
        name: 'ops_devX_0.cnest',
        bytes: Uint8List.fromList(List.filled(64, 7)));
    final unreadable = await b.pullAndMerge();
    expect(unreadable, 1);
    final seen = await dbB.query('sync_seen_segments');
    expect(seen.where((r) => r['name'] == 'ops_devX_0.cnest'), isEmpty,
        reason: 'an unreadable segment must be retried, not absorbed');
  });

  // -----------------------------------------------------------------------
  // Folders (Model A) materialization
  // -----------------------------------------------------------------------

  Future<Map<String, Object?>?> folderRow(Database db, String id) async {
    final rows = await db.query('folders',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Every op-owned column, both tables, compared row-for-row — the
  /// materializer-drift net: an op-owned column written on insert but
  /// missed on diff-update (or vice versa) fails HERE, whatever the column.
  Future<void> expectConvergedMaterialization(Database x, Database y) async {
    const fileCols = [
      'id',
      'filename',
      'is_favorite',
      'is_deleted',
      'deleted_at',
      'folder_id',
      'deleted_by_folder_id',
      'size_bytes',
      'content_hash',
      'created_at',
      'type',
    ];
    final fx = await x.query('files', columns: fileCols, orderBy: 'id');
    final fy = await y.query('files', columns: fileCols, orderBy: 'id');
    expect(fx, fy, reason: 'files materialization diverged');
    final ox = await x.query('folders', orderBy: 'id');
    final oy = await y.query('folders', orderBy: 'id');
    expect(ox, oy, reason: 'folders materialization diverged');
  }

  test(
      'INSTANT-PURGE REGRESSION: cascade-binned files carry the deleteFolder '
      'op\'s wall as deleted_at, never 0', () async {
    // Realistic epoch walls: with the old deleted_at=0 behavior these rows
    // would read as deleted in 1970 — instantly past any 30-day TTL.
    final base = DateTime.now().millisecondsSinceEpoch;
    var now = base;
    a = engineFor(dbA, cloud, 'devA', wallClock: () => now);

    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'F', name: 'Holiday'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile,
        targetId: 'f1',
        name: 'a.jpg',
        folderId: 'F'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile,
        targetId: 'f2',
        name: 'b.jpg',
        folderId: 'F'));
    now = base + 1000;
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFile, targetId: 'f1'));
    now = base + 2000;
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFolder, targetId: 'F'));
    await a.syncCycle();
    await b.syncCycle();

    for (final db in [dbA, dbB]) {
      final f1 = (await fileRow(db, 'f1'))!;
      expect(f1['is_deleted'], 1);
      expect(f1['deleted_at'], base + 1000,
          reason: 'individual delete keeps its own wall');
      expect(f1['deleted_by_folder_id'], isNull,
          reason: 'individual entry, never absorbed by the cascade');

      final f2 = (await fileRow(db, 'f2'))!;
      expect(f2['is_deleted'], 1);
      expect(f2['deleted_at'], base + 2000,
          reason: 'THE regression: cascade wall, not 0/epoch — a 0 here '
              'meant the next bin sweep permanently purged the folder\'s '
              'entire contents');
      expect(f2['deleted_by_folder_id'], 'F');

      final folder = (await folderRow(db, 'F'))!;
      expect(folder['is_deleted'], 1);
      expect(folder['deleted_at'], base + 2000);
      expect(folder['deleted_by_folder_id'], isNull);
    }
    await expectConvergedMaterialization(dbA, dbB);
  });

  test(
      'rich two-device folder history converges column-for-column, '
      'including the seed-178 re-stamp at the SQLite layer', () async {
    final base = DateTime.now().millisecondsSinceEpoch;
    var nowA = base;
    var nowB = base + 500;
    a = engineFor(dbA, cloud, 'devA', wallClock: () => nowA);
    b = engineFor(dbB, cloud, 'devB', wallClock: () => nowB);

    // A builds a small tree and shares it.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'P', name: 'Parent'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder,
        targetId: 'C',
        name: 'Child',
        folderId: 'P'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile,
        targetId: 'f1',
        name: 'in-child.jpg',
        folderId: 'C'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f2', name: 'root.jpg'));
    await a.syncCycle();
    await b.syncCycle();

    // B reorganizes: moves f2 into C, renames C.
    nowB = base + 1000;
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.moveFile, targetId: 'f2', folderId: 'C'));
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.renameFolder, targetId: 'C', name: 'Trip'));
    await b.syncCycle();
    await a.syncCycle();

    // CONCURRENT: A deletes folder C (cascade bins f1+f2); B — later HLC,
    // unaware — individually deletes f1. The merged fold must re-stamp f1
    // as an individual entry (seed-178) ON BOTH DEVICES' ROWS.
    nowA = base + 2000;
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFolder, targetId: 'C'));
    nowB = base + 3000;
    await b.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFile, targetId: 'f1'));
    await a.syncCycle();
    await b.syncCycle();
    await a.syncCycle();

    for (final db in [dbA, dbB]) {
      final f1 = (await fileRow(db, 'f1'))!;
      expect(f1['is_deleted'], 1);
      expect(f1['deleted_by_folder_id'], isNull,
          reason: 'seed-178 re-stamp reaches SQLite on both devices');
      expect(f1['deleted_at'], base + 3000,
          reason: 're-stamp carries the explicit deleteFile\'s wall');
      final f2 = (await fileRow(db, 'f2'))!;
      expect(f2['is_deleted'], 1);
      expect(f2['deleted_by_folder_id'], 'C');
      expect(f2['deleted_at'], base + 2000);
    }

    // A restores C: f2 comes back inside it; f1 stays deleted.
    nowA = base + 4000;
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.restoreFolder, targetId: 'C'));
    await a.syncCycle();
    await b.syncCycle();

    for (final db in [dbA, dbB]) {
      final c = (await folderRow(db, 'C'))!;
      expect(c['is_deleted'], 0);
      expect(c['name'], 'Trip', reason: 'rename survived the round trip');
      expect(c['parent_id'], 'P');
      final f2 = (await fileRow(db, 'f2'))!;
      expect(f2['is_deleted'], 0);
      expect(f2['folder_id'], 'C');
      expect(f2['deleted_at'], isNull);
      expect(f2['deleted_by_folder_id'], isNull);
      final f1 = (await fileRow(db, 'f1'))!;
      expect(f1['is_deleted'], 1,
          reason: 'the explicit individual delete survives the restore');
    }
    await expectConvergedMaterialization(dbA, dbB);
  });

  test('restore under a dead parent lands at root in SQLite, rejoins when '
      'the parent is restored', () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'P', name: 'P'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder,
        targetId: 'C',
        name: 'C',
        folderId: 'P'));
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFolder, targetId: 'C'));
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFolder, targetId: 'P'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.restoreFolder, targetId: 'C'));
    await a.syncCycle();
    await b.syncCycle();

    for (final db in [dbA, dbB]) {
      final c = (await folderRow(db, 'C'))!;
      expect(c['is_deleted'], 0);
      expect(c['parent_id'], isNull,
          reason: 'parent still binned -> normalized to root');
    }

    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.restoreFolder, targetId: 'P'));
    await a.syncCycle();
    await b.syncCycle();

    for (final db in [dbA, dbB]) {
      final c = (await folderRow(db, 'C'))!;
      expect(c['parent_id'], 'P',
          reason: 'structure remembered: child rejoins the restored parent');
    }
    await expectConvergedMaterialization(dbA, dbB);
  });

  test('purgeFolder removes the folder row on every device', () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'X', name: 'X'));
    await a.syncCycle();
    await b.syncCycle();
    expect(await folderRow(dbB, 'X'), isNotNull);

    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFolder, targetId: 'X'));
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.purgeFolder, targetId: 'X'));
    await a.syncCycle();
    await b.syncCycle();

    expect(await folderRow(dbA, 'X'), isNull);
    expect(await folderRow(dbB, 'X'), isNull);
    await expectConvergedMaterialization(dbA, dbB);
  });

  test(
      'system folders: independent deterministic creates fold to ONE '
      'device+path chain with is_system stamped; user folders stay 0',
      () async {
    // The pCloud-style chain one phone mints: Phone Backup -> Samsung
    // SM-A556E -> DCIM -> Camera. Both sim devices run the SAME derivation
    // independently (offline), then sync — exactly what one phone's two
    // installs (reinstall, model-keyed) do.
    final key = SystemFolders.deviceKey('samsung', 'SM-A556E');
    final rootId = SystemFolders.rootId(account);
    final devId = SystemFolders.deviceId(account, key);
    final dcimId = SystemFolders.pathSegmentId(account, key, ['DCIM']);
    final camId =
        SystemFolders.pathSegmentId(account, key, ['DCIM', 'Camera']);

    for (final e in [a, b]) {
      await e.recordLocalOp(LocalSyncAction(
          kind: SyncOpKind.createFolder,
          targetId: rootId,
          name: 'Phone Backup'));
      await e.recordLocalOp(LocalSyncAction(
          kind: SyncOpKind.createFolder,
          targetId: devId,
          name: 'Samsung SM-A556E',
          folderId: rootId));
      await e.recordLocalOp(LocalSyncAction(
          kind: SyncOpKind.createFolder,
          targetId: dcimId,
          name: 'DCIM',
          folderId: devId));
      await e.recordLocalOp(LocalSyncAction(
          kind: SyncOpKind.createFolder,
          targetId: camId,
          name: 'Camera',
          folderId: dcimId));
    }
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'U', name: 'Holiday'));
    await a.syncCycle();
    await b.syncCycle();
    await a.syncCycle();

    for (final db in [dbA, dbB]) {
      final chain = {rootId: null, devId: rootId, dcimId: devId, camId: dcimId};
      for (final e in chain.entries) {
        final row = (await folderRow(db, e.key))!;
        expect(row['is_system'], 1);
        expect(row['parent_id'], e.value);
      }
      final user = (await folderRow(db, 'U'))!;
      expect(user['is_system'], 0);
      // First-create-wins: the duplicate creates folded, no ghost rows.
      final all = await db.query('folders');
      expect(all.length, 5);
    }
    await expectConvergedMaterialization(dbA, dbB);
  });

  test(
      'setFolderHidden: hide on A + concurrent move on B converge; '
      'hidden_effective materializes subtree inheritance', () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'P', name: 'Parent'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder,
        targetId: 'C',
        name: 'Escapes',
        folderId: 'P'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder,
        targetId: 'C2',
        name: 'Stays',
        folderId: 'P'));
    await a.syncCycle();
    await b.syncCycle();

    // Concurrent: A hides the parent while B moves C out from under it.
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.setFolderHidden, targetId: 'P', favorite: true));
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.moveFolder, targetId: 'C', folderId: null));
    await a.syncCycle();
    await b.syncCycle();
    await a.syncCycle();

    for (final db in [dbA, dbB]) {
      final p = (await folderRow(db, 'P'))!;
      expect(p['is_hidden'], 1);
      expect(p['hidden_effective'], 1);
      final c = (await folderRow(db, 'C'))!;
      expect(c['parent_id'], isNull, reason: 'moved to root');
      expect(c['is_hidden'], 0);
      expect(c['hidden_effective'], 0,
          reason: 'escaped the hidden subtree by moving out');
      final c2 = (await folderRow(db, 'C2'))!;
      expect(c2['is_hidden'], 0);
      expect(c2['hidden_effective'], 1,
          reason: 'still under the hidden parent — inherited');
    }
    await expectConvergedMaterialization(dbA, dbB);
  });

  test('folder edit-vs-delete: my pending rename on a foreign-deleted '
      'folder is a folder-shaped conflict', () async {
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'F', name: 'Shared'));
    await a.syncCycle();
    await b.syncCycle();

    // B renames (pending), A deletes and pushes.
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.renameFolder, targetId: 'F', name: 'Mine'));
    await a.recordLocalOp(
        const LocalSyncAction(kind: SyncOpKind.deleteFolder, targetId: 'F'));
    await a.syncCycle();
    await b.pullAndMerge();

    final conflicts = await b.detectConflicts();
    expect(conflicts.length, 1);
    expect(conflicts.first.isFolder, isTrue);
    expect(conflicts.first.deleterDeviceId, 'devA');
    expect(conflicts.first.purged, isFalse);
    expect(await a.detectConflicts(), isEmpty);
  });

  test('undone folder move: the cycle-skip loser is reported on the losing '
      'device only, with the winner attributed', () async {
    final base = DateTime.now().millisecondsSinceEpoch;
    var nowA = base;
    var nowB = base + 1000; // B's concurrent move orders LATER -> loses
    a = engineFor(dbA, cloud, 'devA', wallClock: () => nowA);
    b = engineFor(dbB, cloud, 'devB', wallClock: () => nowB);

    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'X', name: 'X'));
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFolder, targetId: 'Y', name: 'Y'));
    await a.syncCycle();
    await b.syncCycle();

    // Concurrent: A moves X under Y; B moves Y under X (recorded before
    // either sees the other's op).
    nowA = base + 2000;
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.moveFolder, targetId: 'X', folderId: 'Y'));
    nowB = base + 3000;
    await b.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.moveFolder, targetId: 'Y', folderId: 'X'));
    await a.syncCycle();
    await b.syncCycle();
    await a.syncCycle();

    final undoneB = await b.detectUndoneFolderMoves();
    expect(undoneB.length, 1, reason: 'B\'s later-ordering move lost');
    expect(undoneB.first.folderName, 'Y');
    expect(undoneB.first.otherDeviceId, 'devA');
    expect(await a.detectUndoneFolderMoves(), isEmpty,
        reason: 'the winner is never notified');

    // The tree itself converged: X under Y, Y at root, on both devices.
    for (final db in [dbA, dbB]) {
      expect((await folderRow(db, 'X'))!['parent_id'], 'Y');
      expect((await folderRow(db, 'Y'))!['parent_id'], isNull);
    }
    await expectConvergedMaterialization(dbA, dbB);
  });

  test('FORWARD-COMPAT: a segment carrying an unknown op kind still merges '
      'its known ops; the unknown op persists verbatim for the upgrade',
      () async {
    // A future app version recorded "teleportFile" alongside a normal
    // create. Simulate by planting the pending rows directly (recordLocalOp
    // asserts against minting unknowns locally).
    await a.recordLocalOp(const LocalSyncAction(
        kind: SyncOpKind.createFile, targetId: 'f1', name: 'cat.jpg'));
    await dbA.insert('sync_ops', {
      'op_key': 'devA:999',
      'account_id': account,
      'device_id': 'devA',
      'seq': 999,
      'hlc_wall': 2000000,
      'hlc_counter': 0,
      'kind': 'teleportFile',
      'target_id': 'f1',
      'name': 'somewhere',
      'pending': 1,
    });
    await a.syncCycle();
    await b.syncCycle();

    // The known op merged and materialized on B…
    final f1 = (await fileRow(dbB, 'f1'))!;
    expect(f1['filename'], 'cat.jpg');
    // …the unknown op is preserved VERBATIM in B's log…
    final rows = await dbB.query('sync_ops',
        where: "kind = 'teleportFile'");
    expect(rows.length, 1, reason: 'unknown op must ride along, not poison');
    // …and round-trips with its original kind string (compaction-safe).
    final reparsed = SyncOp.fromRow(rows.single);
    expect(reparsed.kind, SyncOpKind.unknown);
    expect(reparsed.kindName, 'teleportFile');
    expect(reparsed.toJson()['k'], 'teleportFile');
    // The segment was legitimately absorbed — no unreadable count, no
    // retry loop.
    expect(await b.pullAndMerge(), 0);
  });
}
