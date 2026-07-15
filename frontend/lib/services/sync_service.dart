import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'auto_sync_service.dart';
import 'auto_sync_worker.dart';
import 'cache_manager_service.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'sync/sync_coordinator.dart';

class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final ValueNotifier<int> syncNotifier = ValueNotifier<int>(0);

  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  static const _minSyncInterval = Duration(seconds: 30);

  bool get isSyncing => _isSyncing;

  /// Syncs local DB with cloud state, cleans stale cache, and notifies listeners.
  /// [force] bypasses the debounce (for pull-to-refresh).
  Future<void> syncNow({bool force = false}) async {
    if (_isSyncing) return;
    if (!force &&
        _lastSyncTime != null &&
        DateTime.now().difference(_lastSyncTime!) < _minSyncInterval) {
      return;
    }

    _isSyncing = true;
    try {
      // 1. Snapshot cloud IDs before reconcile (for stale cache detection)
      final oldMap = await DatabaseService().getCloudToLocalIdMap();
      final oldCloudIds = oldMap.keys.toSet();

      // 2. Multi-device op-log first (tombstones, renames, foreign creates
      //    land before the blob pass), then blob reconcile (fills cloud_id
      //    for op-created rows, prunes remotely-deleted blobs).
      await SyncCoordinator().sync();
      final cloudFiles = await CloudService().listCloudFiles();
      await DatabaseService().reconcile(cloudFiles.cast<Map<String, dynamic>>());

      // 3. Snapshot after reconcile — detect deletions
      final newMap = await DatabaseService().getCloudToLocalIdMap();
      final newCloudIds = newMap.keys.toSet();
      final deletedCloudIds = oldCloudIds.difference(newCloudIds);

      // 4. Clean stale cache files for remotely deleted entries
      if (deletedCloudIds.isNotEmpty) {
        await _cleanStaleCacheFiles(deletedCloudIds, oldMap);
      }

      _lastSyncTime = DateTime.now();

      // 5. If auto-sync is enabled in any mode, upload new gallery photos
      //    on this foreground pass. `background` mode also gets the same
      //    treatment — the periodic worker handles app-closed intervals,
      //    but running here too shortens the window between "you took a
      //    photo" and "it's in the vault" when the app is already open.
      final mode = await AutoSyncScheduler.readMode();
      if (mode != AutoSyncMode.off) {
        await AutoSyncService().runFullSync();
      }

      // 6. Notify all subscribed screens
      syncNotifier.value++;

      // 7. Enforce the cache cap. Every sync surfaces fresh thumbnails and
      //    (for pull-to-refresh in the viewer) decrypted plaintext — without
      //    a periodic sweep here, the cap only fires on app boot and when
      //    the user manually taps Save & Apply in Settings. Fire-and-forget:
      //    the sweep is best-effort and shouldn't block the caller.
      unawaited(CacheManagerService().enforceCacheLimit());
    } catch (e) {
      debugPrint('SyncService error: $e');
    } finally {
      _isSyncing = false;
    }
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
