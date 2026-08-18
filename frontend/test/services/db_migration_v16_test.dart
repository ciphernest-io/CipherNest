/// v16 migration: folders.is_system. Two upgrade paths must both equal a
/// fresh create: v15 -> 16 (ALTER adds the column) and v14 -> 16 (the v15
/// branch creates the table WITH the column, the v16 ALTER must be skipped
/// or it would fail on a duplicate column).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

/// The `folders` DDL exactly as v15 shipped it (no is_system).
const _v15FoldersDdl = '''
  CREATE TABLE folders(
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    name TEXT NOT NULL,
    parent_id TEXT,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER,
    deleted_by_folder_id TEXT,
    created_at INTEGER
  )
''';

/// The `files` DDL as of v15 (v14 files + the two v15 columns).
const _v15FilesDdl = '''
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
    duration_ms INTEGER,
    video_codec TEXT,
    audio_codec TEXT,
    fps INTEGER,
    device_model TEXT,
    folder_id TEXT,
    deleted_by_folder_id TEXT
  )
''';

const _v14FilesDdl = '''
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
    duration_ms INTEGER,
    video_codec TEXT,
    audio_codec TEXT,
    fps INTEGER,
    device_model TEXT
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

  test('v15 -> v16 upgrade matches fresh create; existing rows default '
      'is_system = 0', () async {
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    final freshFolders = await _columns(fresh, 'folders');
    expect(freshFolders, contains('is_system'));

    final old = await newDb();
    await old.execute(_v15FilesDdl);
    await old.execute(_v15FoldersDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.insert('folders', {
      'id': 'F',
      'account_id': 'acct',
      'name': 'Holiday',
    });
    await old.execute(_legacyAlbumsDdl);
    await DatabaseService.migrateForTest(old, 15);

    expect(await _columns(old, 'folders'), freshFolders);
    final row = (await old.query('folders', where: "id = 'F'")).single;
    expect(row['is_system'], 0);

    await fresh.close();
    await old.close();
  });

  test('v14 -> v16 upgrade (double jump) matches fresh create', () async {
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    final freshFolders = await _columns(fresh, 'folders');
    final freshFiles = await _columns(fresh, 'files');

    final old = await newDb();
    await old.execute(_v14FilesDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.execute(_legacyAlbumsDdl);
    await DatabaseService.migrateForTest(old, 14);

    expect(await _columns(old, 'folders'), freshFolders);
    expect(await _columns(old, 'files'), freshFiles);

    await fresh.close();
    await old.close();
  });
}
