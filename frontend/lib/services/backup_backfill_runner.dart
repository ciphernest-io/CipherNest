import 'package:flutter/foundation.dart';

import 'activity_center.dart';
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

  Future<void> runPending() async {
    if (_running) return;
    // A running migration owns the pipeline; its reentrancy guard would
    // hand us an all-zero "clean" result and we'd wrongly clear the flag.
    if (MigrationService().isRunning) return;
    _running = true;
    try {
      final pending = await BackupSelectionService().pendingBackfills();
      if (pending.isEmpty) return;

      final albums = (await MigrationService().getAlbums())
          .where((a) => !a.path.isAll)
          .toList();
      final wanted = matchPending(
          pending, [for (final a in albums) a.name]).toSet();

      for (final album in albums) {
        if (!wanted.contains(album.name)) continue;
        final scan =
            await MigrationService().scanGallery(albumPaths: [album.path]);
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
          onCancel: MigrationService().cancel,
        );
        try {
          final result = await MigrationService().runMigration(
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
            // Keep the flag: the next sync cycle picks up what's left.
            task.complete('${album.name} paused — resumes next sync');
          } else {
            task.fail(
                '${album.name}: ${result.failed} failed — will retry');
          }
        } catch (e) {
          debugPrint('Backfill failed for ${album.name}: $e');
          task.fail('Could not back up ${album.name}');
        }
      }
    } finally {
      _running = false;
    }
  }
}
