import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../src/models/file_model.dart';
import '../src/utils/filename_dedup.dart';
import '../src/utils/media_store_uri.dart';
import 'activity_center.dart';
import 'audio_art_parser.dart';
import 'auto_sync_service.dart';
import 'cloud/cloud_service.dart';
import 'cnest_errors.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';
import 'file_metadata_service.dart';
import 'mp4_metadata_parser.dart';
import 'subscription_service.dart';
import 'upload_foreground_guard.dart';

/// Which picker surface the user came through. Drives type classification
/// exactly as the four home-screen upload buttons always did; [other] (and
/// the Files browser's "upload here") classifies by extension instead.
enum UploadCategory { media, document, audio, other }

/// Per-file result of a batch. [skippedDuplicate] = the plaintext content
/// hash already exists live in the vault, so the file was NOT re-uploaded.
class UploadOutcome {
  final String filename;
  final bool ok;
  final bool skippedDuplicate;
  final Object? error;
  const UploadOutcome._(this.filename,
      {required this.ok, this.skippedDuplicate = false, this.error});
}

class _GalleryAssetMatch {
  final String? assetId;
  final String? localPath;
  const _GalleryAssetMatch({this.assetId, this.localPath});
}

/// The manual encrypt-and-upload flow, extracted from the home screen so
/// every surface (home categories, the Files browser's upload-here, folder
/// import) shares ONE pipeline. Behavior is the home flow's, unchanged,
/// plus two Phase D additions: [folderId] placement (rides the createFile
/// op) and a content-hash duplicate pre-check for whole-file uploads.
///
/// Zero-knowledge invariants preserved: plaintext only ever lives in
/// memory or the app-private cache dirs; nothing is logged; the cloud sees
/// `<uuid>.cnest` blobs only.
class UploadPipeline {
  UploadPipeline._();

  /// Uploads [picks] sequentially under ONE foreground-service pin.
  /// [onProgress] fires after each file with (done, total). Never throws —
  /// per-file failures land in the returned outcomes.
  ///
  /// [trackActivity] (default true) registers the batch as an ActivityCenter
  /// task, so every caller inherits the progress pill for free. The folder
  /// import passes false — it runs its own outer per-entry task.
  ///
  /// [skipDuplicates] (default true) is the content-hash pre-check: bytes
  /// already live in the vault are not re-uploaded. The FOLDER IMPORT path
  /// passes false — Windows-copy semantics (Usman ruling, Aug 1): an
  /// explicitly imported folder must arrive INTACT, so a matching file
  /// becomes a real second row + second blob (a copy costs storage,
  /// exactly like copying on disk; one row = one folder_id = one blob,
  /// and rows must stay independent for delete/purge/sweep to hold).
  static Future<List<UploadOutcome>> uploadBatch(
    List<PlatformFile> picks, {
    required UploadCategory category,
    String? folderId,
    bool skipDuplicates = true,
    bool trackActivity = true,
    void Function(int done, int total)? onProgress,
  }) async {
    if (picks.isEmpty) return const [];

    // Free-tier cap: the whole batch must fit (a partial upload of a
    // hand-picked batch confuses more than it helps). Typed failure so
    // callers surface the upsell like any other upload error.
    if (!await FreeTierGuard.canStoreMore(adding: picks.length)) {
      return [
        for (final p in picks)
          UploadOutcome._(p.name,
              ok: false, error: const FreeLimitReachedError()),
      ];
    }

    // Android 13+: without this the pin still works but the "Securing your
    // file…" notification is invisible and a backgrounded upload looks
    // like nothing is running. Denial is non-fatal.
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
    // Drawer-cancel support: stops BEFORE the next file; the file in
    // flight finishes (mid-file rollback is the failure path's job).
    var cancelled = false;
    final task = trackActivity
        ? ActivityCenter().start(
            kind: ActivityKind.upload,
            label: 'Encrypting 0/${picks.length}…',
            total: picks.length,
            onCancel: () => cancelled = true)
        : null;
    await UploadForegroundGuard().begin();
    try {
      final outcomes = <UploadOutcome>[];
      for (var i = 0; i < picks.length; i++) {
        if (cancelled) break;
        outcomes.add(await _uploadOne(picks[i],
            category: category,
            folderId: folderId,
            skipDuplicates: skipDuplicates));
        task?.update(i + 1,
            label: 'Encrypting ${i + 1}/${picks.length}…');
        onProgress?.call(i + 1, picks.length);
      }
      final summary = cancelled
          ? 'Upload stopped: ${outcomes.length} of ${picks.length} done'
          : summarizeOutcomes(outcomes);
      if (outcomes.any((o) => !o.ok)) {
        task?.fail(summary);
      } else {
        task?.complete(summary);
      }
      return outcomes;
    } catch (e) {
      // Contractually unreachable (_uploadOne never throws) — but a leaked
      // running task would pin the pill forever, so belt-and-braces.
      task?.fail('Upload failed');
      rethrow;
    } finally {
      await UploadForegroundGuard().end();
    }
  }

