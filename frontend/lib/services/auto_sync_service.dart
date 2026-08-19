import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../src/models/file_model.dart';
import 'backup_backfill_runner.dart';
import 'backup_selection_service.dart';
import 'cloud/account_registry.dart';
import 'cloud/cloud_service.dart';
import 'cnest_errors.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';
import 'key_manager_service.dart';
import 'mp4_metadata_parser.dart';
import 'sync/device_registry_service.dart';
import 'sync/sync_coordinator.dart';
import 'sync_service.dart';
import 'system_folders.dart';

/// One gallery asset inside the scan window, tagged with whether the vault
/// already has it. Duplicates still ride through [AutoSyncService.runFullSync]
/// so the watermark math sees the complete, capture-ordered window.
class ScannedAsset {
  final AssetEntity asset;
  final bool duplicate;
  final int capturedMs;

  /// The MediaStore bucket (album) the asset lives in — "Camera",
  /// "Screenshots", "WhatsApp Images"… Drives the FLAT system-folder
  /// placement (`Phone Backup / <Device> / <bucket>`). Null when only the
  /// aggregate all-photos album claimed it; those file into the device
  /// folder directly.
  final String? bucketName;

  const ScannedAsset({
    required this.asset,
    required this.duplicate,
    required this.capturedMs,
    this.bucketName,
  });
}

/// The scan window's contents (capture-time ASC) plus the window's upper
/// bound — the ONLY timestamp the watermark may advance to on a clean run.
/// Advancing to "now after the batch" would leap past photos captured while
/// the batch was uploading.
class GalleryScan {
  final List<ScannedAsset> entries;
  final int windowMaxMs;
  const GalleryScan({required this.entries, required this.windowMaxMs});
}

class AutoSyncService {
  static final AutoSyncService _instance = AutoSyncService._internal();
  factory AutoSyncService() => _instance;
  AutoSyncService._internal();

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  /// Row ids with an encrypt+upload in flight RIGHT NOW — manual uploads
  /// register here too. The heal pass must never touch these: healing a row
  /// mid-upload deletes it under the uploader's feet (and its createFile op
  /// would then reference a row that no longer exists).
  static final Set<String> inFlightUploadIds = <String>{};

  /// Callback for progress updates (used by foreground UI if active).
  void Function(int synced, int total)? onProgress;

  /// Runs a full auto-sync cycle: scans gallery, deduplicates, encrypts+uploads new files.
  Future<AutoSyncResult> runFullSync() async {
    if (_isSyncing) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);
    _isSyncing = true;
    // Stale chain decisions must not leak between runs (a folder binned
    // since the last run changes where new files land).
    _ensuredChain.clear();

    int synced = 0;
    int failed = 0;
    int skipped = 0;
    int offlineFailures = 0;

    try {
      // Encrypt-only: load just the vault PUBLIC key. New uploads are sealed
      // to it via HPKE, so background sync works while the vault is locked
      // with no secret key material in this isolate.
      final canEncrypt = await KeyManagerService().loadPublicKeyForEncrypt();
      if (!canEncrypt) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);

