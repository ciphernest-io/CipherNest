import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'activity_center.dart';
import 'auto_sync_service.dart';
import 'auto_sync_worker.dart';
import 'cache_manager_service.dart';
import 'cloud/account_registry.dart';
import 'cloud/cloud_service.dart';
import 'cnest_errors.dart';
import 'database_service.dart';
import 'sync/sync_coordinator.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final ValueNotifier<int> syncNotifier = ValueNotifier<int>(0);

  bool _isSyncing = false;
  bool _rerunRequested = false;
  DateTime? _lastSyncTime;
  static const _minSyncInterval = Duration(seconds: 30);

  bool get isSyncing => _isSyncing;

  /// Outcome surface for the most recent cycle, so pull-to-refresh can be
  /// honest instead of always announcing "Sync complete": the auto-sync
  /// upload tally (null when the upload pass didn't run) and whether the
  /// cycle died on a network-shaped error before reaching it.
  AutoSyncResult? lastAutoSyncResult;
  bool lastCycleOffline = false;

  /// Syncs local DB with cloud state, cleans stale cache, and notifies listeners.
  /// [force] bypasses the debounce (for pull-to-refresh / account switch).
  ///
  /// Every cycle is PINNED to the account that is active when it starts.
  /// Switching accounts mid-cycle used to be catastrophic: reconcile would
  /// prune the NEW account's rows against the OLD account's cloud listing
  /// (rows recreated later with local_path/asset_id NULL — the gallery's
  /// local fast paths gone for good), and the before/after cloud-id diff
  /// would read "everything deleted" and wipe every cached thumbnail. Now a
  /// mid-cycle switch aborts the cycle before any cross-account write and
  /// reruns cleanly for the new account.
  Future<void> syncNow({bool force = false}) async {
    if (_isSyncing) {
      // The in-flight cycle may be for another account (it will abort at its
      // next checkpoint). Don't drop a force request — queue a rerun so the
      // newly active account gets its sync the moment the cycle ends.
      if (force) _rerunRequested = true;
      return;
    }
    if (!force &&
        _lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _minSyncInterval) {
      return;
    }

    _isSyncing = true;
    // QUIET task: cycles fire on every screen-open/pull-to-refresh and
    // usually finish in seconds — a flashing pill would be noise. It shows
    // in the expanded sheet while running; failures inside the cycle are
    // handled per-step (offline is a state, not an error toast).
    final task = ActivityCenter().start(
        kind: ActivityKind.sync,
        label: 'Syncing…',
        visibility: ActivityVisibility.quiet);
    try {
      var again = true;
      while (again) {
        _rerunRequested = false;
        final abortedOnSwitch = await _runCycle();
        again = abortedOnSwitch || _rerunRequested;
      }
    } finally {
      task.complete('Synced');
      _isSyncing = false;
    }
  }

  /// One full sync cycle for the account active at entry. Returns true when
  /// the active account changed mid-cycle and the cycle aborted — the caller
  /// reruns for the new account.
  Future<bool> _runCycle() async {
    final accountId = AccountRegistry().activeAccount?.id;
    if (accountId == null) return false;
    bool switched() => AccountRegistry().activeAccount?.id != accountId;

    lastAutoSyncResult = null;
    lastCycleOffline = false;

    try {
      // 1. Snapshot cloud IDs before reconcile (for stale cache detection)
      final oldMap =
          await DatabaseService().getCloudToLocalIdMap(accountId: accountId);
      final oldCloudIds = oldMap.keys.toSet();

      // 2. Multi-device op-log first (tombstones, renames, foreign creates
      //    land before the blob pass), then blob reconcile (fills cloud_id
      //    for op-created rows, prunes remotely-deleted blobs).
      if (switched()) return true;
      await SyncCoordinator().sync();

      // listCloudFiles resolves its provider synchronously from the active
      // account at call start, so this guard must sit immediately before the
      // call with no await in between.
      if (switched()) return true;
      final cloudFiles = await CloudService().listCloudFiles();

      if (switched()) return true;
      await DatabaseService().reconcile(
        cloudFiles.cast<Map<String, dynamic>>(),
        accountId: accountId,
      );

      // 3. Snapshot after reconcile — detect deletions
      final newMap =
          await DatabaseService().getCloudToLocalIdMap(accountId: accountId);
      final newCloudIds = newMap.keys.toSet();
      final deletedCloudIds = oldCloudIds.difference(newCloudIds);

      // 4. Clean stale cache files for remotely deleted entries
      if (deletedCloudIds.isNotEmpty) {
        await _cleanStaleCacheFiles(deletedCloudIds, oldMap);
      }

      // 4.5 Condemned-blob sweep: a blob whose file id carries a purge
      //     tombstone outlived a failed "Delete forever" cloud call (the
      //     recycle bin swallows those errors by design — the delete must
      //     not block on network). Reconcile refuses to re-adopt such blobs;
      //     this sweep retries the actual deletion every cycle until the
      //     provider lets go, so permanent deletion CONVERGES instead of
      //     leaving encrypted orphans (or, before the reconcile guard,
      //     resurrecting the photo).
      if (switched()) return true;
      final purged =
          await DatabaseService().getPurgedFileIds(accountId: accountId);
      if (purged.isNotEmpty) {
        final condemned = condemnedBlobCloudIds(
          cloudFiles.cast<Map<String, dynamic>>(),
          purged,
        );
        for (final cloudId in condemned) {
          if (switched()) return true;
          try {
            await CloudService().deleteFile(cloudId);
            debugPrint('SyncService: deleted condemned blob $cloudId');
          } catch (e) {
            // Retried next cycle — never fails the sync.
            debugPrint('SyncService: condemned blob $cloudId delete failed: $e');
          }
        }
      }

      _lastSyncTime = DateTime.now();
    } catch (e) {
      debugPrint('SyncService error: $e');
      // A network-shaped failure in the cloud steps means the whole cycle
      // is offline — record that honestly and DON'T attempt the auto-sync
      // upload pass (it would fail asset-by-asset against the same dead
      // network).
      if (classifyNetworkError(e) != null) lastCycleOffline = true;
      return switched();
    }

    try {
      // 5. If auto-sync is enabled in any mode, upload new gallery photos
      //    on this foreground pass. `background` mode also gets the same
      //    treatment — the periodic worker handles app-closed intervals,
      //    but running here too shortens the window between "you took a
      //    photo" and "it's in the vault" when the app is already open.
      if (switched()) return true;
      final mode = await AutoSyncScheduler.readMode();
      if (mode != AutoSyncMode.off) {
        // NORMAL task, created lazily on the first per-asset callback — a
        // pass that finds nothing never pills. Only wire the single-slot
        // onProgress when auto-sync is idle: overwriting a running run's
        // slot (e.g. Settings' Sync Now) would freeze ITS progress.
        ActivityTask? bTask;
        final wasIdle = !AutoSyncService().isSyncing;
        if (wasIdle) {
          AutoSyncService().onProgress = (done, total) {
            bTask ??= ActivityCenter().start(
                kind: ActivityKind.backup, label: 'Backing up…');
            bTask!.update(done,
                total: total, label: 'Backing up $done/$total');
          };
        }
        try {
          lastAutoSyncResult = await AutoSyncService().runFullSync();
        } catch (e) {
          // runFullSync has no top-level catch — without this the lazily
          // created task would run (and pin the pill) forever.
          bTask?.fail('Backup failed');
          rethrow;
        } finally {
          if (wasIdle) AutoSyncService().onProgress = null;
        }
        final r = lastAutoSyncResult;
        final t = bTask;
        if (t != null && r != null) {
          final msg = r.failed > 0
              ? '${r.synced} backed up · ${r.failed} failed'
              : '${r.synced} photo${r.synced == 1 ? '' : 's'} secured';
          r.failed > 0 ? t.fail(msg) : t.complete(msg);
        }
      }

      // 6. Notify all subscribed screens
      syncNotifier.value++;

      // 7. Enforce the cache cap. Every sync surfaces fresh thumbnails and
      //    (for pull-to-refresh in the viewer) decrypted plaintext — without
      //    a periodic sweep here, the cap only fires on app boot and when
      //    the user manually taps Save & Apply in Settings. Fire-and-forget:
      //    the sweep is best-effort and shouldn't block the caller.
      unawaited(CacheManagerService().enforceCacheLimit());

      // 8. Reclaim stale leftovers for MediaStore-served files — the
      //    deterministic counterpart to the opportunistic per-tile reclaim,
      //    covering restores the UI paths never re-verify (grid memo hits,
      //    files outside the Stories selection).
      unawaited(CacheManagerService().reclaimMediaStoreServedLeftovers());
    } catch (e) {
      debugPrint('SyncService error: $e');
    }
    return switched();
  }

  /// Cloud ids of vault blobs owned by permanently-deleted (purged) file
  /// ids — the main `<uuid>.cnest` blob and its `<uuid>_thumb.cnest`
  /// sidecar. Pure so the condemnation rule is unit-testable.
  @visibleForTesting
  static List<String> condemnedBlobCloudIds(
    List<Map<String, dynamic>> cloudFiles,
    Set<String> purgedIds,
  ) {
    final out = <String>[];
    for (final f in cloudFiles) {
      final cloudId = f['id'] as String?;
      if (cloudId == null) continue;
      final name = f['name'] as String? ?? '';
      if (purgedIds.contains(DatabaseService.blobOwnerId(name, cloudId))) {
        out.add(cloudId);
      }
    }
    return out;
  }

  Future<void> _cleanStaleCacheFiles(
    Set<String> deletedCloudIds,
    Map<String, String> oldCloudToLocal,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final deletedLocalIds = <String>{};

    for (final cloudId in deletedCloudIds) {
      if (oldCloudToLocal.containsKey(cloudId)) {
        deletedLocalIds.add(oldCloudToLocal[cloudId]!);
      }
      // Clean thumbnail and full-image cache by cloud ID
      final candidates = [
        File('${tempDir.path}/thumb_$cloudId.jpg'),
        File('${tempDir.path}/${cloudId}_decrypted.jpg'),
        File('${tempDir.path}/video_$cloudId.plain'),
        File('${tempDir.path}/video_$cloudId.plain.done'),
        File('${tempDir.path}/video_$cloudId.plain.idx'),
      ];
      for (final f in candidates) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }

    // Clean video cache by local file ID
    for (final localId in deletedLocalIds) {
      try {
        final videoFile = File('${tempDir.path}/${localId}_decrypted.mp4');
        if (await videoFile.exists()) await videoFile.delete();
      } catch (_) {}
    }
  }
}
