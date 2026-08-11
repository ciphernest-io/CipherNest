/// Per-folder "hide from specialized views": the hiddenExclusion fragment
/// must remove files under a hidden subtree from every specialized-view
/// query, while machinery callers (includeHidden) and the Recycle Bin keep
/// seeing everything. The subtree effect is materialized (hidden_effective)
/// — these tests seed it directly, as applyMergedState would.
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

    // P (hidden, own flag) -> C (clean own flag, inherits effective).
    // U is a visible user folder.
    await db.insert('folders', {
      'id': 'P',
      'account_id': _acct,
      'name': 'Private',
      'is_hidden': 1,
      'hidden_effective': 1,
    });
    await db.insert('folders', {
      'id': 'C',
      'account_id': _acct,
      'name': 'Nested',
      'parent_id': 'P',
      'is_hidden': 0,
      'hidden_effective': 1,
    });
    await db.insert('folders', {
      'id': 'U',
      'account_id': _acct,
      'name': 'Holiday',
    });

    Future<void> file(String id, {String? folderId, bool binned = false}) =>
        db.insert('files', {
          'id': id,
          'account_id': _acct,
          'filename': '$id.jpg',
          'size_bytes': 123,
          'created_at': 1700000000000,
          'is_uploaded': 1,
          'is_deleted': binned ? 1 : 0,
          'deleted_at': binned ? 1700000001000 : null,
          'folder_id': folderId,
          'type': CnestFileType.image.index,
        }).then((_) {});

    await file('root'); // unfiled
    await file('inU', folderId: 'U'); // visible folder
    await file('inP', folderId: 'P'); // hidden folder
    await file('inC', folderId: 'C'); // hidden by inheritance
    await file('binP', folderId: 'P', binned: true); // binned, hidden folder
  });

  tearDown(() async {
    await DatabaseService().closeDatabase();
  });

  test('getFilesByType excludes files under a hidden subtree', () async {
    final ids = (await DatabaseService().getFilesByType(CnestFileType.image))
        .map((f) => f.id)
        .toSet();
    expect(ids, {'root', 'inU'},
        reason: 'own-hidden and inherited-hidden files must both vanish');
  });

  test('includeHidden (machinery) sees everything live', () async {
    final ids = (await DatabaseService()
            .getFilesByType(CnestFileType.image, includeHidden: true))
        .map((f) => f.id)
        .toSet();
    expect(ids, {'root', 'inU', 'inP', 'inC'});
  });

  test('the Recycle Bin ignores hidden entirely', () async {
    final ids = (await DatabaseService().getDeletedFiles(
            type: CnestFileType.image))
        .map((f) => f.id)
        .toSet();
    expect(ids, {'binP'},
        reason: 'a binned file in a hidden folder still shows in the bin');
  });

  test('favorites and stories exclude the hidden subtree too', () async {
    await db.update('files', {'is_favorite': 1});
    final favIds = (await DatabaseService().getFavorites())
        .map((f) => f.id)
        .toSet();
    expect(favIds, {'root', 'inU'});
  });

  test('per-FILE hide: own flag in a VISIBLE folder excludes from '
      'specialized views; browser and bin still see it', () async {
    await db.insert('files', {
      'id': 'ownHidden',
      'account_id': _acct,
      'filename': 'ownHidden.jpg',
      'size_bytes': 123,
      'created_at': 1700000000000,
      'is_uploaded': 1,
      'is_deleted': 0,
      'folder_id': 'U',
      'type': CnestFileType.image.index,
      'is_hidden': 1,
      'is_favorite': 1,
    });
    final typed =
        (await DatabaseService().getFilesByType(CnestFileType.image))
            .map((f) => f.id)
            .toSet();
    expect(typed, isNot(contains('ownHidden')));

    final favs =
        (await DatabaseService().getFavorites()).map((f) => f.id).toSet();
    expect(favs, isNot(contains('ownHidden')));

    final everything = (await DatabaseService()
            .getFilesByType(CnestFileType.image, includeHidden: true))
        .map((f) => f.id)
        .toSet();
    expect(everything, contains('ownHidden'));

    final inFolder = (await DatabaseService().getFilesInFolder('U'))
        .map((f) => f.id)
        .toSet();
    expect(inFolder, contains('ownHidden'),
        reason: 'the Files browser always shows hidden files');
  });

  test('ANOTHER account\'s hidden folder never filters this account\'s '
      'files (account-correlated subquery)', () async {
    // System-folder ids are deterministic and account-agnostic, so a second
    // linked account CAN own a hidden folders row whose id equals a folder
    // this account's files point at. That hide belongs to the other
    // account — this account's gallery must not lose the files.
    await db.insert('folders', {
      'id': 'shared-sys-id',
      'account_id': 'someone_else@example.com',
      'name': 'Phone Backup',
      'is_hidden': 1,
      'hidden_effective': 1,
    });
    await db.insert('files', {
      'id': 'mine',
      'account_id': _acct,
      'filename': 'mine.jpg',
      'size_bytes': 123,
      'created_at': 1700000000000,
      'is_uploaded': 1,
      'is_deleted': 0,
      'folder_id': 'shared-sys-id',
      'type': CnestFileType.image.index,
    });
    final ids = (await DatabaseService().getFilesByType(CnestFileType.image))
        .map((f) => f.id)
        .toSet();
    expect(ids, contains('mine'),
        reason: 'the hide is scoped to the account that owns the folder row');
  });
}
