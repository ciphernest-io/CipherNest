/// BackupBackfillRunner SCHEDULING regressions (MTR#1 B5).
///
/// The bug class this pins down: ticking N album checkboxes fires
/// runPending once per tick, but the runner (a) silently dropped calls that
/// landed while a pass was running, (b) snapshotted the pending set once at
/// loop start so mid-run enrollments were invisible, and (c) never
/// re-checked the queue when a pass ended — so "I selected 6 albums and 1
/// backed up" until some unrelated future trigger flushed the rest.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/services/backup_backfill_runner.dart';
import 'package:ciphernest/services/backup_selection_service.dart';
import 'package:ciphernest/services/migration_service.dart';

AlbumInfo _album(String name) => AlbumInfo(
      paths: [AssetPathEntity(id: name, name: name)],
      name: name,
      count: 1,
    );

MigrationScanResult _scanWithOneAsset() => MigrationScanResult(
      assets: [
        AssetEntity(id: 'asset-1', typeInt: 1, width: 10, height: 10),
      ],
      totalBytes: 10,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BackupBackfillRunner runner;
  late List<String> migrated;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    runner = BackupBackfillRunner();
    migrated = [];
    runner.debugScan = (album) async => _scanWithOneAsset();
    runner.debugCanStore = () async => true;
    runner.debugMigrate = (album, scan) async {
      migrated.add(album.name);
      return MigrationResult(synced: 1, failed: 0, skipped: 0);
    };
  });

  tearDown(() async {
    runner.debugAlbums = null;
    runner.debugScan = null;
    runner.debugMigrate = null;
    runner.debugCanStore = null;
    // Let any coalesced rerun microtask settle before the next test.
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('albums enrolled WHILE a pass runs are drained by the same invocation',
      () async {
    runner.debugAlbums = () async => [_album('AlbumA'), _album('AlbumB')];
    await BackupSelectionService().enroll('AlbumA', backfill: true);

    final holdA = Completer<void>();
    runner.debugMigrate = (album, scan) async {
      if (album.name == 'AlbumA' && !holdA.isCompleted) {
        // Simulate a long AlbumA backfill; AlbumB is enrolled mid-flight.
        await holdA.future;
      }
      migrated.add(album.name);
      return MigrationResult(synced: 1, failed: 0, skipped: 0);
    };

    final run = runner.runPending();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await BackupSelectionService().enroll('AlbumB', backfill: true);
    holdA.complete();
    await run;

    expect(migrated, ['AlbumA', 'AlbumB'],
        reason: 'the drain loop must re-read the pending set per sweep');
    expect(await BackupSelectionService().pendingBackfills(), isEmpty);
  });

  test('a second runPending during a pass coalesces instead of double-running',
      () async {
    runner.debugAlbums = () async => [_album('AlbumA')];
    await BackupSelectionService().enroll('AlbumA', backfill: true);

    final holdA = Completer<void>();
    runner.debugMigrate = (album, scan) async {
      if (!holdA.isCompleted) await holdA.future;
      migrated.add(album.name);
      return MigrationResult(synced: 1, failed: 0, skipped: 0);
    };

    final first = runner.runPending();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    // The tick-#2 call of the field report: must return, not drop or race.
    await runner.runPending();
    holdA.complete();
    await first;
    // The coalesced rerun (if any) fires on a microtask; let it settle.
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(migrated, ['AlbumA'],
        reason: 'AlbumA cleanly cleared its flag; no double migration');
  });

  test('a failing album cannot spin the drain loop; its flag is retained',
      () async {
    runner.debugAlbums = () async => [_album('AlbumA')];
    await BackupSelectionService().enroll('AlbumA', backfill: true);
    runner.debugMigrate = (album, scan) async {
      migrated.add(album.name);
      return MigrationResult(synced: 0, failed: 1, skipped: 0);
    };

    await runner.runPending();

    expect(migrated, ['AlbumA'], reason: 'exactly one attempt this run');
    expect(await BackupSelectionService().pendingBackfills(),
        contains('albuma'),
        reason: 'failed backfill keeps its flag for the next sync cycle');
  });

  test('cancelled pass keeps the flag and stops the queue', () async {
    runner.debugAlbums = () async => [_album('AlbumA'), _album('AlbumB')];
    await BackupSelectionService().enroll('AlbumA', backfill: true);
    await BackupSelectionService().enroll('AlbumB', backfill: true);
    runner.debugMigrate = (album, scan) async {
      migrated.add(album.name);
      return MigrationResult(
          synced: 0, failed: 0, skipped: 0, cancelled: true);
    };

    await runner.runPending();

    expect(await BackupSelectionService().pendingBackfills(),
        containsAll(['albuma', 'albumb']),
        reason: 'a cancelled pass never clears flags');
  });

  test('pending albums missing from this device do not spin the loop',
      () async {
    runner.debugAlbums = () async => [_album('AlbumA')];
    await BackupSelectionService().enroll('OtherPhoneAlbum', backfill: true);

    await runner.runPending();

    expect(migrated, isEmpty);
    expect(await BackupSelectionService().pendingBackfills(),
        contains('otherphonealbum'),
        reason: 'another device\'s album keeps its flag');
  });

  test('at the Free cap the runner skips silently and keeps every flag',
      () async {
    runner.debugAlbums = () async => [_album('AlbumA'), _album('AlbumB')];
    await BackupSelectionService().enroll('AlbumA', backfill: true);
    await BackupSelectionService().enroll('AlbumB', backfill: true);
    runner.debugCanStore = () async => false;
    runner.debugMigrate = (album, scan) async {
      migrated.add(album.name);
      return MigrationResult(synced: 1, failed: 0, skipped: 0);
    };

    await runner.runPending();

    expect(migrated, isEmpty, reason: 'nothing can be stored, nothing runs');
    expect(await BackupSelectionService().pendingBackfills(),
        containsAll(['albuma', 'albumb']),
        reason: 'flags survive so the backfill resumes after an upgrade');
  });

  test('a pass that hits the cap mid-album keeps the flag and stops the queue',
      () async {
    runner.debugAlbums = () async => [_album('AlbumA'), _album('AlbumB')];
    await BackupSelectionService().enroll('AlbumA', backfill: true);
    await BackupSelectionService().enroll('AlbumB', backfill: true);
    runner.debugMigrate = (album, scan) async {
      migrated.add(album.name);
      return MigrationResult(
          synced: 3, failed: 0, skipped: 0, limitReached: true);
    };

    await runner.runPending();

    expect(migrated, ['AlbumA'], reason: 'the queue stops at the cap');
    expect(await BackupSelectionService().pendingBackfills(),
        containsAll(['albuma', 'albumb']));
  });
}
