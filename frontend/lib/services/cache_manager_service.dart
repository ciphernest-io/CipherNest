import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CacheManagerService {
  // Singleton pattern (optional, but good for services)
  static final CacheManagerService _instance = CacheManagerService._internal();
  factory CacheManagerService() => _instance;
  CacheManagerService._internal();

  /// Eviction priority for a cache file path:
  /// - 1 = full-size decrypted plaintext (`*_decrypted.jpg`, `*_decrypted.mp4`):
  ///       large, easy to regenerate on next view. Evict these first.
  /// - 0 = everything else, including `thumb_*.jpg`: small, expensive
  ///       (decrypt cost) to regenerate, and what keeps the gallery smooth.
  ///       Evict last.
  int _evictionPriority(String path) {
    final name = path.split(Platform.pathSeparator).last;
    if (name.endsWith('_decrypted.jpg') || name.endsWith('_decrypted.mp4')) {
      return 1;
    }
    return 0;
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
      }

    } catch (e) {
      debugPrint("Cache Manager Error: $e");
    }
  }
}