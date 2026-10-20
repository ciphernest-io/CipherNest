/// Reconcile must not manufacture rootless files out of our own uploads.
///
/// Three mechanisms found in the 20 Oct 2026 walkthrough:
///  1. a listing that lagged a just-created blob deleted the row, and the
///     next listing re-adopted the blob at the vault root;
///  2. a pending row that reconcile had linked to its blob was still purged
///     as a phantom by the heal pass, then re-adopted at the root;
///  3. a reconcile while the vault was locked adopted every unknown sealed
///     blob as a prior-key row with a UUID name, permanently.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';

const _acct = 'google_test@example.com';

Map<String, dynamic> _blob(String cloudId, String name,
        {String? sealedMeta, String? legacyName}) =>
    {
      'id': cloudId,
      'name': name,
      'size': 100,
      'created': '2026-07-01T00:00:00.000Z',
      if (sealedMeta != null) 'sealed_meta': sealedMeta,
      if (legacyName != null) 'original_name': legacyName,
      if (legacyName != null) 'type': 'image',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUpAll(() => databaseFactory = databaseFactoryFfi);

  late Database db;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    await DatabaseService.createSchemaForTest(db);
    await DatabaseService.createSyncSchemaForTest(db);
    DatabaseService().debugSetDatabase(db);
    DatabaseService().setCurrentAccount(_acct);
  });
  tearDown(() async => DatabaseService().closeDatabase());

  Future<void> uploadedRow(String id, {int? startedAt}) => db.insert('files', {
        'id': id,
        'cloud_id': 'c-$id',
        'account_id': _acct,
        'filename': '$id.jpg',
        'size_bytes': 10,
        'created_at': 1000,
        'is_uploaded': 1,
        'type': 0,
        'folder_id': 'folder-1',
        'upload_started_at': startedAt,
      });

  group('deletion pass', () {
    test('a blob missing from ONE listing does not delete the row', () async {
      await uploadedRow('a', startedAt: 1000);
      await DatabaseService().reconcile([], accountId: _acct);
      expect(await db.query('files'), hasLength(1));
    });

    test('missing from two consecutive listings deletes it', () async {
      await uploadedRow('a', startedAt: 1000);
      await DatabaseService().reconcile([], accountId: _acct);
      await DatabaseService().reconcile([], accountId: _acct);
      expect(await db.query('files'), isEmpty);
    });

    test('a reappearance between the two misses resets the strike', () async {
      await uploadedRow('a', startedAt: 1000);
      await DatabaseService().reconcile([], accountId: _acct);
      await DatabaseService()
          .reconcile([_blob('c-a', 'a.cnest')], accountId: _acct);
      await DatabaseService().reconcile([], accountId: _acct);
      expect(await db.query('files'), hasLength(1),
          reason: 'one miss after a hit is the first strike again');
    });

    test('a fresh upload is never deleted, however many misses', () async {
      await uploadedRow('a',
          startedAt: DateTime.now().millisecondsSinceEpoch);
      for (var i = 0; i < 3; i++) {
        await DatabaseService().reconcile([], accountId: _acct);
      }
      expect(await db.query('files'), hasLength(1));
    });
  });

  group('linked pending rows', () {
    test('a pending row keeps its folder and is finalised, not re-adopted',
        () async {
      await db.insert('files', {
        'id': 'p1',
        'cloud_id': null,
        'account_id': _acct,
        'filename': 'holiday.jpg',
        'size_bytes': 10,
        'created_at': 1000,
        'is_uploaded': 0,
        'type': 0,
        'folder_id': 'folder-1',
        'local_path': '/storage/holiday.jpg',
        'width': 640,
        'height': 480,
        'upload_started_at': 1000,
      });
      await DatabaseService().reconcile(
        [_blob('c-p1', 'p1.cnest'), _blob('c-p1t', 'p1_thumb.cnest')],
        accountId: _acct,
      );
      final linked = (await db.query('files')).single;
      expect(linked['cloud_id'], 'c-p1');
      expect(linked['thumbnail_cloud_id'], 'c-p1t');
      expect(linked['is_uploaded'], 0, reason: 'linking alone is not final');

      final n = await DatabaseService().finalizeLinkedPendingUploads();
      expect(n, 1);
      final done = (await db.query('files')).single;
      expect(done['is_uploaded'], 1);
      expect(done['folder_id'], 'folder-1');
      expect(done['local_path'], '/storage/holiday.jpg');
      expect(done['width'], 640);
      expect(done['filename'], 'holiday.jpg');
    });

    test('rows in flight are left to their uploader', () async {
      await db.insert('files', {
        'id': 'p2',
        'cloud_id': 'c-p2',
        'account_id': _acct,
        'filename': 'x.jpg',
        'size_bytes': 10,
        'created_at': 1000,
        'is_uploaded': 0,
        'type': 0,
      });
      final n = await DatabaseService()
          .finalizeLinkedPendingUploads(inFlight: {'p2'});
      expect(n, 0);
      expect((await db.query('files')).single['is_uploaded'], 0);
    });
  });

  group('adoption while locked', () {
    test('sealed blobs wait; unsealed legacy blobs still adopt', () async {
      KeyManagerService().lock();
      expect(KeyManagerService().isUnlocked, isFalse);
      await DatabaseService().reconcile(
        [
          _blob('c-s', 'sealed.cnest', sealedMeta: 'bm90LXJlYWw='),
          _blob('c-l', 'legacy.cnest', legacyName: 'photo.jpg'),
        ],
        accountId: _acct,
      );
      final ids = [for (final r in await db.query('files')) r['id']];
      expect(ids, ['legacy']);
    });

    test('once unlocked, an unopenable seal adopts flagged as before',
        () async {
      final keyPair = await X25519().newKeyPairFromSeed(
          Uint8List.fromList(List<int>.generate(32, (i) => i + 1)));
      KeyManagerService().installKeysForTest(
        keyPair: keyPair,
        publicKey: await keyPair.extractPublicKey(),
      );
      await DatabaseService().reconcile(
        [_blob('c-s', 'sealed.cnest', sealedMeta: 'bm90LXJlYWw=')],
        accountId: _acct,
      );
      final row = (await db.query('files')).single;
      expect(row['id'], 'sealed');
      expect(row['prior_key'], 1);
    });
  });
}
