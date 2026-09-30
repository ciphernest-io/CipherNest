import 'package:flutter/foundation.dart';

import 'activity_center.dart';
import 'auto_sync_service.dart';
import 'backup_selection_service.dart';
import 'migration_service.dart';
import 'system_folders.dart';

/// Runs the queued "include existing photos" backfills — one bucket-scoped
/// migration pass per pending album, with an ActivityCenter task for
/// progress when a UI is attached.
///
/// Crash/offline-safe by construction: a pending flag clears ONLY after a
/// pass with zero failures, and re-running a pass is harmless (the
/// migration scan dedups against the vault by asset id + name|size|day).
/// Callers fire this after enrollment and at the end of every auto-sync
/// cycle, so an interrupted backfill always gets another chance.
class BackupBackfillRunner {
  static final BackupBackfillRunner _instance = BackupBackfillRunner._();
  factory BackupBackfillRunner() => _instance;
  BackupBackfillRunner._();

  bool _running = false;

  /// Set when a call arrives while a pass is already running. Ticking N
  /// album checkboxes fires runPending once per tick; without this flag
  /// ticks #2..#N were dropped silently and their albums sat in
  /// pendingBackfill until some unrelated future trigger (MTR#1 B5).
  bool _rerunRequested = false;

  /// User cancel from the pill stops the WHOLE pending queue, not just the
  /// current album — MigrationService.cancel() only breaks the current
  /// runMigration (and resets its own flag on entry/exit), so without this
  /// the runner would pop the next album's task seconds after the user hit
  /// X, once per enrolled album.
  bool _cancelAll = false;

  /// Test seams: collaborator calls route through these so the SCHEDULING
  /// logic (drain loop, rerun coalescing, failure handling) is testable
  /// without MediaStore/plugin channels — the untested scheduling is
  /// exactly where B5 lived.
  @visibleForTesting
  Future<List<AlbumInfo>> Function()? debugAlbums;
  @visibleForTesting
  Future<MigrationScanResult> Function(AlbumInfo album)? debugScan;
  @visibleForTesting
  Future<MigrationResult> Function(AlbumInfo album, MigrationScanResult scan)?
      debugMigrate;

  /// The pending albums that exist on this device, in album-list order.
  /// Pure so it's testable without MediaStore.
  @visibleForTesting
  static List<String> matchPending(
      Set<String> pendingNormalized, List<String> deviceAlbumNames) {
    return [
      for (final name in deviceAlbumNames)
        if (pendingNormalized.contains(SystemFolders.normalize(name))) name,
    ];
  }

  /// [calledFromSync] = invoked from inside runFullSync, which already
  /// holds the cross-isolate run lease and has finished its upload pass —
  /// no extra guards needed. UI-triggered calls (enrollment sheets) must
  /// themselves respect the single-flight rules: never race a live
  /// incremental sync (its dedup index predates our inserts — double
  /// uploads), and never run concurrently with the OTHER isolate's sync.
  Future<void> runPending({bool calledFromSync = false}) async {
    if (_running) {
      // Coalesce instead of drop: the running pass re-reads the pending set
      // each sweep, but a call landing in its final moments would be lost —
      // the finally below fires one fresh pass to cover that window.
      _rerunRequested = true;
      return;
    }
    // A running migration owns the pipeline; its reentrancy guard would
    // hand us an all-zero "clean" result and we'd wrongly clear the flag.
    if (MigrationService().isRunning) return;
    var ownsLease = false;
    if (!calledFromSync) {
      if (AutoSyncService().isSyncing) return;
      if (!await AutoSyncService.acquireRunLease()) return;
      ownsLease = true;
    }
    _running = true;
    _cancelAll = false;
    try {
      // Sweep until the pending set is drained. The set is re-read every
      // sweep so albums enrolled WHILE a backfill runs are picked up by
      // this same invocation (the old single-snapshot loop never saw them).
      // Albums already attempted this run are excluded so a failing album
      // can't spin the loop; its flag stays for the next sync cycle.
      final attempted = <String>{};
      while (!_cancelAll) {
        final pendingAll = await BackupSelectionService().pendingBackfills();
        final pending = pendingAll.difference(attempted);
        if (pending.isEmpty) break;

        final albums = (debugAlbums != null
                ? await debugAlbums!()
                : await MigrationService().getAlbums())
            .where((a) => !a.path.isAll)
            .toList();
        final wanted = matchPending(
            pending, [for (final a in albums) a.name]).toSet();
        // Pending entries with no matching album on this device: leave the
        // flags (another device's albums), nothing more to do this run.
        if (wanted.isEmpty) break;

        for (final album in albums) {
          if (_cancelAll) break;
          if (!wanted.contains(album.name)) continue;
          attempted.add(SystemFolders.normalize(album.name));
          final scan = debugScan != null
              ? await debugScan!(album)
              : await MigrationService().scanGallery(albumPaths: album.paths);
          if (_cancelAll) break;
          if (scan.assets.isEmpty) {
            // Nothing left to vault — the backfill is (already) complete.
            await BackupSelectionService().clearBackfill(album.name);
            continue;
          }

          final task = ActivityCenter().start(
            kind: ActivityKind.backup,
            label: 'Backing up ${album.name}…',
            total: scan.assets.length,
            onPause: MigrationService().pause,
            onResume: MigrationService().resume,
            onCancel: () {
              _cancelAll = true;
              MigrationService().cancel();
            },
          );
          try {
            final result = debugMigrate != null
                ? await debugMigrate!(album, scan)
                : await MigrationService().runMigration(
                    assets: scan.assets,
                    bucketByAssetId: {
                      for (final a in scan.assets) a.id: album.name,
                    },
                    onProgress: (p) => task.update(p.current,
                        total: p.total, detail: p.currentFileName),
                  );
            if (!result.cancelled &&
                result.failed == 0 &&
                result.synced + result.skipped > 0) {
              await BackupSelectionService().clearBackfill(album.name);
              task.complete('${album.name} backed up · ${result.synced}');
            } else if (result.cancelled) {
              // User cancelled: stop importing existing photos for good.
              // The pending flags are cleared below so it never resumes;
              // enrollment stays, so NEW photos still back up.
              task.complete('${album.name} backup stopped');
            } else {
              task.fail(
                  '${album.name}: ${result.failed} failed, will retry');
            }
          } catch (e) {
            debugPrint('Backfill failed for ${album.name}: $e');
            task.fail('Could not back up ${album.name}');
          }
        }
      }
      // A user cancel stops the import of existing photos permanently:
      // drop every remaining pending flag so the next sync cycle does NOT
      // resurrect the backfill. Enrollment is untouched, so newly added
      // photos continue to back up.
      if (_cancelAll) {
        for (final name in await BackupSelectionService().pendingBackfills()) {
          await BackupSelectionService().clearBackfill(name);
        }
      }
    } finally {
      _running = false;
      if (ownsLease) await AutoSyncService.releaseRunLease();
      if (_rerunRequested && !_cancelAll) {
        _rerunRequested = false;
        // Fresh pass with its own guards/lease; never reuse this call's
        // calledFromSync context — the sync cycle that held the lease may
        // be gone by the time this fires.
        Future.microtask(() => runPending());
      } else {
        _rerunRequested = false;
      }
    }
  }
}
