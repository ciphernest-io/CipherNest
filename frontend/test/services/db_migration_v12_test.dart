/// v12 migration: upgrading a v11 database must yield a `files` table
/// column-identical to a fresh v12 create — additive-only, no data loss.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

/// The `files` DDL exactly as v11 shipped it (pre upload_started_at /
/// width / height / duration_ms).
const _v11FilesDdl = '''
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
    type INTEGER,
    content_hash TEXT
  )
''';

Future<Set<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}


/// Albums DDL as it shipped from v8 onward (no account_id) — present in
/// every real DB these fixtures model; the v19 step ALTERs it.
const _legacyAlbumsDdl = '''
  CREATE TABLE albums(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    cover_file_id TEXT,
    is_smart INTEGER DEFAULT 0,
    smart_query TEXT,
    kind TEXT NOT NULL DEFAULT 'photo',
    created_at INTEGER,
    updated_at INTEGER
  )
''';

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

  test('v11 -> v12 upgrade matches fresh create column-for-column', () async {
    // Fresh create at current version.
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    final freshCols = await _columns(fresh, 'files');

    // v11 database with a row, upgraded through the real chain.
    final old = await newDb();
    await old.execute(_v11FilesDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.insert('files', {
      'id': 'f1',
      'filename': 'photo.jpg',
      'size_bytes': 123,
      'created_at': 1700000000000,
      'is_uploaded': 1,
      'type': 0,
    });
    await old.execute(_legacyAlbumsDdl);
    await DatabaseService.migrateForTest(old, 11);
    final upgradedCols = await _columns(old, 'files');

    expect(upgradedCols, freshCols);
    expect(
      upgradedCols,
      containsAll(['upload_started_at', 'width', 'height', 'duration_ms']),
    );

    // Existing row survives with nulls in the new columns.
    final row = (await old.query('files', where: "id = 'f1'")).single;
    expect(row['filename'], 'photo.jpg');
    expect(row['upload_started_at'], isNull);
    expect(row['width'], isNull);
    expect(row['height'], isNull);
    expect(row['duration_ms'], isNull);

    await fresh.close();
    await old.close();
  });

  test('v12 migration is idempotent-safe from any v>=3 start', () async {
    // Jumping from v3 straight to current must not throw (duplicate column
    // guards etc. along the chain).
    final old = await newDb();
    await old.execute('''
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
        type INTEGER
      )
    ''');
    await old.execute('''
      CREATE TABLE albums(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        cover_file_id TEXT,
        is_smart INTEGER DEFAULT 0,
        smart_query TEXT,
        created_at INTEGER,
        updated_at INTEGER
      )
    ''');
    await DatabaseService.migrateForTest(old, 4);
    final cols = await _columns(old, 'files');
    expect(
      cols,
      containsAll([
        'asset_id',
        'is_favorite',
        'is_deleted',
        'content_hash',
        'upload_started_at',
        'width',
        'height',
        'duration_ms',
      ]),
    );
    await old.close();
  });
}
