import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
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

    final result = <AlbumInfo>[];
    for (final album in albums) {
      final count = await album.assetCountAsync;
      if (count == 0) continue;
      result.add(AlbumInfo(path: album, name: album.name, count: count));
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
      }
    }

    // Deduplicate — skip files already in the DB
    final existingKeys = <String>{};
    final images = await DatabaseService().getFilesByType(CnestFileType.image);
    final docs = await DatabaseService().getFilesByType(CnestFileType.document);
    for (final f in [...images, ...docs]) {
      existingKeys.add('${f.filename}|${f.sizeBytes}');
    }

    // Deduplicate within results (same file in multiple albums)
    final seenIds = <String>{};
    final unsynced = <AssetEntity>[];
    int totalBytes = 0;

    for (final asset in allAssets) {
      if (seenIds.contains(asset.id)) continue;
      seenIds.add(asset.id);

      final file = await asset.file;
      if (file == null) continue;

      final name = asset.title ?? file.path.split('/').last;
      final size = await file.length();

      if (!existingKeys.contains('$name|$size')) {
        unsynced.add(asset);
        totalBytes += size;
      }
    }

    return MigrationScanResult(assets: unsynced, totalBytes: totalBytes);
  }

  /// Runs the migration: encrypts and uploads each asset, calling [onProgress]
  /// after each file completes. Can be paused/resumed/cancelled.
  Future<MigrationResult> runMigration({
    required List<AssetEntity> assets,
    required void Function(MigrationProgress progress) onProgress,
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
      return MigrationResult(synced: 0, failed: 0, skipped: 0);
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
      try {
        final file = await asset.file;
        if (file == null) {
          skipped++;
          continue;
        }

        final fileSize = await file.length();
        final didSync = await _migrateAsset(asset, email);

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

    _isRunning = false;
    _isPaused = false;
    _isCancelled = false;

    return MigrationResult(synced: synced, failed: failed, skipped: skipped);
  }

  void pause() => _isPaused = true;
  void resume() => _isPaused = false;
  void cancel() {
    _isCancelled = true;
    _isPaused = false;
  }

  Future<bool> _migrateAsset(AssetEntity asset, String email) async {
    final file = await asset.file;
    if (file == null) return false;

    final filename = asset.title ?? file.path.split('/').last;
    final fileSize = await file.length();
    final isVideo = asset.type == AssetType.video;
    final isImage = asset.type == AssetType.image || isVideo;
    final fileId = const Uuid().v4();

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

    // Create DB record
    final newFile = CnestFile(
      id: fileId,
      filename: filename,
      sizeBytes: fileSize,
      createdAt: asset.createDateTime,
      isUploaded: false,
      type: isImage ? CnestFileType.image : CnestFileType.document,
      provider: 0,
      accountId: email,
    );
    await DatabaseService().addFile(newFile);

    // Encrypt and upload
    final mainCloudFilename = '$fileId.cnest';
    String? mainCloudId;

    if (isVideo) {
      final encryptedSize = EncryptionService.calculateEncryptedSize(fileSize);
      final encryptedStream = EncryptionService.encryptStream(file.openRead());
      mainCloudId = await CloudService().uploadEncryptedFile(
        filename: mainCloudFilename,
        isImage: false,
        originalName: filename,
        stream: encryptedStream,
        size: encryptedSize,
      );
    } else {
      final fileBytes = await file.readAsBytes();
      final encrypted = await EncryptionService.encryptFile(fileBytes);
      mainCloudId = await CloudService().uploadEncryptedFile(
        filename: mainCloudFilename,
        isImage: isImage,
        originalName: filename,
        bytes: encrypted,
      );
    }

    if (mainCloudId == null) throw Exception('Upload failed for $filename');

    // Upload thumbnail
    String? thumbCloudId;
    if (thumbnailBytes != null) {
      final encryptedThumb =
          await EncryptionService.encryptFile(thumbnailBytes);
      thumbCloudId = await CloudService().uploadEncryptedFile(
        filename: '${fileId}_thumb.cnest',
        isImage: true,
        bytes: encryptedThumb,
      );
    }

    await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId);
    return true;
  }
}

class AlbumInfo {
  final AssetPathEntity path;
  final String name;
  final int count;

  AlbumInfo({required this.path, required this.name, required this.count});
}

class MigrationScanResult {
  final List<AssetEntity> assets;
  final int totalBytes;

  MigrationScanResult({required this.assets, required this.totalBytes});
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

  MigrationResult({
    required this.synced,
    required this.failed,
    required this.skipped,
  });
}