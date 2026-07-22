/// The deterministic leftover-reclaim sweep's pure seams.
///
/// Scenario it exists for: local original deleted from the phone gallery →
/// surfaces legitimately download the decrypted thumb → original restored →
/// the opportunistic UI reclaims never fire (grid session memo skips the
/// ladder; Stories selection may not include the file) → the leftover
/// lingered. The sweep maps every cache artifact to its owning row and
/// reclaims once the row's MediaStore asset verifiably serves again.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/cache_manager_service.dart';
import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/src/models/file_model.dart';

const _acct = 'google_test@example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() {
    databaseFactory = databaseFactoryFfi;
  });

  group('cacheArtifactOwner', () {
    test('maps every managed artifact pattern to its owner', () {
      expect(CacheManagerService.cacheArtifactOwner('thumb_c1.jpg'),
          ('cloud', 'c1'));
      expect(CacheManagerService.cacheArtifactOwner('thumb_local_f1.jpg'),
          ('file', 'f1'));
      expect(CacheManagerService.cacheArtifactOwner('c1_decrypted.jpg'),
          ('cloud', 'c1'));
      expect(CacheManagerService.cacheArtifactOwner('f1_decrypted.mp4'),
          ('file', 'f1'));
      expect(CacheManagerService.cacheArtifactOwner('video_c1.plain'),
          ('cloud', 'c1'));
      expect(CacheManagerService.cacheArtifactOwner('video_c1.plain.done'),
          ('cloud', 'c1'));
      expect(CacheManagerService.cacheArtifactOwner('video_c1.plain.idx'),
          ('cloud', 'c1'));
    });

    test('ignores files CipherNest does not manage', () {
      expect(CacheManagerService.cacheArtifactOwner('_wallpaper_tmp.jpg'),
          isNull);
      expect(CacheManagerService.cacheArtifactOwner('journal.bin'), isNull);
      expect(CacheManagerService.cacheArtifactOwner('video_c1.mp4'), isNull);
      expect(CacheManagerService.cacheArtifactOwner('thumb_c1.png'), isNull);
    });
  });

  group('getMediaStoreBoundFiles', () {
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
      String? cloudId,
      String? assetId,
      String account = _acct,
    }) {
      return db.insert('files', {
        'id': id,
        'account_id': account,
        'cloud_id': cloudId,
        'asset_id': assetId,
        'filename': '$id.mp4',
        'size_bytes': 10,
        'created_at': 1700000000000,
        'is_uploaded': 1,
        'is_deleted': 0,
        'type': CnestFileType.image.index,
      });
    }

    test('returns only MediaStore-bound owners of the given artifacts',
        () async {
      await insertRow(id: 'f1', cloudId: 'c1', assetId: 'a1'); // by cloud id
      await insertRow(id: 'f2', cloudId: 'c2', assetId: 'a2'); // by row id
      await insertRow(id: 'f3', cloudId: 'c3', assetId: null); // no asset
      await insertRow(id: 'f4', cloudId: 'c4', assetId: 'a4'); // not queried
      await insertRow(
          id: 'f5', cloudId: 'c5', assetId: 'a5', account: 'other'); // foreign

      final rows = await DatabaseService().getMediaStoreBoundFiles(
        cloudIds: {'c1', 'c3', 'c5'},
        fileIds: {'f2'},
      );
      expect(rows.map((r) => r.id), unorderedEquals(['f1', 'f2']));
    });

    test('empty artifact sets return empty without querying', () async {
      final rows = await DatabaseService()
          .getMediaStoreBoundFiles(cloudIds: {}, fileIds: {});
      expect(rows, isEmpty);
    });
  });
}