      // Ensure cloud session is active
      final active = AccountRegistry().activeAccount;
      if (active == null) {
        final email = await CloudService().restoreSession();
        if (email == null) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);
      }
      final account = AccountRegistry().activeAccount;
      if (account == null) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);
      DatabaseService().setCurrentAccount(account.id);

      // Heal phantom rows from interrupted past runs: rows inserted before
      // an upload that never completed. With the gallery copy still present
      // we can re-upload; with it gone the row is pure dead weight (broken
      // tile in the grid, nothing recoverable behind it).
      await _healPendingUploads();

      final scan = await scanGallery();
      // Null = not scannable (no permission / auto-sync never enabled).
      // Distinct from an EMPTY scan, which is a provably clean window and
      // may advance the watermark below.
      if (scan == null) return AutoSyncResult(synced: 0, failed: 0, skipped: 0);

      final total = scan.entries.length;
      final outcomes = <({int capturedMs, bool ok})>[];

      for (final entry in scan.entries) {
        if (entry.duplicate) {
          skipped++;
          outcomes.add((capturedMs: entry.capturedMs, ok: true));
          onProgress?.call(synced + failed + skipped, total);
          continue;
        }
        try {
          final didSync =
              await _syncAsset(entry.asset, bucketName: entry.bucketName);
          if (didSync) {
            synced++;
          } else {
            // Asset unreadable (file handle null). Deliberate safe-skip:
            // counting it as failure would wedge the watermark on this
            // asset forever.
            skipped++;
          }
          outcomes.add((capturedMs: entry.capturedMs, ok: true));
        } catch (e) {
          debugPrint('Auto-sync failed for asset: $e');
          failed++;
          if (classifyNetworkError(e) != null) offlineFailures++;
          outcomes.add((capturedMs: entry.capturedMs, ok: false));
        }
        onProgress?.call(synced + failed + skipped, total);
      }

      // Watermark: advance only past the capture-ordered PREFIX of outcomes
      // that went cleanly. A failed asset pins the watermark at (before)
      // its capture time, so the next run's window still contains it —
      // this is what makes an offline-taken photo retryable instead of a
      // permanent ghost.
      final prefs = await SharedPreferences.getInstance();
      final currentWm = prefs.getInt('auto_sync_watermark') ?? 0;
      final advance =
          computeWatermarkAdvance(outcomes, scan.windowMaxMs, currentWm);
      if (advance != null) {
        await prefs.setInt('auto_sync_watermark', advance);
      }
      await prefs.setInt(
        'auto_sync_last_run',
        DateTime.now().millisecondsSinceEpoch,
      );
      if (synced > 0) {
        DatabaseBackupService().scheduleBackup();
        // Push the createFile ops for this batch. Push-only: sealing is
        // public-key-only, so this works from the locked background
        // worker — encrypt-while-locked extends to the sync log.
        await SyncCoordinator().pushOnly();
      }

      // Notify all subscribed screens (gallery, documents) to refresh
      SyncService().syncNotifier.value++;

      // Enrolled-with-"include existing" albums whose backfill hasn't
      // completed yet: run them now, after the incremental pass. Interrupted
      // runs are safe to repeat — the migration dedup index skips everything
      // already vaulted, and the pending flag only clears on a clean pass.
      await BackupBackfillRunner().runPending();
    } catch (e) {
      debugPrint('Auto-sync error: $e');
      if (classifyNetworkError(e) != null) offlineFailures++;
    } finally {
      _isSyncing = false;
    }

    return AutoSyncResult(
      synced: synced,
      failed: failed,
      skipped: skipped,
      offlineFailures: offlineFailures,
    );
  }

  /// Whether a failed upload attempt may delete its own row. Fresh inserts
  /// roll back (no phantom tile); HEAL retries never do — the pending row
  /// is the retry state itself, and the watermark has typically advanced
  /// past the asset's capture time, so deleting the row would permanently
  /// exclude the photo from backup with zero UI signal. Pinned by test so
  /// a future "simplification" can't quietly reintroduce the data loss.
  @visibleForTesting
  static bool shouldRollbackFailedAttempt({required bool isHealRetry}) =>
      !isHealRetry;

  /// The watermark's next value, or null when it must not move.
  ///
  /// [outcomes] are the scan window's assets in capture-time ASC order.
  /// The watermark advances to the last capture time of the longest all-ok
  /// prefix; when the ENTIRE window was ok it advances to [windowMaxMs]
  /// (the scan query's upper bound). It never moves backwards. Duplicates
  /// count as ok — the vault already holds them.
  @visibleForTesting
  static int? computeWatermarkAdvance(
    List<({int capturedMs, bool ok})> outcomes,
    int windowMaxMs,
    int currentWatermarkMs,
  ) {
    var advanceTo = currentWatermarkMs;
    var prefixLen = 0;
    for (final o in outcomes) {
      if (!o.ok) break;
      if (o.capturedMs > advanceTo) advanceTo = o.capturedMs;
      prefixLen++;
    }
    if (prefixLen == outcomes.length && windowMaxMs > advanceTo) {
      advanceTo = windowMaxMs;
    }
    return advanceTo > currentWatermarkMs ? advanceTo : null;
  }

  /// Scans the device gallery window (watermark → now) and tags each asset
  /// as new or duplicate. Returns null when scanning isn't possible at all
  /// (no permission, auto-sync never enabled).
  Future<GalleryScan?> scanGallery() async {
    // Check permission
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.isAuth) return null;

    // Get watermark — only sync photos created after this timestamp.
    // Set to enablement time when auto-sync is first turned on, so existing
    // gallery photos are NOT auto-synced (use Migration for those).
    final prefs = await SharedPreferences.getInstance();
    final watermarkMs = prefs.getInt('auto_sync_watermark') ?? 0;
    if (watermarkMs == 0) return null; // No watermark = not properly enabled
    final lastRun = DateTime.fromMillisecondsSinceEpoch(watermarkMs);
    final windowMax = DateTime.now();

    // Query gallery for photos and videos created after last sync
    final filterOption = FilterOptionGroup(
      createTimeCond: DateTimeCond(
        min: lastRun,
        max: windowMax,
      ),
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: true)],
    );

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.common, // photos + videos
      filterOption: filterOption,
    );

    final windowMaxMs = windowMax.millisecondsSinceEpoch;
    if (albums.isEmpty) {
      return GalleryScan(entries: const [], windowMaxMs: windowMaxMs);
    }

    // Collect assets from the albums the user chose to back up
    // (BackupSelectionService): every album in `all` mode, only enrolled
    // ones in `selected` mode. Real (non-aggregate) albums also record
    // which bucket each asset belongs to — first bucket wins for the rare
    // asset MediaStore lists in two. The aggregate all-photos album is
    // walked only in `all` mode, purely to catch stray assets no real
    // bucket claims; those keep a null bucket and file into the device
    // folder.
    final selection = await BackupSelectionService().load();
    final allAssets = <AssetEntity>[];
    final bucketByAssetId = <String, String>{};
    for (final album in albums) {
      if (album.isAll) {
        if (selection.mode != BackupMode.all) continue;
      } else if (album.name.trim().isEmpty ||
          !selection.includes(album.name)) {
        continue;
      }
      final count = await album.assetCountAsync;
      if (count == 0) continue;
      final assets = await album.getAssetListRange(start: 0, end: count);
      allAssets.addAll(assets);
      if (!album.isAll) {
        for (final a in assets) {
          bucketByAssetId.putIfAbsent(a.id, () => album.name.trim());
        }
      }
    }

    // Vault-side dedup. Only COMPLETED uploads (plus attempts that are in
    // flight right now, and stable asset-id matches) hide an asset — a
    // stale pending phantom row must never block its own asset's retry.
    final index = await DatabaseService().getAutoSyncDedupIndex();

    // Also check against intentionally deleted files (prevents re-upload)
    final deletedKeys = await _getDeletedKeys();

    // Deduplicate within this scan — same photo appears in multiple
    // albums (e.g. "Camera" + "All Photos"). Without this, both copies
    // pass the DB check and create duplicate uploads.
    final seenKeys = <String>{};
    final seenIds = <String>{};
    final entries = <ScannedAsset>[];
    for (final asset in allAssets) {
      if (!seenIds.add(asset.id)) continue;

      final file = await asset.file;
      // Unreadable asset: drop it from the window entirely. Documented
      // trade-off — it can't wedge the watermark, at the cost of never
      // being retried if it becomes readable later.
      if (file == null) continue;

      final name = asset.title ?? file.path.split('/').last;
      final size = await file.length();
      final key = '$name|$size';

      final duplicate = index.uploadedKeys.contains(key) ||
          index.inFlightKeys.contains(key) ||
          index.knownAssetIds.contains(asset.id) ||
          deletedKeys.contains(key) ||
          !seenKeys.add(key);

      entries.add(ScannedAsset(
        asset: asset,
        duplicate: duplicate,
        capturedMs: asset.createDateTime.millisecondsSinceEpoch,
        bucketName: bucketByAssetId[asset.id],
      ));
    }

    // The multi-album merge is NOT globally sorted even though each album
    // query is — and the watermark prefix math is only correct on a
    // capture-ordered list.
    entries.sort((a, b) => a.capturedMs.compareTo(b.capturedMs));

    return GalleryScan(entries: entries, windowMaxMs: windowMaxMs);
  }

  /// Per-run memo of ensured system-folder chains: derivation key -> the
  /// folder id to file into (null = vault root). Cleared each runFullSync.
  final Map<String, String?> _ensuredChain = {};

  /// This phone's subtree KEY, derived from the model string so a
  /// reinstall reuses the same subtree (accepted trade-off: two identical
  /// handsets merge). Cached for the process lifetime. The DISPLAY name is
  /// deliberately NOT cached — it comes from the device registry (user-
  /// editable) and is read fresh so a rename applies to the next folder
  /// this service creates.
  static String? _deviceKeyCache;

  Future<(String, String)> _deviceIdentity() async {
    final display = await DeviceRegistryService().deviceName();
    final cachedKey = _deviceKeyCache;
    if (cachedKey != null) return (cachedKey, display);
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final manufacturer = info.manufacturer.trim();
      final model = info.model.trim();
      final key = manufacturer.isEmpty && model.isEmpty
          ? 'unknown device'
          : SystemFolders.deviceKey(manufacturer, model);
      _deviceKeyCache = key;
      return (key, display);
    } catch (_) {
      // Transient plugin failure (e.g. first call in a background isolate):
      // return the generic fallback WITHOUT caching it, so the next call
      // retries — a cached failure would permanently split the backup into
      // an "unknown device" subtree beside the real one.
      return ('unknown device', display);
    }
  }

  /// Resolves (creating if needed) the system folder a device-gallery
  /// asset files into: `Phone Backup / <Device> / <Album>` — FLAT, one
  /// level per MediaStore bucket display name, never a filesystem path
  /// mirror. Bucketless assets (aggregate-album-only) file into the device
  /// folder. Deterministic ids (SystemFolders) make every run converge on
  /// the same tree; replay's first-create-wins guard folds the duplicate
  /// creates. PUBLIC because migration/backfill place through the same
  /// chain — one placement authority, not two drifting copies.
  ///
  /// Deletion is RESPECTED per level, never fought: a binned or purged
  /// level (purge is terminal — replay drops re-creates of the id) stops
  /// the walk and files land in the NEAREST LIVE ANCESTOR — the device
  /// folder, then Phone Backup, then the vault root. Either way the file
  /// still ingests and shows in the gallery.
  Future<String?> ensureSystemPath({String? bucketName}) async {
    // Ids are ACCOUNT-SALTED (see SystemFolders): each linked account owns
    // its own tree in the shared folders table. No account = nothing to
    // salt with — file at the vault root (_syncAsset throws earlier anyway).
    final acct = AccountRegistry().activeAccount?.id;
    if (acct == null) return null;
    final (key, display) = await _deviceIdentity();
    final album = bucketName?.trim() ?? '';
    final memoKey =
        '$acct|$key|${album.isEmpty ? '' : SystemFolders.normalize(album)}';
    final dbsForMemo = DatabaseService();
    final memo = _ensuredChain[memoKey];
    if (memo != null) {
      // Re-validate: the user can bin/purge the folder MID-RUN from the
      // Files browser; a stale memo would stamp a dead folderId and the
      // write boundary reroutes those files to the VAULT ROOT instead of
      // the promised nearest live ancestor. One cheap lookup per asset.
      final row = await dbsForMemo.getFolderById(memo);
      if (row != null && !row.isDeleted) return memo;
      _ensuredChain.remove(memoKey);
    } else if (_ensuredChain.containsKey(memoKey)) {
      // Memoized "vault root" stays valid — there is nothing to go stale.
      return null;
    }

    final chain = <(String, String)>[
      (SystemFolders.rootId(acct), SystemFolders.rootName),
      (SystemFolders.deviceId(acct, key), display),
      if (album.isNotEmpty)
        (SystemFolders.albumId(acct, key, album), album),
    ];

    final dbs = DatabaseService();
    String? parent; // null = vault root
    for (final (id, name) in chain) {
      var row = await dbs.getFolderById(id);
      if (row == null) {
        if (await dbs.isFolderPurged(id)) break;
        await dbs.createFolder(name, parentId: parent, id: id);
        row = await dbs.getFolderById(id);
        if (row == null) break; // signed out mid-run
      }
      if (row.isDeleted) break;
      parent = id;
    }
    _ensuredChain[memoKey] = parent;
    return parent;
  }

  /// Encrypts and uploads a single gallery asset. With [existingRow] the
  /// pending row is retried IN PLACE (heal path) — no delete-then-recreate,
  /// so the gallery tile never flashes.
  Future<bool> _syncAsset(AssetEntity asset,
      {CnestFile? existingRow, String? bucketName}) async {
    final account = AccountRegistry().activeAccount;
    if (account == null) {
      // Transient (sign-out mid-run). Must throw, not return false: false
      // counts as "skipped", and a zero-failure run advances the watermark —
      // silently dropping every remaining asset from all future scans.
      throw StateError('No active cloud account');
    }

    final file = await asset.file;
    if (file == null) return false;

    final filename = asset.title ?? file.path.split('/').last;
    final fileSize = await file.length();
    final isVideo = asset.type == AssetType.video;
    final isImage = asset.type == AssetType.image || isVideo;
    final fileId = existingRow?.id ?? const Uuid().v4();

    // System-folder placement: Phone Backup/<Device>/<real path>. Heal
    // retries keep the placement the original attempt stamped on the row.
    final folderId = existingRow != null
        ? existingRow.folderId
        : await ensureSystemPath(bucketName: bucketName);

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

    if (existingRow == null) {
      // Video container metadata (codec/audio/fps + dimension fallback) —
      // parsed now, while the gallery file is on disk. Header-only atom
      // walk, no pixel IO.
      Mp4Metadata? mp4;
      if (isVideo) {
        try {
          mp4 = await Mp4MetadataParser.parse(file);
        } catch (e) {
          debugPrint('Auto-sync mp4 parse failed: $e');
        }
      }

      // Create DB record — store gallery path for local-first loading and
      // the AssetEntity id so the grid can pull Android's MediaStore
      // thumbnail straight from Samsung Gallery's cache. Dimensions and
      // duration ride along so the details sheet works even after the
      // gallery copy is gone (MediaStore knows them without pixel IO).
      final newFile = CnestFile(
        id: fileId,
        filename: filename,
        sizeBytes: fileSize,
        createdAt: asset.createDateTime,
        isUploaded: false,
        localPath: file.path,
        assetId: asset.id,
        type: isImage ? CnestFileType.image : CnestFileType.document,
        // Composite account id + real provider type, matching what addFile
        // persists — a bare email or hardcoded Google here silently
        // mislabels rows synced under a OneDrive account.
        provider: account.providerType,
        accountId: account.id,
        width: asset.orientatedWidth > 0
            ? asset.orientatedWidth
            : mp4?.width,
        height: asset.orientatedHeight > 0
            ? asset.orientatedHeight
            : mp4?.height,
        durationMs: isVideo && asset.videoDuration > Duration.zero
            ? asset.videoDuration.inMilliseconds
            : mp4?.duration?.inMilliseconds,
        videoCodec: mp4?.videoCodec,
        audioCodec: mp4?.audioCodec,
        fps: mp4?.fps,
        deviceModel: mp4?.deviceModel,
        folderId: folderId,
      );
      await DatabaseService().addFile(newFile);
    } else {
      // Heal retry: same row, fresh attempt clock.
      await DatabaseService().touchUploadAttempt(fileId);
    }

    inFlightUploadIds.add(fileId);
    try {
      // Encrypt and upload main file. Content hash (plaintext SHA-256) is
      // computed in the same single pass as encryption.
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
        final fileBytes = await file.readAsBytes();
        final hashed =
            await EncryptionService.encryptFileWithHash(fileBytes);
        contentHash = hashed.hash;
        mainCloudId = await CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: isImage ? CnestFileType.image : CnestFileType.document,
          originalName: filename,
          bytes: hashed.encrypted,
        );
      }

      if (mainCloudId == null) throw Exception('Upload failed for $filename');

      // Encrypt and upload thumbnail
      String? thumbCloudId;
      if (thumbnailBytes != null) {
        final encryptedThumb =
            await EncryptionService.encryptFile(thumbnailBytes);
        thumbCloudId = await CloudService().uploadEncryptedFile(
          filename: '${fileId}_thumb.cnest',
          type: CnestFileType.image,
          bytes: encryptedThumb,
        );
      }

      // Mark as uploaded — also records the createFile sync op (blob is
      // durable at this point; op-after-blob crash ordering holds). The
      // asset's MediaStore capture time travels as the gallery sort key so
      // every device orders this photo identically.
      final capturedMs = asset.createDateTime.millisecondsSinceEpoch;
      await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId,
          filename: filename,
          contentHash: contentHash,
          sizeBytes: fileSize,
          capturedAt: capturedMs > 0 ? capturedMs : null,
          folderId: folderId);

      return true;
    } catch (e) {
      // Roll the row back — same contract as the manual upload path — but
      // ONLY for rows THIS attempt inserted. rollbackFailedUpload, NOT
      // permanentlyDeleteFile: this row never recorded a createFile op
      // (that happens in markAsUploaded), so a purgeFile op here would be
      // a spurious tombstone shipped to peers.
      //
      // A HEAL retry (existingRow != null) must NEVER roll back: the
      // pending row IS the retry state. Its assetId is what dedup-hides
      // the asset from rescans, so the watermark has usually advanced
      // past the capture time by the time heal runs — deleting the row on
      // a transient failure (offline blip, cloud 500) would silently
      // exclude the photo from backup forever. Keep the row; the attempt
      // clock already touched at entry gives the grace-window backoff.
      if (shouldRollbackFailedAttempt(isHealRetry: existingRow != null)) {
        try {
          await DatabaseService().rollbackFailedUpload(fileId);
        } catch (rollbackErr) {
          debugPrint('Auto-sync rollback failed for $filename: $rollbackErr');
        }
      }
      rethrow;
    } finally {
      inFlightUploadIds.remove(fileId);
    }
  }

  /// Rows whose last upload ATTEMPT is younger than this are skipped by the
  /// healing pass — the attempt may still be in flight (backstopped by the
  /// live [inFlightUploadIds] registry for attempts in this process).
  static const _pendingGraceWindow = Duration(minutes: 15);

  /// Re-uploads or purges rows whose upload never completed (cloud_id NULL).
  /// These are phantoms from interrupted past runs: the row masquerades as a
  /// synced photo while the gallery copy exists, then turns into a broken
  /// tile once it's deleted.
  Future<void> _healPendingUploads() async {
    final pending = await DatabaseService().getPendingUploads();
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final row in pending) {
      // Never touch a row whose upload is running in this process right
      // now — deleting it mid-upload orphans the uploader's markAsUploaded.
      if (inFlightUploadIds.contains(row.id)) continue;

      // Grace measures from the last upload ATTEMPT, not createdAt —
      // createdAt is the media's CAPTURE time, which for an old photo
      // picked today would grant zero protection. Pre-v12 rows have no
      // attempt stamp and are heal-eligible immediately.
      final attempt = row.uploadStartedAt;
      if (attempt != null &&
          nowMs - attempt < _pendingGraceWindow.inMilliseconds) {
        continue;
      }

      AssetEntity? asset;
      if (row.assetId != null) {
        try {
          asset = await AssetEntity.fromId(row.assetId!);
        } catch (_) {
          // MediaStore entry gone — treat like a missing local file.
        }
      }

      if (asset != null) {
        // Source still on device — retry the upload IN PLACE. Reusing the
        // row (instead of delete-then-recreate) keeps the gallery tile
        // stable: no flash, no churn.
        try {
          await _syncAsset(asset, existingRow: row);
        } catch (e) {
          debugPrint('Heal re-upload failed for ${row.filename}: $e');
        }
        continue;
      }

      final localExists =
          row.localPath != null && File(row.localPath!).existsSync();
      if (localExists) {
        // Local file without a MediaStore entry (rare: manual pick whose
        // asset resolve failed). Leave it — it still renders from disk and
        // the user can re-upload manually.
        continue;
      }

      // Nothing on device, nothing in the cloud: pure phantom. Remove the
      // broken tile. rollbackFailedUpload, not permanentlyDeleteFile — a
      // never-uploaded row has no createFile op, so a purge op here would
      // be a spurious tombstone.
      try {
        await DatabaseService().rollbackFailedUpload(row.id);
      } catch (e) {
        debugPrint('Heal purge failed for ${row.filename}: $e');
      }
    }
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

  /// How many of [failed] were network-shaped (offline / connection died).
  /// Messaging only — V1 never auto-retries; the next sync rescans them.
  final int offlineFailures;

  AutoSyncResult({
    required this.synced,
    required this.failed,
    required this.skipped,
    this.offlineFailures = 0,
  });

  bool get allFailuresOffline => failed > 0 && offlineFailures >= failed;
}
