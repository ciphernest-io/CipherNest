/// v18 migration: files.is_hidden. The files table needs no lower guard
/// (the <3 branch recreates via _createSchema and returns), so v17 -> 18
/// and the long jump v14 -> 18 must both equal a fresh create.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';

/// The `files` DDL exactly as v17 shipped it (v15 files DDL — unchanged
/// through v16/v17; no is_hidden).
const _v17FilesDdl = '''
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

/// The `folders` DDL exactly as v17 shipped it (both hidden columns).
const _v17FoldersDdl = '''
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

  test('v17 -> v18 upgrade matches fresh create; existing rows default '
      'is_hidden = 0', () async {
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    final freshFiles = await _columns(fresh, 'files');
    expect(freshFiles, contains('is_hidden'));

    final old = await newDb();
    await old.execute(_v17FilesDdl);
    await old.execute(_v17FoldersDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await old.insert('files', {
      'id': 'F',
      'account_id': 'acct',
      'filename': 'a.jpg',
    });
    await DatabaseService.migrateForTest(old, 17);

    expect(await _columns(old, 'files'), freshFiles);
    final row = (await old.query('files', where: "id = 'F'")).single;
    expect(row['is_hidden'], 0);

    await fresh.close();
    await old.close();
  });

  test('v14 -> v18 long jump matches fresh create', () async {
    final fresh = await newDb();
    await DatabaseService.createSchemaForTest(fresh);
    await DatabaseService.createSyncSchemaForTest(fresh);
    final freshFiles = await _columns(fresh, 'files');
    final freshFolders = await _columns(fresh, 'folders');

    final old = await newDb();
    await old.execute(_v14FilesDdl);
    await DatabaseService.createSyncSchemaForTest(old);
    await DatabaseService.migrateForTest(old, 14);

    expect(await _columns(old, 'files'), freshFiles);
    expect(await _columns(old, 'folders'), freshFolders);

    await fresh.close();
    await old.close();
  });
}
