/// addFile must carry the caller's placement/flags into the inserted row.
/// The regression: the hand-rebuilt CnestFile inside addFile dropped
/// folderId (and isFavorite / deletedByFolderId), so every upload flashed
/// at the vault root until op-replay re-stamped folder_id.
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

  test('addFile stamps folderId and isFavorite on the INSERTED row', () async {
    await DatabaseService().addFile(CnestFile(
      id: 'f1',
      filename: 'a.jpg',
      sizeBytes: 10,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      type: CnestFileType.image,
      folderId: 'F',
      isFavorite: true,
    ));
    final row = (await db.query('files', where: "id = 'f1'")).single;
    expect(row['folder_id'], 'F',
        reason: 'placement must be visible immediately, not after replay');
    expect(row['is_favorite'], 1);
  });

  test('markAsUploaded heals a NULL-folder row when given folderId; null '
      'leaves placement alone', () async {
    await db.insert('files', {
      'id': 'f2',
      'account_id': _acct,
      'filename': 'b.jpg',
      'size_bytes': 5,
      'created_at': 1700000000000,
      'is_uploaded': 0,
      'is_deleted': 0,
      'type': CnestFileType.image.index,
    });
    await DatabaseService()
        .markAsUploaded('f2', 'cloud-2', null, folderId: 'F');
    var row = (await db.query('files', where: "id = 'f2'")).single;
    expect(row['folder_id'], 'F');

    // A second call WITHOUT folderId must not clobber the placement.
    await DatabaseService().markAsUploaded('f2', 'cloud-2b', null);
    row = (await db.query('files', where: "id = 'f2'")).single;
    expect(row['folder_id'], 'F');
  });
}
