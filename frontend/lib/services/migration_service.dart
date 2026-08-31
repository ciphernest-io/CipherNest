import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../src/models/file_model.dart';
import 'auto_sync_service.dart';
import 'system_folders.dart';
import 'cloud/cloud_service.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
import 'subscription_service.dart';
import 'encryption_service.dart';

class MigrationService {
  static final MigrationService _instance = MigrationService._internal();
  factory MigrationService() => _instance;
  MigrationService._internal();

  bool _isRunning = false;
  bool _isPaused = false;
  bool _isCancelled = false;

  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;

  /// Returns all device albums with their asset counts.
  Future<List<AlbumInfo>> getAlbums() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return [];

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: true),
        ],
      ),
    );

    // Merge same-named buckets (e.g. /DCIM/Snapseed + /Pictures/Snapseed)
    // into one entry, matching the vault's album identity (albumId is keyed
    // on the normalized name). The aggregate "all" album never merges.
    final result = <AlbumInfo>[];
    final groupIndexByKey = <String, int>{};
    for (final album in albums) {
      final count = await album.assetCountAsync;
      if (count == 0) continue;
      if (album.isAll) {
        result.add(AlbumInfo(paths: [album], name: album.name, count: count));
        continue;
      }
      final key = SystemFolders.normalize(album.name);
      final existing = groupIndexByKey[key];
      if (existing == null) {
        groupIndexByKey[key] = result.length;
        result.add(AlbumInfo(paths: [album], name: album.name, count: count));
      } else {
        final g = result[existing];
        result[existing] = AlbumInfo(
          paths: [...g.paths, album],
          name: g.name,
          count: g.count + count,
        );
      }
    }
    return result;
  }

  /// Scans for assets not yet in the DB.
  /// - No arguments: scans entire gallery
  /// - [albumPaths]: scan only these albums
  /// - [manualAssets]: use these pre-selected assets directly
  Future<MigrationScanResult> scanGallery({
    List<AssetPathEntity>? albumPaths,
    List<AssetEntity>? manualAssets,
  }) async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) {
      return MigrationScanResult(assets: [], totalBytes: 0);
    }

    List<AssetEntity> allAssets;
    // Which real bucket each asset came from (first bucket wins) — drives
    // the Phone Backup/<Device>/<Album> placement at migrate time. Manual
    // picks have no bucket and file into the device folder.
    final bucketByAssetId = <String, String>{};

    if (manualAssets != null) {
      allAssets = manualAssets;
    } else {
      // Either scan specific albums or all albums
      final albums = albumPaths ??
          await PhotoManager.getAssetPathList(
            type: RequestType.common,
            filterOption: FilterOptionGroup(
              orders: [
                const OrderOption(
                    type: OrderOptionType.createDate, asc: true),
              ],
            ),
          );

      allAssets = <AssetEntity>[];
      for (final album in albums) {
        final count = await album.assetCountAsync;
        if (count == 0) continue;
        final assets =
            await album.getAssetListRange(start: 0, end: count);
        allAssets.addAll(assets);
        if (!album.isAll && album.name.trim().isNotEmpty) {
          for (final a in assets) {
            bucketByAssetId.putIfAbsent(a.id, () => album.name.trim());
          }
        }
      }
    }

    // Deduplicate — skip files already in the DB. Two independent keys are
    // recorded per existing file:
    //   assetId    (photo_manager's MediaStore id; stable and unique)
    //   filename|size|day  (fallback for rows migrated before the assetId
    //                       column was added; the extra `day` component
    //                       keeps two IMG_20250101.jpg's at 1.2 MB from
    //                       colliding just because they share a name+size)
    // A candidate is skipped iff EITHER key hits.
    final existingAssetIds = <String>{};
    final existingFallbackKeys = <String>{};
    // includeHidden: this is a DEDUP index, not a view — a photo filed in a
    // hidden folder must still be recognized or migration re-imports it.
    final images = await DatabaseService()
        .getFilesByType(CnestFileType.image, includeHidden: true);
    final docs = await DatabaseService()
        .getFilesByType(CnestFileType.document, includeHidden: true);
    for (final f in [...images, ...docs]) {
      final aid = f.assetId;
      if (aid != null && aid.isNotEmpty) existingAssetIds.add(aid);
      final day = f.createdAt.toIso8601String().substring(0, 10);
      existingFallbackKeys.add('${f.filename}|${f.sizeBytes}|$day');
    }

    // Deduplicate within results (same file in multiple albums)
    final seenIds = <String>{};
    final unsynced = <AssetEntity>[];
    int totalBytes = 0;

    for (final asset in allAssets) {
      if (seenIds.contains(asset.id)) continue;
      seenIds.add(asset.id);

      // Fast path: MediaStore id already matches a stored vault file.
      if (existingAssetIds.contains(asset.id)) continue;

      final file = await asset.file;
      if (file == null) continue;

      final name = asset.title ?? file.path.split('/').last;
      final size = await file.length();
      final day = asset.createDateTime.toIso8601String().substring(0, 10);
      final fallbackKey = '$name|$size|$day';

      if (!existingFallbackKeys.contains(fallbackKey)) {
        unsynced.add(asset);
        totalBytes += size;
      }
    }

    return MigrationScanResult(
      assets: unsynced,
      totalBytes: totalBytes,
      bucketByAssetId: bucketByAssetId,
    );
  }

  /// Runs the migration: encrypts and uploads each asset, calling [onProgress]
  /// after each file completes. Can be paused/resumed/cancelled.
  Future<MigrationResult> runMigration({
    required List<AssetEntity> assets,
    required void Function(MigrationProgress progress) onProgress,
    Map<String, String> bucketByAssetId = const {},
  }) async {
    if (_isRunning) {
      return MigrationResult(synced: 0, failed: 0, skipped: 0);
    }

    _isRunning = true;
    _isPaused = false;
    _isCancelled = false;

    final email = CloudService().currentEmail;
    if (email == null) {
      _isRunning = false;
      // Not a silent no-op any more — this only fires when a cloud
      // reconnect is needed. Screen catches the exception and can route
      // to reconnect / show a friendly error.
      debugPrint('MigrationService.runMigration: no active cloud account');
      throw StateError(
        'Migration cannot start: no active cloud account. '
        'Reconnect from Settings and try again.',
      );
    }

    int synced = 0;
    int failed = 0;
    int skipped = 0;
    int bytesUploaded = 0;
    final stopwatch = Stopwatch()..start();

    for (int i = 0; i < assets.length; i++) {
      // Check for cancellation
      if (_isCancelled) break;

      // Wait while paused
      while (_isPaused && !_isCancelled) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (_isCancelled) break;

      final asset = assets[i];
      // Keep the cross-isolate sync lease fresh: a background runFullSync
      // firing mid-migration would race this pass (its dedup snapshot
      // predates our inserts). Standalone migration-screen runs acquire no
      // lease explicitly — this heartbeat IS their claim, and it
      // self-expires within the freshness window after the run ends.
      await AutoSyncService.refreshRunLease();
      try {
        final file = await asset.file;
        if (file == null) {
          skipped++;
          continue;
        }

        final fileSize = await file.length();
        final didSync = await _migrateAsset(asset, email,
            bucketName: bucketByAssetId[asset.id]);

        if (didSync) {
          synced++;
          bytesUploaded += fileSize;
        } else {
          skipped++;
        }
      } catch (e) {
        debugPrint('Migration failed for asset ${asset.id}: $e');
        failed++;
      }

      // Calculate ETA
      final elapsed = stopwatch.elapsed;
      final completed = synced + failed + skipped;
      final avgPerFile = completed > 0
          ? elapsed.inMilliseconds / completed
          : 0.0;
      final remaining = assets.length - completed;
      final etaMs = (avgPerFile * remaining).round();

      onProgress(MigrationProgress(
        current: completed,
        total: assets.length,
        synced: synced,
        failed: failed,
        skipped: skipped,
        bytesUploaded: bytesUploaded,
        eta: Duration(milliseconds: etaMs),
        currentFileName: asset.title ?? 'Unknown',
      ));

      // Backup DB every 10 files
      if (synced > 0 && synced % 10 == 0) {
        DatabaseBackupService().scheduleBackup();
      }
    }

    stopwatch.stop();

    // Final DB backup
    if (synced > 0) {
      DatabaseBackupService().scheduleBackup();
    }

    final wasCancelled = _isCancelled;
    _isRunning = false;
    _isPaused = false;
    _isCancelled = false;

    return MigrationResult(
        synced: synced,
        failed: failed,
        skipped: skipped,
        cancelled: wasCancelled);
  }

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void cancel() {
    _isCancelled = true;
    _isPaused = false;
  }

  Future<bool> _migrateAsset(AssetEntity asset, String email,
      {String? bucketName}) async {
    // Free-tier cap: past the limit only Plus stores more. Quietly skips
    // (the asset stays eligible for after an upgrade); never touches
    // anything already stored.
    if (!await FreeTierGuard.canStoreMore()) return false;

    final file = await asset.file;
    if (file == null) return false;

    final filename = asset.title ?? file.path.split('/').last;
    final fileSize = await file.length();
    final isVideo = asset.type == AssetType.video;
    final isImage = asset.type == AssetType.image || isVideo;
    final fileId = const Uuid().v4();

    // Same placement authority as auto-sync: Phone Backup/<Device>/<Album>
    // (device folder when the asset has no bucket). Migrated files used to
    // land at the vault root — a device-gallery photo belongs in the
    // device's backup tree no matter which path vaulted it.
    final folderId =
        await AutoSyncService().ensureSystemPath(bucketName: bucketName);

    // Read once, reuse for encryption (was two full reads per photo).
    Uint8List? imageBytes;
    Uint8List? thumbnailBytes;

    // Generate thumbnail
    if (isVideo) {
      try {
        thumbnailBytes = await VideoThumbnail.thumbnailData(
          video: file.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 300,
          quality: 50,
        );
      } catch (e) {
        debugPrint('Video thumbnail failed: $e');
      }
    } else if (isImage) {
      try {
        final bytes = await file.readAsBytes();
        imageBytes = bytes;
        thumbnailBytes = await FlutterImageCompress.compressWithList(
          bytes,
          minHeight: 300,
          minWidth: 300,
          quality: 50,
        );
      } catch (e) {
        debugPrint('Image thumbnail failed: $e');
      }
    }

    // Create DB record — store gallery path for local-first loading and
    // MediaStore asset id so the next migration scan can dedupe by it
    // (fixes the collision on IMG_*.jpg-with-same-size we had before).
    final newFile = CnestFile(
      id: fileId,
      filename: filename,
      sizeBytes: fileSize,
      createdAt: asset.createDateTime,
      isUploaded: false,
      localPath: file.path,
      assetId: asset.id,
      type: isImage ? CnestFileType.image : CnestFileType.document,
      provider: 0,
      accountId: email,
      folderId: folderId,
    );
    await DatabaseService().addFile(newFile);

    // Register with the shared in-flight set: the auto-sync HEAL pass must
    // never retry this row in place while our upload is running (a slow
    // large-video backfill can outlive the 15-minute grace window).
    AutoSyncService.inFlightUploadIds.add(fileId);
    try {
      // Encrypt and upload (content hash computed in the same pass).
      final mainCloudFilename = '$fileId.cnest';
      String? mainCloudId;
      String? contentHash;

      if (isVideo) {
        final encryptedSize =
            EncryptionService.calculateEncryptedSize(fileSize);
        final hashed = EncryptionService.encryptStreamWithHash(
            file.openRead(), totalSize: fileSize);
        mainCloudId = await CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: CnestFileType.image,
          originalName: filename,
          stream: hashed.stream,
          size: encryptedSize,
        );
        contentHash = await hashed.hash;
      } else {
        final fileBytes = imageBytes ?? await file.readAsBytes();
        final hashed = await EncryptionService.encryptFileWithHashInBackground(fileBytes);
        contentHash = hashed.hash;
        mainCloudId = await CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: isImage ? CnestFileType.image : CnestFileType.document,
          originalName: filename,
          bytes: hashed.encrypted,
        );
      }

      if (mainCloudId == null) throw Exception('Upload failed for $filename');

      // Upload thumbnail
      String? thumbCloudId;
      if (thumbnailBytes != null) {
        final encryptedThumb =
            await EncryptionService.encryptFileInBackground(thumbnailBytes);
        thumbCloudId = await CloudService().uploadEncryptedFile(
          filename: '${fileId}_thumb.cnest',
          type: CnestFileType.image,
          bytes: encryptedThumb,
        );
      }

      final capturedMs = asset.createDateTime.millisecondsSinceEpoch;
      await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId,
          filename: filename,
          contentHash: contentHash,
          sizeBytes: fileSize,
          capturedAt: capturedMs > 0 ? capturedMs : null,
          folderId: folderId);
      return true;
    } catch (e) {
      // Failed mid-upload: remove the phantom row — same contract as the
      // manual pipeline (rollbackFailedUpload, never permanentlyDeleteFile:
      // no createFile op exists yet, so a purge op would be a spurious
      // tombstone). Leaving the row would poison the next scan's dedup
      // index: the asset reads "already vaulted", the backfill flag clears
      // as a clean pass, and if the user then deletes the gallery copy the
      // heal pass purges the row — permanent loss behind a "backed up"
      // claim.
      try {
        await DatabaseService().rollbackFailedUpload(fileId);
      } catch (rollbackErr) {
        debugPrint('Migration rollback failed for $filename: $rollbackErr');
      }
      rethrow;
    } finally {
      AutoSyncService.inFlightUploadIds.remove(fileId);
    }
  }
}