  /// The ' · '-joined batch summary every surface shows — extracted from
  /// the home screen's reporter so pill terminals and callers agree.
  static String summarizeOutcomes(List<UploadOutcome> outcomes) {
    final uploaded =
        outcomes.where((o) => o.ok && !o.skippedDuplicate).length;
    final dups = outcomes.where((o) => o.skippedDuplicate).length;
    final failures = outcomes.where((o) => !o.ok).length;
    final parts = <String>[];
    if (uploaded > 0) {
      parts.add(outcomes.length == 1
          ? 'Secure Upload Complete'
          : '$uploaded file${uploaded == 1 ? '' : 's'} secured');
    }
    if (dups > 0) parts.add('$dups already in your vault');
    if (failures > 0) parts.add('$failures failed');
    return parts.isEmpty ? 'Nothing uploaded' : parts.join(' · ');
  }

  static Future<UploadOutcome> _uploadOne(
    PlatformFile pickedFile, {
    required UploadCategory category,
    String? folderId,
    bool skipDuplicates = true,
  }) async {
    Uint8List? fileBytes;
    Stream<List<int>>? fileStream;
    Uint8List? thumbnailBytes;
    String filename = pickedFile.name;
    String? pickedPath;
    bool isLocalFile = false;
    // Hoisted so the catch block can roll back the row inserted in step 4
    // when a later step (upload) fails.
    String? fileId;

    try {
      final fileSize = pickedFile.size;
      pickedPath = pickedFile.path;
      if (pickedPath == null) throw Exception('Could not retrieve file path');

      final ext = filename.split('.').last.toLowerCase();
      final isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);

      // Type first, behavior from the TYPE: a jpg picked through the
      // unrestricted "other" surface still gets thumbnails and the gallery
      // resolve — otherwise it would sit in the grid as a blank tile.
      final CnestFileType type = switch (category) {
        UploadCategory.media => CnestFileType.image,
        UploadCategory.audio => CnestFileType.audio,
        UploadCategory.document => CnestFileType.document,
        UploadCategory.other => CnestFileTypeWire.fromFilename(filename),
      };
      final isMediaFile = isVideo || type == CnestFileType.image;

      // --- 2. PREPARE STREAM OR BYTES + VIDEO THUMB ---
      if (isVideo) {
        fileStream = File(pickedPath).openRead();
        try {
          thumbnailBytes = await VideoThumbnail.thumbnailData(
            video: pickedPath,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 300,
            quality: 50,
          );
        } catch (e) {
          debugPrint('Video thumbnail generation failed: $e');
        }
      } else {
        fileBytes = await File(pickedPath).readAsBytes();
      }

      // --- 3. IMAGE/PDF/ALBUM-ART THUMBNAILS ---
      if (!isVideo && fileBytes != null) {
        if (isMediaFile) {
          try {
            thumbnailBytes = await FlutterImageCompress.compressWithList(
              fileBytes,
              minHeight: 300,
              minWidth: 300,
              quality: 50,
            );
          } catch (e) {
            debugPrint('Image thumbnail failed: $e');
          }
        } else if (filename.toLowerCase().endsWith('.pdf')) {
          thumbnailBytes = await _generatePdfThumbnail(fileBytes);
        } else if (type == CnestFileType.audio) {
          // Embedded cover art (ID3 APIC / m4a covr) becomes the track's
          // thumbnail — the downstream encrypt/upload path is type-blind.
          // Full-buffer synchronous Dart scan — keep it off the UI
          // isolate like the encrypt pass.
          final fb = fileBytes;
          final art =
              await Isolate.run(() => AudioArtParser.extract(fb, filename));
          if (art != null) {
            try {
              thumbnailBytes = await FlutterImageCompress.compressWithList(
                art,
                minHeight: 300,
                minWidth: 300,
                quality: 60,
              );
            } catch (_) {
              thumbnailBytes = art; // odd format: ship as-is
            }
          }
        }
      }

      final currentEmail = CloudService().currentEmail;
      if (currentEmail == null) throw Exception('No active account.');

      // Whole-file uploads: encrypt now — the hash falls out of the same
      // pass — and skip the upload entirely if these exact bytes are
      // already live in the vault. Streamed videos can't pre-check without
      // a second full read; their duplicate lands as "name (1)" as before.
      ({Uint8List encrypted, String hash})? preEncrypted;
      if (fileBytes != null) {
        final hashed = await EncryptionService.encryptFileWithHashInBackground(fileBytes);
        preEncrypted = (encrypted: hashed.encrypted, hash: hashed.hash);
        if (skipDuplicates &&
            await DatabaseService().hasActiveContentHash(hashed.hash)) {
          return UploadOutcome._(filename, ok: true, skippedDuplicate: true);
        }
      }

      // --- 4. DATABASE ENTRY ---
      fileId = const Uuid().v4();

      // Duplicate-name rename: a second upload of "photo.jpg" lands as
      // "photo (1).jpg" instead of a same-named twin. Auto-sync dedup is
      // unaffected — it matches renamed rows by MediaStore asset id. The
      // pre-rename name is kept for the gallery-asset resolve below, which
      // matches against MediaStore titles.
      final originalPickName = filename;
      final taken = await DatabaseService()
          .getActiveFilenames(stemPrefix: dedupQueryPrefix(filename));
      filename = nextAvailableFilename(filename, taken);

      isLocalFile = pickedPath.startsWith('/storage/') ||
          pickedPath.startsWith('/sdcard/');

      String? matchedAssetId;
      String? matchedLocalPath;
      if (isMediaFile) {
        final match = await _resolveGalleryAsset(
          filename: originalPickName,
          fileSize: fileSize,
          fallbackPath: pickedPath,
          pickedIdentifier: pickedFile.identifier,
        );
        matchedAssetId = match?.assetId;
        matchedLocalPath = match?.localPath;
      }

      // Capture time = the device-identical gallery sort key. Prefer the
      // image's own EXIF; for a gallery-resolved video use MediaStore's
      // DATE_TAKEN. Null otherwise — sync falls back to the create op's
      // HLC wall, also identical on every device.
      int? capturedMs;
      if (fileBytes != null && isMediaFile && !isVideo) {
        capturedMs =
            await FileMetadataService.captureEpochFromImageBytes(fileBytes);
      }
      if (capturedMs == null && matchedAssetId != null) {
        try {
          final a = await AssetEntity.fromId(matchedAssetId);
          final dt = a?.createDateTime;
          if (dt != null && dt.millisecondsSinceEpoch > 0) {
            capturedMs = dt.millisecondsSinceEpoch;
          }
        } catch (_) {}
      }

      // Media dimensions/duration, captured while the plaintext is still
      // in hand — the ONLY moment they're free.
      int? mediaWidth;
      int? mediaHeight;
      int? mediaDurationMs;
      String? mediaVideoCodec;
      String? mediaAudioCodec;
      int? mediaFps;
      String? mediaDeviceModel;
      if (isVideo) {
        try {
          final meta = await Mp4MetadataParser.parse(File(pickedPath));
          mediaWidth = meta?.width;
          mediaHeight = meta?.height;
          mediaDurationMs = meta?.duration?.inMilliseconds;
          mediaVideoCodec = meta?.videoCodec;
          mediaAudioCodec = meta?.audioCodec;
          mediaFps = meta?.fps;
          mediaDeviceModel = meta?.deviceModel;
        } catch (e) {
          debugPrint('Video metadata parse failed: $e');
        }
      } else if (isMediaFile && fileBytes != null) {
        final dims = await _imageDimensions(fileBytes);
        mediaWidth = dims?.$1;
        mediaHeight = dims?.$2;
      }

      final newFile = CnestFile(
        id: fileId,
        filename: filename,
        sizeBytes: fileSize,
        createdAt: capturedMs != null
            ? DateTime.fromMillisecondsSinceEpoch(capturedMs)
            : DateTime.now(),
        isUploaded: false,
        localPath: matchedLocalPath ?? (isLocalFile ? pickedPath : null),
        assetId: matchedAssetId,
        type: type,
        provider: 0,
        accountId: currentEmail,
        width: mediaWidth,
        height: mediaHeight,
        durationMs: mediaDurationMs,
        videoCodec: mediaVideoCodec,
        audioCodec: mediaAudioCodec,
        fps: mediaFps,
        deviceModel: mediaDeviceModel,
        folderId: folderId,
      );

      await DatabaseService().addFile(newFile);
      // The heal pass must never touch this row while its upload runs.
      AutoSyncService.inFlightUploadIds.add(fileId);

      // Video WITHOUT a MediaStore binding: cache the just-generated thumb
      // locally, keyed by row id, so the grid shows a frame DURING upload.
      if (isVideo && thumbnailBytes != null && matchedAssetId == null) {
        try {
          final dir = await getTemporaryDirectory();
          await File('${dir.path}/thumb_local_$fileId.jpg')
              .writeAsBytes(thumbnailBytes);
        } catch (_) {
          // Best-effort — the tile just stays blank during upload.
        }
      }

      // Audio: keep a plaintext copy in the private audio cache so a track
      // uploaded from this device plays locally without a cloud
      // round-trip. The cache GC may evict it later.
      if (type == CnestFileType.audio && fileBytes != null) {
        final plainCopy = fileBytes;
        final audioFileId = fileId;
        getTemporaryDirectory().then((dir) async {
          try {
            await File('${dir.path}/${audioFileId}_audio.bin')
                .writeAsBytes(plainCopy);
          } catch (_) {
            // Best-effort cache write.
          }
        });
      }

      // --- 5. ENCRYPT & UPLOAD ---
      final mainCloudFilename = '$fileId.cnest';
      Future<String?> mainUploadFuture;
      Future<String>? contentHashFuture;

      if (isVideo && fileStream != null) {
        final encryptedSize =
            EncryptionService.calculateEncryptedSize(fileSize);
        final hashed = EncryptionService.encryptStreamWithHash(fileStream,
            totalSize: fileSize);
        contentHashFuture = hashed.hash;
        mainUploadFuture = CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: type,
          originalName: filename,
          stream: hashed.stream,
          size: encryptedSize,
          bytes: null,
        );
      } else if (preEncrypted != null) {
        contentHashFuture = Future.value(preEncrypted.hash);
        mainUploadFuture = CloudService().uploadEncryptedFile(
          filename: mainCloudFilename,
          type: type,
          originalName: filename,
          bytes: preEncrypted.encrypted,
        );
      } else {
        throw Exception('Invalid state');
      }

