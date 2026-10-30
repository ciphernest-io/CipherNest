import 'dart:io';

import 'package:exif/exif.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../src/models/album_model.dart';
import '../src/models/file_model.dart';
import 'audio_player_service.dart';
import 'cloud/cloud_service.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';
import 'subscription_service.dart';
import 'system_folders.dart';

/// Sets custom cover artwork for tracks and playlists, reusing the vault's
/// existing encrypted-blob machinery (no new schema, no new sync op).
///
/// Zero-knowledge: the picked image is compressed and encrypted in memory;
/// only ciphertext is uploaded, and the plaintext never touches disk.
///
///  - A TRACK cover replaces the track's encrypted thumbnail blob under its
///    canonical `<fileId>_thumb.cnest` name. `thumbnail_cloud_id` is a
///    device-local column that every peer re-derives by reconciling that
///    blob by stem (SyncEngine.applyMergedState), so swapping the blob is
///    all it takes to converge — this device's row is updated immediately
///    for a live UI.
///  - A PLAYLIST cover is a HIDDEN vault image (invisible to the gallery and
///    the other specialized views) referenced through the existing
///    setAlbumCover sync op, so it propagates like any album cover.
class CoverArtService {
  static final CoverArtService _instance = CoverArtService._internal();
  factory CoverArtService() => _instance;
  CoverArtService._internal();

  /// Prompts for an image from device storage and returns its bytes, or null
  /// if the user cancelled. Shared by the track- and playlist-cover flows.
  static Future<Uint8List?> pickImageBytes() async {
    return (await pickImageWithName())?.$1;
  }

