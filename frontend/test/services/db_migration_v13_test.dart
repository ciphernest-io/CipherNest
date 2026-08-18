/// v13 migration: video_codec / audio_codec / fps — additive, upgrade
/// equals fresh create.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

/// The `files` DDL exactly as v12 shipped it.
const _v12FilesDdl = '''
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
    content_hash TEXT,
    upload_started_at INTEGER,
    width INTEGER,
    height INTEGER,
    duration_ms INTEGER
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

  test('v12 -> v13 upgrade matches fresh create column-for-column', () async {
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    final freshCols = await _columns(fresh, 'files');

    final old = await newDb();
    await old.execute(_v12FilesDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.insert('files', {
      'id': 'f1',
      'filename': 'clip.mp4',
      'size_bytes': 7230000,
      'created_at': 1700000000000,
      'is_uploaded': 1,
      'type': 0,
      'width': 1080,
      'height': 1920,
      'duration_ms': 3000,
    });
    await old.execute(_legacyAlbumsDdl);
    await DatabaseService.migrateForTest(old, 12);
    final upgradedCols = await _columns(old, 'files');

    expect(upgradedCols, freshCols);
    expect(
      upgradedCols,
      containsAll(['video_codec', 'audio_codec', 'fps', 'device_model']),
    );

    final row = (await old.query('files', where: "id = 'f1'")).single;
    expect(row['width'], 1080);
    expect(row['video_codec'], isNull);
    expect(row['audio_codec'], isNull);
    expect(row['fps'], isNull);

    await fresh.close();
    await old.close();
  });
}
