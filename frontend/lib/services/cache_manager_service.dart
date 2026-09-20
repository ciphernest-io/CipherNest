import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'database_service.dart';
import 'local_content_guard.dart';

/// Extends [ChangeNotifier] so the Settings cache-size tile, the Home vault
/// usage card, and any other consumer can subscribe and rebuild the moment
/// cache contents change — instead of only picking up the delta when the
/// screen remounts.
class CacheManagerService extends ChangeNotifier {
  // Singleton pattern (optional, but good for services)
  static final CacheManagerService _instance = CacheManagerService._internal();
  factory CacheManagerService() => _instance;
  CacheManagerService._internal();

  /// Announce that the cache pool changed out-of-band (e.g. a bulk wipe done
  /// by deleting the temp dir directly, which bypasses this service's own
  /// delete paths). Lets the Settings cache-usage card and size tile re-scan.
  void notifyCacheChanged() => notifyListeners();

  /// Eviction priority for a cache file path:
  /// - 1 = large plaintext that's cheap to regenerate:
  ///       `*_decrypted.jpg`, `*_decrypted.mp4`, `*_audio.bin`,
  ///       `share_*` blobs, and decrypted document plaintext.
  ///       Evict these first.
  /// - 0 = everything else, including `thumb_*.jpg`: small, expensive
  ///       (decrypt cost) to regenerate, and what keeps the gallery smooth.
  ///       Evict last.
  ///
  /// The pre-S19 version only bumped `_decrypted.jpg` / `_decrypted.mp4` into
  /// priority 1. Audio `.bin` payloads (can be tens of MB per track) and
  /// decrypted document plaintext (whole PDFs) were grouped with thumbnails,
  /// so a single big audio file could keep hundreds of thumbs from being
  /// evicted — starving the gallery of its most-expensive-to-regen artifacts
  /// to save something the user can trivially re-fetch.
  int _evictionPriority(String path) {
    final name = path.split(Platform.pathSeparator).last;
    if (name.startsWith('thumb_')) return 0;
    if (name.endsWith('_decrypted.jpg') ||
        name.endsWith('_decrypted.mp4') ||
        name.endsWith('_audio.bin') ||
        name.startsWith('share_')) {
      return 1;
    }
    // Decrypted document / other-file plaintext writes under the file's own
    // name (e.g. `report.pdf`). Anything not a thumbnail is treated as a
    // large-plaintext candidate. file_picker/ copies land here too — full
    // plaintext source copies, first out the door.
    return 1;
  }

  /// True for a file inside file_picker's cache-copy dir that was touched
  /// within the last 15 minutes — likely the SOURCE of an upload running
  /// right now. Evicting it mid-stream kills the upload.
  bool _isFreshPickerCopy(File f) {
    if (!f.path.contains('${Platform.pathSeparator}file_picker')) {
      return false;
    }
    try {
      final age = DateTime.now().difference(f.lastModifiedSync());
      return age < const Duration(minutes: 15);
    } catch (_) {
      return false;
    }
  }

