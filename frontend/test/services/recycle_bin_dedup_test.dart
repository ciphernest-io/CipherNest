/// Recycle-bin rows must keep their names and asset-ids RESERVED.
///
/// The bug: both dedup surfaces filtered `is_deleted = 0`, so a binned
/// file was invisible to them. Manual re-upload of the same file took the
/// same name (restore → two identically-named files), and auto-sync could
/// re-upload a binned file's gallery original as a full duplicate blob.
/// Only a purge (hard delete) frees a name / asset id.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/src/models/file_model.dart';

const _acct = 'google_test@example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
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

  Future<void> insertRow({
    required String id,
    required String filename,
    required bool binned,
    String? assetId,
    int isUploaded = 1,
    int sizeBytes = 123,
  }) {
    return db.insert('files', {
      'id': id,
      'account_id': _acct,
      'filename': filename,
      'size_bytes': sizeBytes,
      'created_at': 1700000000000,
      'is_uploaded': isUploaded,
      'is_deleted': binned ? 1 : 0,
      'deleted_at': binned ? 1700000001000 : null,
      'asset_id': assetId,
      'type': CnestFileType.image.index,
    });
  }

  test('binned filenames stay reserved for duplicate-rename', () async {
    await insertRow(id: 'f1', filename: 'clip.mp4', binned: true);
    await insertRow(id: 'f2', filename: 'clip (1).mp4', binned: false);

    final names =
        await DatabaseService().getActiveFilenames(stemPrefix: 'clip');
    expect(names, containsAll(['clip.mp4', 'clip (1).mp4']));
  });

  test('binned rows stay in the auto-sync dedup index', () async {
    await insertRow(
        id: 'f1', filename: 'clip.mp4', binned: true, assetId: 'asset-9');

    final index = await DatabaseService().getAutoSyncDedupIndex();
    expect(index.uploadedKeys, contains('clip.mp4|123'));
    expect(index.knownAssetIds, contains('asset-9'));
  });

  test('purged rows DO free the name', () async {
    await insertRow(id: 'f1', filename: 'clip.mp4', binned: true);
    await db.delete('files', where: "id = 'f1'");

    final names =
        await DatabaseService().getActiveFilenames(stemPrefix: 'clip');
    expect(names, isEmpty);
  });
}
