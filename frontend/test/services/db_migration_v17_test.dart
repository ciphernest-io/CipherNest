/// v17 migration: folders.is_hidden + folders.hidden_effective. Three
/// upgrade paths must all equal a fresh create: v16 -> 17 (ALTERs add both
/// columns), v15 -> 17 (v16 + v17 branches both run), and v14 -> 17 (the
/// v15 branch creates the table WITH every column, so the v16/v17 ALTERs
/// must be skipped or they would fail on duplicate columns).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

/// The `folders` DDL exactly as v16 shipped it (no hidden columns).
const _v16FoldersDdl = '''
  CREATE TABLE folders(
    id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    name TEXT NOT NULL,
    parent_id TEXT,
    is_deleted INTEGER NOT NULL DEFAULT 0,
    deleted_at INTEGER,
    deleted_by_folder_id TEXT,
    created_at INTEGER,
    is_system INTEGER NOT NULL DEFAULT 0
  )
''';

/// The `folders` DDL exactly as v15 shipped it (no is_system either).
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

/// The `files` DDL as of v15 — unchanged through v16 and v17.
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

  Future<Set<String>> freshFolderColumns(Database fresh) async {
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    return _columns(fresh, 'folders');
  }

  test('v16 -> v17 upgrade matches fresh create; existing rows default '
      'is_hidden/hidden_effective = 0', () async {
    final fresh = await newDb();
    final freshFolders = await freshFolderColumns(fresh);
    expect(freshFolders, containsAll(['is_hidden', 'hidden_effective']));

    final old = await newDb();
    await old.execute(_v15FilesDdl);
    await old.execute(_v16FoldersDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.insert('folders', {
      'id': 'F',
      'account_id': 'acct',
      'name': 'Holiday',
    });
    await DatabaseService.migrateForTest(old, 16);

    expect(await _columns(old, 'folders'), freshFolders);
    final row = (await old.query('folders', where: "id = 'F'")).single;
    expect(row['is_hidden'], 0);
    expect(row['hidden_effective'], 0);

    await fresh.close();
    await old.close();
  });

  test('v15 -> v17 upgrade (double jump) matches fresh create', () async {
    final fresh = await newDb();
    final freshFolders = await freshFolderColumns(fresh);

    final old = await newDb();
    await old.execute(_v15FilesDdl);
    await old.execute(_v15FoldersDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await DatabaseService.migrateForTest(old, 15);

    expect(await _columns(old, 'folders'), freshFolders);

    await fresh.close();
    await old.close();
  });

  test('v14 -> v17 upgrade (fresh-create-in-migration path) matches fresh '
      'create', () async {
    final fresh = await newDb();
    final freshFolders = await freshFolderColumns(fresh);
    final freshFiles = await _columns(fresh, 'files');

    final old = await newDb();
    await old.execute(_v14FilesDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await DatabaseService.migrateForTest(old, 14);

    expect(await _columns(old, 'folders'), freshFolders);
    expect(await _columns(old, 'files'), freshFiles);

    await fresh.close();
    await old.close();
  });
}