      Future<String?>? thumbUploadFuture;
      if (thumbnailBytes != null) {
        final encryptedThumbBytes =
            await EncryptionService.encryptFileInBackground(thumbnailBytes);
        thumbUploadFuture = CloudService().uploadEncryptedFile(
          bytes: encryptedThumbBytes,
          filename: '${fileId}_thumb.cnest',
          type: CnestFileType.image,
        );
      }

      final mainCloudId = await mainUploadFuture;
      final thumbCloudId =
          thumbUploadFuture != null ? await thumbUploadFuture : null;
      if (mainCloudId == null) throw Exception('Main upload failed');

      final contentHash = await contentHashFuture;

      await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId,
          filename: filename,
          contentHash: contentHash,
          sizeBytes: fileSize,
          capturedAt: capturedMs,
          folderId: folderId);
      DatabaseBackupService().scheduleBackup();

      // Prime the grid's thumb cache from bytes already in memory — only
      // for videos with no MediaStore binding (asset-bound videos render
      // from MediaStore).
      if (isVideo && thumbnailBytes != null && matchedAssetId == null) {
        try {
          final dir = await getTemporaryDirectory();
          await File('${dir.path}/thumb_$mainCloudId.jpg')
              .writeAsBytes(thumbnailBytes);
          final localThumb = File('${dir.path}/thumb_local_$fileId.jpg');
          if (await localThumb.exists()) await localThumb.delete();
        } catch (_) {}
      }

      return UploadOutcome._(filename, ok: true);
    } catch (e, s) {
      debugPrint('Upload failed: $e\n$s');
      // Roll the phantom row back HARD (not soft) — a failed upload must
      // vanish entirely, not land in the Recycle Bin as a mysterious
      // entry. Matches the auto-sync rollback.
      final rollbackId = fileId;
      if (rollbackId != null) {
        try {
          await DatabaseService().rollbackFailedUpload(rollbackId);
        } catch (rollbackErr) {
          debugPrint('Upload rollback failed: $rollbackErr');
        }
        try {
          final dir = await getTemporaryDirectory();
          for (final f in [
            File('${dir.path}/${rollbackId}_audio.bin'),
            File('${dir.path}/thumb_local_$rollbackId.jpg'),
          ]) {
            if (await f.exists()) await f.delete();
          }
        } catch (_) {}
      }
      return UploadOutcome._(filename, ok: false, error: e);
    } finally {
      if (fileId != null) AutoSyncService.inFlightUploadIds.remove(fileId);
      // The file_picker cache copy must die on BOTH outcomes. Real
      // on-device files (isLocalFile) are kept for local-first loading.
      if (pickedPath != null && !isLocalFile) {
        try {
          final pickerFile = File(pickedPath);
          if (await pickerFile.exists()) await pickerFile.delete();
        } catch (e) {
          debugPrint('Picker-copy cleanup warning: $e');
        }
      }
    }
  }

  /// Maps an upload failure to the friendly error surface. Quota first —
  /// its exceptions can carry connection-ish wording that the network
  /// classifier would misread.
  static CnestError mapUploadError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('storagequotaexceeded') ||
        msg.contains('quotalimitreached') ||
        msg.contains('quota exceeded')) {
      return const StorageFullError();
    }
    // Quota first: Drive's quota errors are 403s with auth-ish wording that
    // isAuthInvalidError must never claim.
    if (isAuthInvalidError(e)) return const TokenExpiredError();
    return classifyNetworkError(e) ??
        UnexpectedError(code: 'UPLOAD', debugDetail: e.toString());
  }

  /// Resolves a FilePicker pick to the corresponding photo_manager
  /// AssetEntity so the vault entry ties back to the phone's gallery.
  /// Three tiers, tried in order (see git history of home_screen for the
  /// full rationale): content-URI MediaStore id, aggregate-album filename
  /// scan, direct-path fallback.
  static Future<_GalleryAssetMatch?> _resolveGalleryAsset({
    required String filename,
    required int fileSize,
    required String fallbackPath,
    String? pickedIdentifier,
  }) async {
    // TIER 1 — content URI → MediaStore id.
    if (pickedIdentifier != null) {
      final id = extractMediaStoreId(pickedIdentifier);
      if (id != null) {
        try {
          final asset = await AssetEntity.fromId(id);
          if (asset != null) {
            final f = await asset.file;
            if (f != null) {
              return _GalleryAssetMatch(assetId: asset.id, localPath: f.path);
            }
          }
        } catch (e) {
          debugPrint('AssetEntity.fromId($id) failed: $e');
        }
      }
    }

    // TIER 2 — filename scan across the aggregate "all" album.
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (perm.isAuth) {
        final albums = await PhotoManager.getAssetPathList(
          type: RequestType.common,
          onlyAll: true,
        );
        if (albums.isNotEmpty) {
          final album = albums.first;
          final count = await album.assetCountAsync;
          final assets = count == 0
              ? const <AssetEntity>[]
              : await album.getAssetListRange(
                  start: 0,
                  end: count.clamp(0, 2000),
                );
          for (final a in assets) {
            if (a.title == filename) {
              final f = await a.file;
              if (f != null) {
                // Filename is not identity — require the byte length to
                // match too. (fileSize == 0 ⇒ unknown; accept on name.)
                if (fileSize > 0 && await f.length() != fileSize) continue;
                return _GalleryAssetMatch(assetId: a.id, localPath: f.path);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('_resolveGalleryAsset filename scan failed: $e');
    }

    // TIER 3 — direct-path fallback.
    if (fallbackPath.startsWith('/storage/') ||
        fallbackPath.startsWith('/sdcard/')) {
      return _GalleryAssetMatch(assetId: null, localPath: fallbackPath);
    }
    return null;
  }

  static Future<Uint8List?> _generatePdfThumbnail(Uint8List fileBytes) async {
    try {
      await for (final page
          in Printing.raster(fileBytes, pages: [0], dpi: 72)) {
        final pdfImage = await page.toImage();
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final paint = Paint()..color = const ui.Color(0xFFFFFFFF);
        canvas.drawRect(
            Rect.fromLTWH(0, 0, pdfImage.width.toDouble(),
                pdfImage.height.toDouble()),
            paint);
        canvas.drawImage(pdfImage, Offset.zero, Paint());
        final compositedImage = await recorder
            .endRecording()
            .toImage(pdfImage.width, pdfImage.height);
        final byteData =
            await compositedImage.toByteData(format: ui.ImageByteFormat.png);
        if (byteData == null) return null;
        final pngBytes = byteData.buffer.asUint8List();
        final jpegBytes = await FlutterImageCompress.compressWithList(
          pngBytes,
          minHeight: 300,
          minWidth: 300,
          quality: 60,
          format: CompressFormat.jpeg,
        );
        return jpegBytes;
      }
      return null;
    } catch (e) {
      debugPrint('PDF thumbnail failed: $e');
      return null;
    }
  }

  /// Header-only decode: dimensions without rasterizing the image.
  static Future<(int, int)?> _imageDimensions(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final dims = descriptor.width > 0 && descriptor.height > 0
          ? (descriptor.width, descriptor.height)
          : null;
      descriptor.dispose();
      buffer.dispose();
      return dims;
    } catch (_) {
      return null;
    }
  }
}
