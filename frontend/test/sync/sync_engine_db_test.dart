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
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';
import 'package:ciphernest/services/sync/hlc.dart';
import 'package:ciphernest/services/sync/segment_codec.dart';
import 'package:ciphernest/services/sync/sync_engine.dart';
import 'package:ciphernest/services/sync/sync_op.dart';

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
      created_at INTEGER,
      is_uploaded INTEGER,
      local_path TEXT,
      asset_id TEXT,
      is_favorite INTEGER DEFAULT 0,
      is_deleted INTEGER DEFAULT 0,
      deleted_at INTEGER,
      type INTEGER
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
    final keyPair = await X25519().newKeyPair();
    KeyManagerService().installKeysForTest(
      keyPair: keyPair,
      publicKey: await keyPair.extractPublicKey(),
    );
  });

  setUp(() async {
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

  test('ghost rule: ancient foreign tombstones do not materialize; fresh '
      'ones do', () async {
    const day = 24 * 60 * 60 * 1000;
    final now = 100 * day;
    b = engineFor(dbB, cloud, 'devB', wallClock: () => now);

    final oldPair = await SegmentCodec.seal([
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
    await cloud.uploadLogObject(name: 'ops_devX_0.cnest', bytes: oldPair!);

    await b.syncCycle();
    expect(await fileRow(dbB, 'old1'), isNull,
        reason: 'tombstone older than the bin TTL must not ghost into a '
            'fresh device');
    final fresh = await fileRow(dbB, 'fresh1');
    expect(fresh, isNotNull,
        reason: 'recent tombstones surface in the bin everywhere');
    expect(fresh!['is_deleted'], 1);
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
}
