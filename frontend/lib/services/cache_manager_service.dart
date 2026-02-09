import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CacheManagerService {
  // Singleton pattern (optional, but good for services)
  static final CacheManagerService _instance = CacheManagerService._internal();
  factory CacheManagerService() => _instance;
  CacheManagerService._internal();

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

      // 3. List & Sort Files (Oldest First)
      // We explicitly check for File type to ignore subdirectories
      List<FileSystemEntity> files = tempDir.listSync();
      
      // Filter only files (not directories)
      List<File> cacheFiles = files.whereType<File>().toList();

      if (cacheFiles.isEmpty) return;

      // Sort: Oldest "Last Modified" at the start of the list
      cacheFiles.sort((a, b) {
        return a.lastModifiedSync().compareTo(b.lastModifiedSync());
      });

      // 4. Calculate Current Usage
      int currentUsage = 0;
      for (var file in cacheFiles) {
        currentUsage += await file.length();
      }

      debugPrint("Cache Manager: Usage ${(currentUsage / 1024 / 1024).toStringAsFixed(2)} MB / Limit ${(limitBytes / 1024 / 1024).toStringAsFixed(2)} MB");

      // 5. Purge Loop
      // While we are over the limit, delete the oldest file (index 0)
      int deletedCount = 0;
      while (currentUsage > limitBytes && cacheFiles.isNotEmpty) {
        final oldestFile = cacheFiles.removeAt(0); // Remove from list
        final size = await oldestFile.length();
        
        try {
          await oldestFile.delete();
          currentUsage -= size; // Update our running total
          deletedCount++;
        } catch (e) {
          debugPrint("Could not delete ${oldestFile.path}: $e");
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