  /// Wipes every decrypted-artifact cache file we might have written for a
  /// single vault file. Called on soft-delete so the grid stops rendering
  /// its thumbnail immediately AND so a re-uploaded file with the same
  /// [fileId] doesn't inherit the previous session's plaintext by mistake.
  ///
  /// Cache-filename layout (must stay in sync with sync_service.dart et al):
  ///   `thumb_{cloudId}.jpg`
  ///   `{cloudId}_decrypted.jpg`
  ///   `{fileId}_decrypted.mp4`         (video plaintext is keyed by local id)
  ///   `thumb_{thumbnailCloudId}.jpg`   (only when a separate thumbnail blob
  ///                                     was uploaded to the cloud)
  ///   `thumb_local_{fileId}.jpg`       (pre-upload video thumb, shown while
  ///                                     the upload is still running)
  ///   `video_{cloudId}.plain`          (streaming server's plaintext chunk
  ///                                     cache + its `.done` marker and
  ///                                     `.idx` chunk index)
  ///
  /// Best-effort. A missing file is not an error. A failing delete is logged
  /// but ignored — the LRU sweep in [enforceCacheLimit] will pick it up on
  /// the next tick.
  Future<void> invalidateFile({
    String? fileId,
    String? cloudId,
    String? thumbnailCloudId,
  }) async {
    bool anyDeleted = false;
    try {
      final tempDir = await getTemporaryDirectory();
      final candidates = <File>[
        if (cloudId != null) File('${tempDir.path}/thumb_$cloudId.jpg'),
        if (cloudId != null)
          File('${tempDir.path}/${cloudId}_decrypted.jpg'),
        if (fileId != null)
          File('${tempDir.path}/${fileId}_decrypted.mp4'),
        if (fileId != null)
          File('${tempDir.path}/thumb_local_$fileId.jpg'),
        if (thumbnailCloudId != null)
          File('${tempDir.path}/thumb_$thumbnailCloudId.jpg'),
        if (cloudId != null) File('${tempDir.path}/video_$cloudId.plain'),
        if (cloudId != null)
          File('${tempDir.path}/video_$cloudId.plain.done'),
        if (cloudId != null)
          File('${tempDir.path}/video_$cloudId.plain.idx'),
      ];
      for (final f in candidates) {
        try {
          if (await f.exists()) {
            await f.delete();
            anyDeleted = true;
          }
        } catch (e) {
          debugPrint('Cache Manager: could not delete ${f.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('Cache Manager: invalidateFile error: $e');
    }
    if (anyDeleted) notifyListeners();
  }

  /// Wipes only the LARGE plaintext artifacts for a file — the streamed
  /// video chunk cache (`.plain` + sidecars), the full decrypted video
  /// copy, and the full decrypted image. NEVER thumbnails: thumbs are
  /// small, expensive to regenerate (download + decrypt), needed by the
  /// grid/viewer/filmstrip alike, and governed exclusively by the LRU
  /// sweep. (An earlier version deleted thumbs here too — the grid
  /// reclaimed them on every gallery visit while the viewer re-created
  /// them on every open, a tug-of-war that made the Settings cache figure
  /// oscillate and wasted a download+decrypt per round.)
  Future<void> invalidateLargePlaintext({
    String? fileId,
    String? cloudId,
  }) async {
    bool anyDeleted = false;
    try {
      final tempDir = await getTemporaryDirectory();
      final candidates = <File>[
        if (cloudId != null) File('${tempDir.path}/video_$cloudId.plain'),
        if (cloudId != null)
          File('${tempDir.path}/video_$cloudId.plain.done'),
        if (cloudId != null)
          File('${tempDir.path}/video_$cloudId.plain.idx'),
        if (cloudId != null)
          File('${tempDir.path}/${cloudId}_decrypted.jpg'),
        if (fileId != null)
          File('${tempDir.path}/${fileId}_decrypted.mp4'),
      ];
      for (final f in candidates) {
        try {
          if (await f.exists()) {
            await f.delete();
            anyDeleted = true;
          }
        } catch (e) {
          debugPrint('Cache Manager: could not delete ${f.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('Cache Manager: invalidateLargePlaintext error: $e');
    }
    if (anyDeleted) notifyListeners();
  }

  /// Reclaim for a file VERIFIED to be served by its MediaStore original:
  /// large plaintext PLUS the decrypted thumbnail copies. Thumbs were
  /// historically spared to avoid a delete/re-download tug-of-war with the
  /// viewer/filmstrip/stories persist paths — but every persist site is now
  /// gated `assetId == null`, so for MediaStore-bound files nothing
  /// re-creates these. Without this, a thumb downloaded while the local
  /// original was temporarily missing (deleted from the phone gallery, then
  /// restored) lingered forever.
  Future<void> reclaimForMediaStoreOriginal({
    required String fileId,
    String? cloudId,
  }) async {
    await invalidateLargePlaintext(fileId: fileId, cloudId: cloudId);
    bool anyDeleted = false;
    try {
      final tempDir = await getTemporaryDirectory();
      final candidates = <File>[
        if (cloudId != null) File('${tempDir.path}/thumb_$cloudId.jpg'),
        File('${tempDir.path}/thumb_local_$fileId.jpg'),
      ];
      for (final f in candidates) {
        try {
          if (await f.exists()) {
            await f.delete();
            anyDeleted = true;
          }
        } catch (e) {
          debugPrint('Cache Manager: could not delete ${f.path}: $e');
        }
      }
    } catch (e) {
      debugPrint('Cache Manager: reclaimForMediaStoreOriginal error: $e');
    }
    if (anyDeleted) notifyListeners();
  }

  /// Owner of a CipherNest cache artifact, derived from its filename:
  /// `('cloud', <cloudId>)` for cloud-id-keyed artifacts, `('file', <rowId>)`
  /// for row-id-keyed ones, null for files we don't manage (wallpaper temp,
  /// system residue). Pure so the mapping is unit-testable.
  @visibleForTesting
  static (String, String)? cacheArtifactOwner(String name) {
    if (name.startsWith('thumb_local_') && name.endsWith('.jpg')) {
      return ('file', name.substring('thumb_local_'.length, name.length - 4));
    }
    if (name.startsWith('thumb_') && name.endsWith('.jpg')) {
      return ('cloud', name.substring('thumb_'.length, name.length - 4));
    }
    if (name.startsWith('video_')) {
      for (final suffix in const ['.plain.done', '.plain.idx', '.plain']) {
        if (name.endsWith(suffix)) {
          return (
            'cloud',
            name.substring('video_'.length, name.length - suffix.length),
          );
        }
      }
      return null;
    }
    if (name.endsWith('_decrypted.jpg')) {
      return ('cloud', name.substring(0, name.length - '_decrypted.jpg'.length));
    }
    if (name.endsWith('_decrypted.mp4')) {
      return ('file', name.substring(0, name.length - '_decrypted.mp4'.length));
    }
    return null;
  }

  /// Deterministic leftover sweep, run once per sync cycle.
  ///
  /// The per-tile reclaim (grid rung 1 / stories rung 1) is opportunistic:
  /// the grid's session memo can skip its ladder entirely, and Stories only
  /// builds the cards its selection includes — so a thumbnail downloaded
  /// while a local original was temporarily missing (gallery delete →
  /// restore) could outlive the restore indefinitely. This sweep closes
  /// that: every cache artifact is mapped to its owning row, and when that
  /// row's MediaStore asset currently resolves AND verifies
  /// (LocalContentGuard), the artifact is by definition a stale leftover —
  /// reclaimed. Artifacts whose asset does NOT resolve are left alone: they
  /// are the only display source.
  Future<void> reclaimMediaStoreServedLeftovers() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;

      final cloudIds = <String>{};
      final fileIds = <String>{};
      // Root only, deliberately: subdirectories are plugin/system caches
      // and picker copies, never vault artifacts.
      for (final f in tempDir.listSync(followLinks: false)) {
        if (f is! File) continue;
        final owner = cacheArtifactOwner(f.uri.pathSegments.last);
        if (owner == null) continue;
        (owner.$1 == 'cloud' ? cloudIds : fileIds).add(owner.$2);
      }
      if (cloudIds.isEmpty && fileIds.isEmpty) return;

      final rows = await DatabaseService()
          .getMediaStoreBoundFiles(cloudIds: cloudIds, fileIds: fileIds);
      for (final row in rows) {
        try {
          final asset = await AssetEntity.fromId(row.assetId!);
          if (asset == null) continue;
          if (!await LocalContentGuard.matches(row, asset: asset)) continue;
          await reclaimForMediaStoreOriginal(
            fileId: row.id,
            cloudId: row.cloudId,
          );
        } catch (_) {
          // Asset resolution failed — the artifacts are still needed.
        }
      }
    } catch (e) {
      debugPrint('Cache Manager: leftover sweep error: $e');
    }
  }

  /// The Main Function: Checks limits and deletes old files if necessary.
  /// Deletes every large decrypted artifact in the cache, regardless of the
  /// size budget. Thumbnails are kept: they are small, expensive to
  /// regenerate, and cleared from memory separately on lock.
  ///
  /// Called when the vault locks. Until this existed, locking cleared the
  /// in-memory key and nothing else, so whole decrypted videos, audio tracks
  /// and images stayed readable on disk behind a login screen. A device test
  /// pulled them straight out of the cache directory with the app not even
  /// running (MASVS F-01 and F-02).
  ///
  /// Best effort. A failed delete is picked up by the LRU sweep later.
  Future<int> purgeAllLargePlaintext() async {
    var deleted = 0;
    try {
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return 0;
      await for (final entity in tempDir.list(recursive: true)) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        // Thumbnails survive; everything classed as large plaintext goes.
        if (name.startsWith('thumb_')) continue;
        if (_evictionPriority(entity.path) != 1) continue;
        // Never yank a picker copy out from under an in-flight upload.
        if (_isFreshPickerCopy(entity)) continue;
        try {
          await entity.delete();
          deleted++;
        } catch (e) {
          debugPrint('Cache Manager: lock purge could not delete $name: $e');
        }
      }
    } catch (e) {
      debugPrint('Cache Manager: lock purge error: $e');
    }
    if (deleted > 0) notifyListeners();
    return deleted;
  }

  Future<void> enforceCacheLimit() async {
    try {
      // 1. Get the User's Limit (GB)
      final prefs = await SharedPreferences.getInstance();
      final limitGB = prefs.getDouble('cache_limit') ?? 0.5; // Default 500MB
      final limitBytes = (limitGB * 1024 * 1024 * 1024).toInt();

      // 2. Get Cache Directory
      final tempDir = await getTemporaryDirectory();
      if (!await tempDir.exists()) return;

      // 3. List & sort files by (priority desc, mtime asc) — evict bulky
      //    full-image plaintext first; only touch the small thumbnails once
      //    no full-image plaintext remains, since they're expensive to
      //    regenerate (cloud download + decrypt) and the thing that keeps
      //    the gallery smooth.
      //    RECURSIVE: the Settings size figure walks subdirectories, so the
      //    sweep must too — a non-recursive listing left file_picker/
      //    copies invisible to eviction while fully counted on screen.
      //    Fresh picker copies are excluded: they may be the source of an
      //    upload in flight.
      List<File> cacheFiles = tempDir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((f) => !_isFreshPickerCopy(f))
          .toList();

      if (cacheFiles.isEmpty) return;

      cacheFiles.sort((a, b) {
        final pa = _evictionPriority(a.path);
        final pb = _evictionPriority(b.path);
        if (pa != pb) return pb.compareTo(pa); // higher priority first
        return a.lastModifiedSync().compareTo(b.lastModifiedSync());
      });

      // 4. Calculate Current Usage
      int currentUsage = 0;
      for (var file in cacheFiles) {
        currentUsage += await file.length();
      }

      debugPrint("Cache Manager: Usage ${(currentUsage / 1024 / 1024).toStringAsFixed(2)} MB / Limit ${(limitBytes / 1024 / 1024).toStringAsFixed(2)} MB");

      // 5. Purge loop — evict from the front of the sorted list (highest
      //    priority + oldest) until we're under budget.
      int deletedCount = 0;
      while (currentUsage > limitBytes && cacheFiles.isNotEmpty) {
        final victim = cacheFiles.removeAt(0);
        final size = await victim.length();

        try {
          await victim.delete();
          currentUsage -= size;
          deletedCount++;
        } catch (e) {
          debugPrint("Could not delete ${victim.path}: $e");
        }
      }

      if (deletedCount > 0) {
        debugPrint("Cache Manager: Cleaned up $deletedCount files.");
        notifyListeners();
      }

    } catch (e) {
      debugPrint("Cache Manager Error: $e");
    }
  }
}