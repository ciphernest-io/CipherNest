/// v21 migration: the guard_verdicts table (persisted LocalContentGuard
/// results). v20 -> v21 is purely additive — no files/albums/folders
/// changes — so the "old" snapshot is the current schema minus the new
/// table. Also covers the verdict accessors' round-trip semantics.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

Future<Set<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

Future<bool> _tableExists(Database db, String table) async {
  final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
      [table]);
  return rows.isNotEmpty;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  Future<Database> newDb() => databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );

  test('v20 -> v21 upgrade matches fresh create', () async {
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    expect(await _tableExists(fresh, 'guard_verdicts'), isTrue);

    // v20 state: current schema minus the v21 table.
    final old = await newDb();
    await DatabaseService.createSchemaForTest(old);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.execute('DROP TABLE guard_verdicts');
    await DatabaseService.migrateForTest(old, 20);

    expect(await _tableExists(old, 'guard_verdicts'), isTrue);
    expect(await _columns(old, 'guard_verdicts'),
        await _columns(fresh, 'guard_verdicts'));
    expect(await _columns(old, 'files'), await _columns(fresh, 'files'));

    await fresh.close();
    await old.close();
  });

  test('verdict round-trip; a new (len|mtime) drops the stale sibling',
      () async {
    final db = await newDb();
    await DatabaseService.createSchemaForTest(db);
    DatabaseService().debugSetDatabase(db);

    await DatabaseService().putGuardVerdict('f1|100|111', true);
    expect(await DatabaseService().getGuardVerdict('f1|100|111'), isTrue);
    expect(await DatabaseService().getGuardVerdict('f1|100|999'), isNull);

    // Same file, new byte identity: the old verdict must never be reused.
    await DatabaseService().putGuardVerdict('f1|100|222', false);
    expect(await DatabaseService().getGuardVerdict('f1|100|111'), isNull);
    expect(await DatabaseService().getGuardVerdict('f1|100|222'), isFalse);

    // Other files are untouched by the sibling cleanup.
    await DatabaseService().putGuardVerdict('f2|5|5', true);
    await DatabaseService().putGuardVerdict('f1|100|333', true);
    expect(await DatabaseService().getGuardVerdict('f2|5|5'), isTrue);

    await db.close();
  });
}
