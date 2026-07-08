import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Extends [ChangeNotifier] so the Settings cache-size tile, the Home vault
/// usage card, and any other consumer can subscribe and rebuild the moment
/// cache contents change — instead of only picking up the delta when the
/// screen remounts.
class CacheManagerService extends ChangeNotifier {
  // Singleton pattern (optional, but good for services)
  static final CacheManagerService _instance = CacheManagerService._internal();
  factory CacheManagerService() => _instance;
  CacheManagerService._internal();

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
    // large-plaintext candidate.
    return 1;
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
        if (thumbnailCloudId != null)
          File('${tempDir.path}/thumb_$thumbnailCloudId.jpg'),
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

  /// The Main Function: Checks limits and deletes old files if necessary.
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
      List<File> cacheFiles =
          tempDir.listSync().whereType<File>().toList();

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