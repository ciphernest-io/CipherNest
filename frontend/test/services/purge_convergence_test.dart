/// Permanent deletion must CONVERGE, never resurrect.
///
/// The bug this pins down: "Delete forever" hard-deletes the row and records
/// a purgeFile tombstone, but the cloud-blob delete is best-effort. When it
/// failed (silently), the orphaned blob survived in Drive and every sync
/// cycle re-adopted it via reconcile — the photo came back, cloud-only,
/// forever, no matter how many times it was deleted again.
///
/// Fix under test:
///  1. reconcile skips blobs owned by a purged file id (no re-adoption);
///  2. SyncService.condemnedBlobCloudIds identifies those blobs (main +
///     thumb) so the cycle can retry the cloud delete until it lands.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/sync_service.dart';

const _acct = 'google_test@example.com';

Map<String, Object?> _purgeOp(String targetId) => {
      'op_key': 'devA:$targetId:purge',
      'account_id': _acct,
      'device_id': 'devA',
      'seq': 0,
      'hlc_wall': 1000,
      'hlc_counter': 0,
      'kind': 'purgeFile',
      'target_id': targetId,
      'pending': 0,
    };

Map<String, dynamic> _blob(String cloudId, String name, {int size = 100}) => {
      'id': cloudId,
      'name': name,
      'size': size,
      'created': '2026-07-01T00:00:00.000Z',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  group('blobOwnerId', () {
    test('derives the owning file id from vault blob names', () {
      expect(DatabaseService.blobOwnerId('uuid-1.cnest', 'c1'), 'uuid-1');
      expect(
          DatabaseService.blobOwnerId('uuid-1_thumb.cnest', 'c2'), 'uuid-1');
      expect(DatabaseService.blobOwnerId('legacy-name', 'c3'), 'c3');
    });
  });

  group('condemnedBlobCloudIds', () {
    test('flags main + thumb blobs of purged ids, leaves the living alone',
        () {
      final listing = [
        _blob('c-main', 'uuid-purged.cnest'),
        _blob('c-thumb', 'uuid-purged_thumb.cnest'),
        _blob('c-live', 'uuid-live.cnest'),
        _blob('c-live-thumb', 'uuid-live_thumb.cnest'),
        <String, dynamic>{'name': 'no-id.cnest'}, // defensive: id missing
      ];
      final condemned =
          SyncService.condemnedBlobCloudIds(listing, {'uuid-purged'});
      expect(condemned, unorderedEquals(['c-main', 'c-thumb']));
    });

    test('empty purge set condemns nothing', () {
      final listing = [_blob('c1', 'uuid-1.cnest')];
      expect(SyncService.condemnedBlobCloudIds(listing, {}), isEmpty);
    });
  });

  group('reconcile with purge tombstones', () {
    late Database db;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await DatabaseService.createSchemaForTest(db);
      await DatabaseService.createSyncSchemaForTest(db);
      DatabaseService().debugSetDatabase(db);
    });

    tearDown(() async {
      await DatabaseService().closeDatabase();
    });

    test('a purged blob is NEVER re-adopted; a living one is', () async {
      await db.insert('sync_ops', _purgeOp('uuid-purged'));

      await DatabaseService().reconcile(
        [
          _blob('c-main', 'uuid-purged.cnest'),
          _blob('c-thumb', 'uuid-purged_thumb.cnest'),
          _blob('c-new', 'uuid-new.cnest'),
        ],
        accountId: _acct,
      );

      final rows = await db.query('files');
      expect(rows, hasLength(1));
      expect(rows.single['id'], 'uuid-new');
      expect(rows.single['cloud_id'], 'c-new');
    });

    test('resurrection loop is dead: purge row-delete + reconcile converge',
        () async {
      // The exact production loop: the op-log purge pass hard-deletes the
      // row each cycle, then reconcile runs against a listing that still
      // contains the orphaned blob. Before the fix the row came back every
      // cycle; now repeated cycles stay converged on "gone".
      await db.insert('sync_ops', _purgeOp('uuid-ghost'));
      final listing = [
        _blob('c-ghost', 'uuid-ghost.cnest'),
        _blob('c-ghost-thumb', 'uuid-ghost_thumb.cnest'),
      ];

      for (var cycle = 0; cycle < 3; cycle++) {
        await DatabaseService()
            .reconcile(List.of(listing), accountId: _acct);
        final rows = await db.query('files');
        expect(rows, isEmpty, reason: 'cycle $cycle resurrected the ghost');
      }
    });

    test('purge tombstones are account-scoped', () async {
      await db.insert('sync_ops', _purgeOp('uuid-x'));

      // Same blob name under a DIFFERENT account: not condemned there.
      await DatabaseService().reconcile(
        [_blob('c-x', 'uuid-x.cnest')],
        accountId: 'google_other@example.com',
      );

      final rows = await db.query('files');
      expect(rows, hasLength(1));
      expect(rows.single['account_id'], 'google_other@example.com');
    });
  });
}
