import 'dart:io';

import 'package:path_provider/path_provider.dart';

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
  Future<int> sweepRecycleBin({
    Duration ttl = const Duration(days: 30),
  }) async {
    final db = DatabaseService();
    final List<String> expiredIds;
    try {
      expiredIds = await db.getExpiredDeletionIds(ttl: ttl);
    } catch (_) {
      return 0;
    }
    if (expiredIds.isEmpty) return 0;

    final cloudIdsByFile = await _loadCloudIds(expiredIds);
    final tempDir = await getTemporaryDirectory();

    int purged = 0;
    for (final id in expiredIds) {
      final ids = cloudIdsByFile[id];
      final cloudId = ids?['cloud_id'];
      final thumbId = ids?['thumbnail_cloud_id'];

      if (cloudId != null) {
        try {
          await CloudService().deleteFile(cloudId);
        } catch (_) {
          // Silent — blob may already be gone, account may be signed out.
        }
      }
      if (thumbId != null) {
        try {
          await CloudService().deleteFile(thumbId);
        } catch (_) {}
      }

      try {
        await db.permanentlyDeleteFile(id);
        purged++;
      } catch (_) {
        continue;
      }

      await _wipeTempArtifacts(tempDir, id, cloudId);
    }
    return purged;
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