  /// Like [pickImageBytes] but also returns the original filename, so a
  /// playlist cover can be stored under its real name in "Album Covers".
  static Future<(Uint8List, String)?> pickImageWithName() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final f = result.files.first;
    final bytes = f.bytes;
    if (bytes == null) return null;
    final name = (f.name.trim().isEmpty) ? 'cover.jpg' : f.name.trim();
    return (bytes, name);
  }

  /// Compresses [imageBytes] to a JPEG about [minSide] px on its short edge,
  /// applying EXIF orientation in Dart. The Android compressor reads
  /// orientation through ExifInterface, which returns 0 for HEIC and for
  /// some stream-only containers, so a portrait photo came out sideways.
  /// Reading it here and rotating explicitly fixes that.
  static Future<Uint8List> _orientedCompress(
    Uint8List imageBytes, {
    required int minSide,
    required int quality,
  }) async {
    var rotate = 0;
    try {
      final tags = await readExifFromBytes(imageBytes);
      final tag = tags['Image Orientation'];
      final o = tag == null ? 1 : tag.values.firstAsInt();
      rotate = switch (o) {
        6 => 90,
        3 => 180,
        8 => 270,
        _ => 0,
      };
    } catch (_) {
      // No/unreadable EXIF: assume upright.
    }
    final out = await FlutterImageCompress.compressWithList(
      imageBytes,
      minHeight: minSide,
      minWidth: minSide,
      quality: quality,
      rotate: rotate,
      // We applied orientation ourselves; don't let the plugin add its own
      // (mis)read on top.
      autoCorrectionAngle: false,
    );
    return out;
  }

  /// Get-or-create the hidden "Album Covers" folder for the active account,
  /// respecting a prior deletion/purge (never resurrects a binned one).
  static Future<String?> ensureAlbumCoversFolder() async {
    final email = CloudService().currentEmail;
    if (email == null) return null;
    final id = SystemFolders.albumCoversId(email);
    final existing = await DatabaseService().getFolderById(id);
    if (existing != null) return existing.isDeleted ? null : id;
    if (await DatabaseService().isFolderPurged(id)) return null;
    await DatabaseService()
        .createFolder(SystemFolders.albumCoversName, id: id);
    await DatabaseService().setFolderHidden(id, true);
    return id;
  }

  /// Sets [imageBytes] as [track]'s cover. Returns the refreshed row.
  Future<CnestFile> setTrackCover({
    required CnestFile track,
    required Uint8List imageBytes,
  }) async {
    if (track.cloudId == null) {
      throw Exception('This track is still syncing. Try again in a moment.');
    }
    // Cover-sized JPEG: this same blob is shown everywhere the track art
    // appears, up to the full-screen player, so keep it larger than a list
    // thumbnail but still small enough to fetch instantly.
    final coverBytes =
        await _orientedCompress(imageBytes, minSide: 720, quality: 78);
    final encrypted = await EncryptionService.encryptFile(coverBytes);

    final oldThumb = track.thumbnailCloudId;
    final newThumbId = await CloudService().uploadEncryptedFile(
      // Canonical thumb name — this is what peers reconcile by stem.
      filename: '${track.id}_thumb.cnest',
      type: CnestFileType.image,
      bytes: encrypted,
    );
    if (newThumbId == null) {
      throw Exception('Cover upload failed.');
    }
    // Exactly one <id>_thumb.cnest must exist or reconcile-by-stem is
    // ambiguous — drop the previous cover blob once the new one has landed.
    if (oldThumb != null && oldThumb != newThumbId) {
      try {
        await CloudService().deleteFile(oldThumb);
      } catch (e) {
        debugPrint('CoverArtService: old track thumb delete failed: $e');
      }
    }

    await DatabaseService().setThumbnailCloudId(track.id, newThumbId);
    await _clearThumbCache(track.cloudId!);

    final updated =
        await DatabaseService().getFileById(track.id) ?? track;
    AudioPlayerService().updateFile(updated);
    DatabaseBackupService().scheduleBackup();
    return updated;
  }

  /// Clears [track]'s custom cover (back to embedded art if any, else the
  /// note placeholder). Returns the refreshed row.
  Future<CnestFile> removeTrackCover(CnestFile track) async {
    final oldThumb = track.thumbnailCloudId;
    if (oldThumb != null) {
      try {
        await CloudService().deleteFile(oldThumb);
      } catch (e) {
        debugPrint('CoverArtService: track thumb delete failed: $e');
      }
    }
    await DatabaseService().setThumbnailCloudId(track.id, null);
    if (track.cloudId != null) await _clearThumbCache(track.cloudId!);

    final updated =
        await DatabaseService().getFileById(track.id) ?? track;
    AudioPlayerService().updateFile(updated);
    DatabaseBackupService().scheduleBackup();
    return updated;
  }

  /// Sets [imageBytes] as [playlist]'s cover by creating a hidden vault image
  /// and pointing the album cover at it. Reuses the create + setAlbumCover
  /// sync ops, so it converges across devices like any album cover.
  Future<void> setPlaylistCover({
    required CnestAlbum playlist,
    required Uint8List imageBytes,
    String? originalName,
  }) async {
    final email = CloudService().currentEmail;
    if (email == null) throw Exception('No active account.');
    final coversFolderId = await ensureAlbumCoversFolder();

    // The cover is a vault row (hidden from the gallery, but a slot all the
    // same) so it answers to the Free cap like every other upload.
    if (!await FreeTierGuard.canStoreMore()) {
      throw await FreeTierGuard.limitError();
    }

    // Main image (what a future full-size cover view would show) + a small
    // thumbnail (what the playlist grid renders), both encrypted in memory.
    final mainBytes =
        await _orientedCompress(imageBytes, minSide: 1080, quality: 82);
    final thumbBytes =
        await _orientedCompress(imageBytes, minSide: 400, quality: 60);
    final encMainFuture = EncryptionService.encryptFile(mainBytes);
    final encThumbFuture = EncryptionService.encryptFile(thumbBytes);
    final encMain = await encMainFuture;
    final encThumb = await encThumbFuture;

    final coverId = const Uuid().v4();
    // Keep the original filename the user picked; fall back to a readable
    // default. Stored inside the hidden "Album Covers" folder.
    final coverName = (originalName == null || originalName.trim().isEmpty)
        ? 'Cover (${playlist.name}).jpg'
        : originalName.trim();

    // Row before upload (markAsUploaded updates it) — the insert-before-upload
    // contract every other upload site follows.
    await DatabaseService().addFile(CnestFile(
      id: coverId,
      filename: coverName,
      sizeBytes: mainBytes.length,
      createdAt: DateTime.now(),
      type: CnestFileType.image,
      provider: CloudService().activeProviderType,
      accountId: email,
      localPath: null,
      assetId: null,
      isUploaded: false,
      // Kept out of the gallery and every specialized view.
      isHidden: true,
      // Tucked into the hidden Album Covers folder so it never shows at the
      // vault root in the Files browser (null folderId = root).
      folderId: coversFolderId,
    ));

    String? mainCloudId;
    String? thumbCloudId;
    Object? uploadError;
    StackTrace? uploadStack;
    void capture(Object e, StackTrace s) {
      uploadError ??= e;
      uploadStack ??= s;
    }

    await Future.wait<void>([
      CloudService()
          .uploadEncryptedFile(
            filename: '$coverId.cnest',
            type: CnestFileType.image,
            originalName: coverName,
            bytes: encMain,
          )
          .then<void>((id) => mainCloudId = id)
          .catchError(capture),
      CloudService()
          .uploadEncryptedFile(
            filename: '${coverId}_thumb.cnest',
            type: CnestFileType.image,
            bytes: encThumb,
          )
          .then<void>((id) => thumbCloudId = id)
          .catchError(capture),
    ]);

    try {
      final err = uploadError;
      if (err != null) Error.throwWithStackTrace(err, uploadStack!);
      if (mainCloudId == null) {
        throw Exception('Cover upload failed: main blob did not upload.');
      }
      await DatabaseService().markAsUploaded(
        coverId,
        mainCloudId!,
        thumbCloudId,
        filename: coverName,
        sizeBytes: mainBytes.length,
      );
      // Hidden flag rides its own op so peers keep it out of their views too.
      await DatabaseService().setFileHidden(coverId, true);
      await DatabaseService().setAlbumCover(playlist.id, coverId);
      // Reclaim the PREVIOUS custom cover so repeatedly changing a playlist's
      // cover doesn't leave orphaned hidden images piling up in the vault.
      await _deleteOwnedCover(playlist.coverFileId);
    } catch (e) {
      // Roll the phantom row back and reclaim any blob that landed.
      try {
        await DatabaseService().rollbackFailedUpload(coverId);
      } catch (_) {}
      for (final orphan in [mainCloudId, thumbCloudId]) {
        if (orphan != null) {
          try {
            await CloudService().deleteFile(orphan);
          } catch (_) {}
        }
      }
      rethrow;
    }

    DatabaseBackupService().scheduleBackup();
  }

  /// Permanently removes a hidden playlist cover WE created (its blobs + row).
  /// Guarded so it never touches a real vault file: only files that are
  /// hidden and carry our cover naming are reclaimed.
  Future<void> _deleteOwnedCover(String? coverFileId) async {
    if (coverFileId == null) return;
    try {
      final old = await DatabaseService().getFileById(coverFileId);
      if (old == null || !old.isHidden) return;
      // Only reclaim files WE created as covers: hidden, and either in the
      // Album Covers folder (named originals) or carrying the legacy
      // "Cover (" name from before the folder existed.
      final coversFolderId = SystemFolders.albumCoversId(
          CloudService().currentEmail ?? '');
      final ours = old.folderId == coversFolderId ||
          old.filename.startsWith('Cover (');
      if (!ours) return;
      for (final blob in [old.cloudId, old.thumbnailCloudId]) {
        if (blob != null) {
          try {
            await CloudService().deleteFile(blob);
          } catch (_) {}
        }
      }
      await DatabaseService().permanentlyDeleteFile(old.id);
    } catch (e) {
      debugPrint('CoverArtService: old cover cleanup failed: $e');
    }
  }

  /// Permanently removes [playlist]'s custom cover (its blobs and hidden
  /// row) and clears the album's cover reference. The playlist falls back to
  /// its note-on-grey placeholder, or to the most-recent-track cover that
  /// [DatabaseService.getAlbumCoverFile] derives.
  Future<void> removePlaylistCover(CnestAlbum playlist) async {
    final coverId = playlist.coverFileId;
    // Clear the reference first so the UI stops pointing at the file even
    // if blob deletion lags.
    await DatabaseService().setAlbumCover(playlist.id, null);
    await _deleteOwnedCover(coverId);
    DatabaseBackupService().scheduleBackup();
  }

  Future<void> _clearThumbCache(String cloudId) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File('${dir.path}/thumb_$cloudId.jpg');
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('CoverArtService: thumb cache clear failed: $e');
    }
  }
}
