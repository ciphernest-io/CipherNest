/// Prior-key flagging (MTR#1 B3): blobs sealed under a PREVIOUS vault key
/// must never be adopted as normal, openable rows.
///
/// After "Start over" on a populated cloud, reconcile adopted the old-key
/// blobs unconditionally; they rendered as normal files and every open died
/// with a raw SecretBoxAuthenticationError. Fix under test: reconcile stamps
/// `prior_key = 1` when sealed metadata will not open under our key, the
/// start-over flow bulk-stamps the known-foreign blob set, and the Settings
/// cleanup path hard-deletes only flagged rows.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

const _acct = 'google_test@example.com';

Map<String, dynamic> _blob(String cloudId, String name,
        {int size = 100, String? sealedMeta, String? legacyName}) =>
    {
      'id': cloudId,
      'name': name,
      'size': size,
      'created': '2026-07-01T00:00:00.000Z',
      if (sealedMeta != null) 'sealed_meta': sealedMeta,
      if (legacyName != null) 'original_name': legacyName,
      if (legacyName != null) 'type': 'image',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

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
    DatabaseService().setCurrentAccount(_acct);
  });

  tearDown(() async {
    await DatabaseService().closeDatabase();
  });

  test('unopenable sealed metadata adopts FLAGGED; legacy plaintext does not',
      () async {
    await DatabaseService().reconcile(
      [
        // Sealed metadata that cannot open under our (absent) key — the
        // foreign-vault shape.
        _blob('c-foreign', 'uuid-foreign.cnest',
            sealedMeta: 'bm90LXJlYWwtc2VhbGVkLWJsb2I='),
        // Transition-era plaintext name, no sealed blob: resolvable, so it
        // adopts as a normal row.
        _blob('c-legacy', 'uuid-legacy.cnest', legacyName: 'photo.jpg'),
      ],
      accountId: _acct,
    );

    final rows = {
      for (final r in await db.query('files')) r['id'] as String: r
    };
    expect(rows, hasLength(2));
    expect(rows['uuid-foreign']!['prior_key'], 1);
    expect(rows['uuid-legacy']!['prior_key'], 0);
  });

  test('markPriorKeyByCloudIds flags via main OR thumb cloud id', () async {
    await DatabaseService().reconcile(
      [
        _blob('c-a', 'uuid-a.cnest', legacyName: 'a.jpg'),
        _blob('c-b', 'uuid-b.cnest', legacyName: 'b.jpg'),
        _blob('c-b-thumb', 'uuid-b_thumb.cnest'),
        _blob('c-c', 'uuid-c.cnest', legacyName: 'c.jpg'),
      ],
      accountId: _acct,
    );

    // Start-over "keep" path: the whole pre-existing listing is foreign —
    // including legacy-plaintext blobs whose names resolved fine.
    await DatabaseService().markPriorKeyByCloudIds(['c-a', 'c-b-thumb']);

    final rows = {
      for (final r in await db.query('files')) r['id'] as String: r
    };
    expect(rows['uuid-a']!['prior_key'], 1);
    expect(rows['uuid-b']!['prior_key'], 1,
        reason: 'thumb cloud id must flag its owner row');
    expect(rows['uuid-c']!['prior_key'], 0);

    expect(await DatabaseService().isPriorKeyFile('uuid-a'), isTrue);
    expect(await DatabaseService().isPriorKeyFile('uuid-c'), isFalse);
    final flagged = await DatabaseService().getPriorKeyFiles();
    expect(flagged.map((f) => f.id), unorderedEquals(['uuid-a', 'uuid-b']));
  });

  test('hardDeletePriorKeyRow removes ONLY flagged rows', () async {
    await DatabaseService().reconcile(
      [
        _blob('c-a', 'uuid-a.cnest', legacyName: 'a.jpg'),
        _blob('c-b', 'uuid-b.cnest', legacyName: 'b.jpg'),
      ],
      accountId: _acct,
    );
    await DatabaseService().markPriorKeyByCloudIds(['c-a']);

    await DatabaseService().hardDeletePriorKeyRow('uuid-a');
    await DatabaseService().hardDeletePriorKeyRow('uuid-b'); // not flagged

    final ids = [for (final r in await db.query('files')) r['id']];
    expect(ids, ['uuid-b'],
        reason: 'the guard must never hard-delete a healthy row');
  });
}
