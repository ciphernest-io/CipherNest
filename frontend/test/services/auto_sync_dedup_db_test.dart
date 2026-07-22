/// getAutoSyncDedupIndex against real SQLite (ffi): the ghost-photo law.
/// A STALE pending row must never hide its asset from the auto-sync scan;
/// completed uploads, fresh in-flight attempts, and stable asset-id matches
/// must.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ciphernest/services/database_service.dart';
import 'package:ciphernest/src/models/file_model.dart';

const _account = 'g_dedup_test@example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  setUpAll(() async {
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    DatabaseService().setCurrentAccount(_account);
    final db = await DatabaseService().database;
    await db.delete('files', where: 'account_id = ?', whereArgs: [_account]);
  });

  Future<void> insertRow({
    required String id,
    required String filename,
    required int size,
    required bool uploaded,
    String? assetId,
    int? uploadStartedAt,
  }) async {
    final db = await DatabaseService().database;
    await db.insert('files', {
      'id': id,
      'account_id': _account,
      'filename': filename,
      'size_bytes': size,
      'created_at': 1700000000000,
      'is_uploaded': uploaded ? 1 : 0,
      'asset_id': assetId,
      'upload_started_at': uploadStartedAt,
      'is_deleted': 0,
      'type': CnestFileType.image.index,
    });
  }

  test('uploaded row hides its filename|size key', () async {
    await insertRow(
        id: 'u1', filename: 'a.jpg', size: 10, uploaded: true);
    final idx = await DatabaseService().getAutoSyncDedupIndex();
    expect(idx.uploadedKeys, contains('a.jpg|10'));
    expect(idx.inFlightKeys, isNot(contains('a.jpg|10')));
  });

  test('STALE pending row does NOT hide its asset (the ghost bug)', () async {
    final staleAttempt = DateTime.now()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    await insertRow(
        id: 'p1',
        filename: 'b.jpg',
        size: 20,
        uploaded: false,
        uploadStartedAt: staleAttempt);
    final idx = await DatabaseService().getAutoSyncDedupIndex();
    expect(idx.uploadedKeys, isNot(contains('b.jpg|20')));
    expect(idx.inFlightKeys, isNot(contains('b.jpg|20')));
  });

  test('pending row with NULL attempt (pre-v12) does not hide its asset',
      () async {
    await insertRow(id: 'p2', filename: 'c.jpg', size: 30, uploaded: false);
    final idx = await DatabaseService().getAutoSyncDedupIndex();
    expect(idx.uploadedKeys, isNot(contains('c.jpg|30')));
    expect(idx.inFlightKeys, isNot(contains('c.jpg|30')));
  });

  test('FRESH pending attempt still dedups (upload racing right now)',
      () async {
    await insertRow(
        id: 'p3',
        filename: 'd.jpg',
        size: 40,
        uploaded: false,
        uploadStartedAt: DateTime.now().millisecondsSinceEpoch);
    final idx = await DatabaseService().getAutoSyncDedupIndex();
    expect(idx.inFlightKeys, contains('d.jpg|40'));
  });

  test('asset id matches regardless of upload state or rename', () async {
    // Renamed row ("photo (1).jpg") no longer matches the gallery key, but
    // the MediaStore asset id is stable identity.
    await insertRow(
        id: 'r1',
        filename: 'photo (1).jpg',
        size: 50,
        uploaded: true,
        assetId: 'asset-123');
    final idx = await DatabaseService().getAutoSyncDedupIndex();
    expect(idx.knownAssetIds, contains('asset-123'));
    expect(idx.uploadedKeys, isNot(contains('photo.jpg|50')));
  });

  test('recycle-bin rows STAY in every set (restorable = still known)',
      () async {
    // Overrules the original "binned rows are invisible" rule: a binned
    // file is still this asset's vault copy. Treating it as unknown made
    // auto-sync re-upload the gallery original as a full duplicate blob
    // (and manual re-upload reuse its name — see recycle_bin_dedup_test).
    // Only a purge (hard delete) frees identity.
    final db = await DatabaseService().database;
    await db.insert('files', {
      'id': 'del1',
      'account_id': _account,
      'filename': 'e.jpg',
      'size_bytes': 60,
      'created_at': 1700000000000,
      'is_uploaded': 1,
      'asset_id': 'asset-del',
      'is_deleted': 1,
      'type': CnestFileType.image.index,
    });
    final idx = await DatabaseService().getAutoSyncDedupIndex();
    expect(idx.uploadedKeys, contains('e.jpg|60'));
    expect(idx.knownAssetIds, contains('asset-del'));
  });

  test('rollbackFailedUpload records NO purgeFile sync op', () async {
    await insertRow(id: 'rb1', filename: 'f.jpg', size: 70, uploaded: false);
    await DatabaseService().rollbackFailedUpload('rb1');
    final db = await DatabaseService().database;
    final rows = (await db.query('files',
        where: 'id = ?', whereArgs: ['rb1']));
    expect(rows, isEmpty);
    final ops = await db.query('sync_ops',
        where: "target_id = 'rb1' AND kind = 'purgeFile'");
    expect(ops, isEmpty);
  });
}
