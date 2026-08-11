import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../src/models/file_model.dart';
import 'activity_center.dart';
import 'cache_manager_service.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';

/// Background janitor for the soft-delete recycle bin. Runs on app start
/// (fire-and-forget) and purges rows whose deleted_at is older than the TTL.
/// For each expired row we:
///   1. Best-effort delete the encrypted cloud blob + thumb blob.
///   2. Hard-delete the SQLite row via [permanentlyDeleteFile].
///   3. Wipe any decrypted artifacts that may still be in the temp cache.
class RecycleBinService {
  static final RecycleBinService _instance = RecycleBinService._internal();
  factory RecycleBinService() => _instance;
  RecycleBinService._internal();

  /// Returns the number of rows successfully purged. Cloud or filesystem
  /// failures for individual files are swallowed so one stuck row doesn't
  /// block the rest.
  ///
  /// Folder entries sweep FIRST: a cascade-binned file expires through its
  /// folder's single bin entry (same wall, one user action = one expiry),
  /// and [DatabaseService.getExpiredDeletionIds] excludes cascade files
  /// whose folder row still exists, so the two passes never double-handle.
  Future<int> sweepRecycleBin({
    Duration ttl = const Duration(days: 30),
  }) async {
    final db = DatabaseService();
    int purged = 0;

    try {
      for (final folderId in await db.getExpiredFolderIds(ttl: ttl)) {
        purged += await purgeFolderPermanently(folderId,
            trackActivity: false);
      }
    } catch (e) {
      debugPrint('Bin sweep: folder pass failed: $e');
    }

    final List<String> expiredIds;
    try {
      expiredIds = await db.getExpiredDeletionIds(ttl: ttl);
    } catch (_) {
      return purged;
    }
    if (expiredIds.isEmpty) return purged;

    final cloudIdsByFile = await _loadCloudIds(expiredIds);
    final tempDir = await getTemporaryDirectory();
    for (final id in expiredIds) {
      if (await _purgeOneFile(db, tempDir, id, cloudIdsByFile[id])) {
        purged++;
      }
    }
    return purged;
  }

  /// Permanently deletes a binned folder: every file its cascade binned
  /// (blob + row + purgeFile op, one by one), then the folder entities
  /// (purgeFolder ops). Shared by the sweep and the bin's "Delete forever".
  /// Interruption-safe by re-tap: already-purged files are gone from the
  /// query, the folder entry remains until [purgeFolderEntity] lands, and
  /// replay treats leftover causes as individual bin entries.
  ///
  /// [trackActivity] (UI callers) pills a real batch (>= 5 files); the TTL
  /// sweep passes false — it runs inside its own quiet task.
  Future<int> purgeFolderPermanently(
    String folderId, {
    void Function(int done, int total)? onProgress,
    bool trackActivity = true,
  }) async {
    final db = DatabaseService();
    final fileIds = await db.getCascadeBinnedFileIds(folderId);
    final task = trackActivity && fileIds.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Emptying folder 0/${fileIds.length}…',
            total: fileIds.length)
        : null;
    final cloudIdsByFile = await _loadCloudIds(fileIds);
    final tempDir = await getTemporaryDirectory();
    var purged = 0;
    var done = 0;
    for (final id in fileIds) {
      if (await _purgeOneFile(db, tempDir, id, cloudIdsByFile[id])) {
        purged++;
      }
      done++;
      task?.update(done, label: 'Emptying folder $done/${fileIds.length}…');
      onProgress?.call(done, fileIds.length);
    }
    await db.purgeFolderEntity(folderId);
    // The caller's own summary names the folder — this terminal is quiet
    // history for the sheet.
    task?.complete();
    return purged;
  }

  /// One file's permanent deletion from a UI action (bin selection bar,
  /// bin viewer): best-effort blob + thumb deletes, the row + purgeFile op,
  /// temp-artifact wipe, then cache invalidation through
  /// [CacheManagerService.invalidateFile] so its ChangeNotifier fires and
  /// the Settings cache tile updates. Returns whether the row purge landed.
  Future<bool> purgeFilePermanently(CnestFile file) async {
    final ok = await _purgeOneFile(
      DatabaseService(),
      await getTemporaryDirectory(),
      file.id,
      {
        'cloud_id': file.cloudId,
        'thumbnail_cloud_id': file.thumbnailCloudId,
      },
    );
    await CacheManagerService().invalidateFile(
      fileId: file.id,
      cloudId: file.cloudId,
      thumbnailCloudId: file.thumbnailCloudId,
    );
    return ok;
  }

  /// One file's permanent deletion: best-effort blob deletes, the row +
  /// purgeFile op, temp-artifact wipe. Returns whether the row purge landed.
  Future<bool> _purgeOneFile(
    DatabaseService db,
    Directory tempDir,
    String id,
    Map<String, String?>? cloudIds,
  ) async {
    final cloudId = cloudIds?['cloud_id'];
    final thumbId = cloudIds?['thumbnail_cloud_id'];

    // A failed cloud delete never blocks the purge: the purge tombstone
    // condemns the blob and the sync cycle's condemned-blob sweep retries
    // the deletion until it lands. Log it anyway — silent swallows here
    // once hid the failure that resurrected deleted photos.
    if (cloudId != null) {
      try {
        await CloudService().deleteFile(cloudId);
      } catch (e) {
        debugPrint('Bin sweep: blob delete failed ($cloudId): $e');
      }
    }
    if (thumbId != null) {
      try {
        await CloudService().deleteFile(thumbId);
      } catch (e) {
        debugPrint('Bin sweep: thumb delete failed ($thumbId): $e');
      }
    }

    try {
      await db.permanentlyDeleteFile(id);
    } catch (_) {
      return false;
    }
    await _wipeTempArtifacts(tempDir, id, cloudId);
    return true;
  }

  /// One-shot read of the cloud_id + thumbnail_cloud_id for the rows we're
  /// about to purge — saves us from fetching them via the public API row by
  /// row after they've been hard-deleted.
  Future<Map<String, Map<String, String?>>> _loadCloudIds(
    List<String> ids,
  ) async {
    if (ids.isEmpty) return {};
    final raw = await (await DatabaseService().database).query(
      'files',
      columns: ['id', 'cloud_id', 'thumbnail_cloud_id'],
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
    final out = <String, Map<String, String?>>{};
    for (final row in raw) {
      out[row['id'] as String] = {
        'cloud_id': row['cloud_id'] as String?,
        'thumbnail_cloud_id': row['thumbnail_cloud_id'] as String?,
      };
    }
    return out;
  }

  Future<void> _wipeTempArtifacts(
    Directory tempDir,
    String fileId,
    String? cloudId,
  ) async {
    final candidates = <File>[
      if (cloudId != null) File('${tempDir.path}/thumb_$cloudId.jpg'),
      if (cloudId != null) File('${tempDir.path}/${cloudId}_decrypted.jpg'),
      File('${tempDir.path}/${fileId}_decrypted.mp4'),
      File('${tempDir.path}/${fileId}_thumb.jpg'),
      File('${tempDir.path}/$fileId.cnest_decrypted'),
    ];
    for (final f in candidates) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {
        // Silent — temp dir is best-effort.
      }
    }
  }
}
