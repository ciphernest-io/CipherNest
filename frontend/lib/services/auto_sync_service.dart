import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';
import 'key_manager_service.dart';
import 'sync_service.dart';

class AutoSyncService {
  static final AutoSyncService _instance = AutoSyncService._internal();
  factory AutoSyncService() => _instance;
  AutoSyncService._internal();

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  /// Callback for progress updates (used by foreground UI if active).
  void Function(int synced, int total)? onProgress;

  /// Runs a full auto-sync cycle: scans gallery, deduplicates, encrypts+uploads new files.
  Future<AutoSyncResult> runFullSync() async {
    if (_isSyncing) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);
    _isSyncing = true;

    int synced = 0;
    int failed = 0;
    int skipped = 0;

    try {
      // Ensure master key is available
      try {
        KeyManagerService().masterKey;
      } catch (_) {
        final loaded = await KeyManagerService().attemptBiometricUnlock();
        if (!loaded) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);
      }

      // Ensure cloud session is active
      final email = CloudService().currentEmail ??
          await CloudService().restoreSession();
      if (email == null) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);
      DatabaseService().setCurrentAccount(email);

      // Get unsynced assets
      final assets = await getUnsyncedAssets();
      if (assets.isEmpty) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);

      final total = assets.length;

      for (int i = 0; i < assets.length; i++) {
        try {
          final didSync = await _syncAsset(assets[i], email);
          if (didSync) {
            synced++;
          } else {
            skipped++;
          }
        } catch (e) {
          debugPrint('Auto-sync failed for asset: $e');
          failed++;
        }
        onProgress?.call(synced + failed + skipped, total);
      }

      // Advance watermark so next run only picks up newer photos
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'auto_sync_watermark',
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setInt(
        'auto_sync_last_run',
        DateTime.now().millisecondsSinceEpoch,
      );
      if (synced > 0) {
        DatabaseBackupService().scheduleBackup();
      }

      // Notify all subscribed screens (gallery, documents) to refresh
      SyncService().syncNotifier.value++;
    } catch (e) {
      debugPrint('Auto-sync error: $e');
    } finally {
      _isSyncing = false;
    }

    return AutoSyncResult(synced: synced, failed: failed, skipped: skipped);
  }

  /// Queries device gallery for photos/videos not yet in the local DB.
  Future<List<AssetEntity>> getUnsyncedAssets() async {
    // Check permission
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return [];

    // Get watermark — only sync photos created after this timestamp.
    // Set to enablement time when auto-sync is first turned on, so existing
    // gallery photos are NOT auto-synced (use Migration for those).
    final prefs = await SharedPreferences.getInstance();
    final watermarkMs = prefs.getInt('auto_sync_watermark') ?? 0;
    if (watermarkMs == 0) return []; // No watermark = not properly enabled
    final lastRun = DateTime.fromMillisecondsSinceEpoch(watermarkMs);

    // Query gallery for photos and videos created after last sync
    final filterOption = FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: lastRun,
        max: DateTime.now(),
      ),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: true)],
    );

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common, // photos + videos
      filterOption: filterOption,
    );

    if (albums.isEmpty) return [];

    // Collect all assets from all albums
    final allAssets = <AssetEntity>[];
    for (final album in albums) {
      final count = await album.assetCountAsync;
      if (count == 0) continue;
      final assets = await album.getAssetListRange(start: 0, end: count);
      allAssets.addAll(assets);
    }

    // Deduplicate by checking against existing DB entries
    final existingFiles = <String>{};
    final images = await DatabaseService().getFilesByType(CnestFileType.image);
    final docs = await DatabaseService().getFilesByType(CnestFileType.document);
    for (final f in [...images, ...docs]) {
      existingFiles.add('${f.filename}|${f.sizeBytes}');
    }

    // Also check against intentionally deleted files (prevents re-upload)
    final deletedKeys = await _getDeletedKeys();

    // Deduplicate within this scan — same photo appears in multiple
    // albums (e.g. "Camera" + "All Photos"). Without this, both copies
    // pass the DB check and create duplicate uploads.
    final seenKeys = <String>{};
    final seenIds = <String>{};
    final unsynced = <AssetEntity>[];
    for (final asset in allAssets) {
      if (seenIds.contains(asset.id)) continue;
      seenIds.add(asset.id);

      final file = await asset.file;
      if (file == null) continue;

      final name = asset.title ?? file.path.split('/').last;
      final size = await file.length();
      final key = '$name|$size';

      if (!existingFiles.contains(key) &&
          !deletedKeys.contains(key) &&
          seenKeys.add(key)) {
        unsynced.add(asset);
      }
    }

    return unsynced;
  }

  /// Encrypts and uploads a single gallery asset.
  Future<bool> _syncAsset(AssetEntity asset, String email) async {
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

    // Encrypt and upload main file
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

    // Encrypt and upload thumbnail
    String? thumbCloudId;
    if (thumbnailBytes != null) {
      final encryptedThumb = await EncryptionService.encryptFile(thumbnailBytes);
      thumbCloudId = await CloudService().uploadEncryptedFile(
        filename: '${fileId}_thumb.cnest',
        isImage: true,
        bytes: encryptedThumb,
      );
    }

    // Mark as uploaded
    await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId);

    return true;
  }

  /// Records a file as intentionally deleted so auto-sync won't re-upload it
  /// from the device gallery.
  static Future<void> trackDeletion(String filename, int sizeBytes) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getStringList('auto_sync_deleted_keys') ?? [];
    final key = '$filename|$sizeBytes';
    if (!keys.contains(key)) {
      keys.add(key);
      await prefs.setStringList('auto_sync_deleted_keys', keys);
    }
  }

  static Future<Set<String>> _getDeletedKeys() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList('auto_sync_deleted_keys') ?? []).toSet();
  }
}

class AutoSyncResult {
  final int synced;
  final int failed;
  final int skipped;

  AutoSyncResult({
    required this.synced,
    required this.failed,
    required this.skipped,
  });
}