class AlbumInfo {
  /// Every MediaStore bucket carrying this display name. Same-named buckets
  /// at different filesystem paths merge into ONE album everywhere in the
  /// product (SystemFolders.albumId is keyed on the name) — the picker was
  /// the sole non-merging surface, showing two "Snapseed" rows whose
  /// name-keyed checkboxes ticked together.
  final List<AssetPathEntity> paths;
  final String name;

  /// Combined asset count across [paths].
  final int count;

  AlbumInfo({required this.paths, required this.name, required this.count});

  /// The primary bucket, for callers that need a single entity (eviction
  /// priority, isAll checks — aggregate albums are never merged, so a
  /// group is either all real buckets or the lone aggregate).
  AssetPathEntity get path => paths.first;
}

class MigrationScanResult {
  final List<AssetEntity> assets;
  final int totalBytes;

  /// Real MediaStore bucket per asset id (first bucket wins) — feeds the
  /// Phone Backup placement in [MigrationService.runMigration]. Empty for
  /// manual picks.
  final Map<String, String> bucketByAssetId;

  MigrationScanResult({
    required this.assets,
    required this.totalBytes,
    this.bucketByAssetId = const {},
  });
}

class MigrationProgress {
  final int current;
  final int total;
  final int synced;
  final int failed;
  final int skipped;
  final int bytesUploaded;
  final Duration eta;
  final String currentFileName;

  MigrationProgress({
    required this.current,
    required this.total,
    required this.synced,
    required this.failed,
    required this.skipped,
    required this.bytesUploaded,
    required this.eta,
    required this.currentFileName,
  });
}

class MigrationResult {
  final int synced;
  final int failed;
  final int skipped;

  /// True when the pass stopped early (user cancel). A cancelled pass can
  /// report zero failures — callers deciding "was this a CLEAN, COMPLETE
  /// pass" (the backfill runner) must check this too.
  final bool cancelled;

  MigrationResult({
    required this.synced,
    required this.failed,
    required this.skipped,
    this.cancelled = false,
  });
}