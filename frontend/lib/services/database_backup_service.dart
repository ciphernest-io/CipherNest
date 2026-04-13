import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';

class DatabaseBackupService {
  static final DatabaseBackupService _instance =
      DatabaseBackupService._internal();
  factory DatabaseBackupService() => _instance;
  DatabaseBackupService._internal();

  static const String backupFileName = 'ciphernest_db_backup.cnest';

  bool _isBackingUp = false;
  Timer? _debounceTimer;

  /// Encrypts the SQLite database and uploads it to the cloud.
  /// Implements Last Write Wins: deletes any existing backup before uploading.
  Future<void> backupDatabase() async {
    if (_isBackingUp) return;
    _isBackingUp = true;

    try {
      final dbPath = await DatabaseService().getDatabasePath();
      await DatabaseService().closeDatabase();

      final dbFile = File(dbPath);
      if (!await dbFile.exists()) return;
      final dbBytes = await dbFile.readAsBytes();

      final encrypted = await EncryptionService.encryptFile(dbBytes);

      // Last Write Wins: remove existing backup
      final existingId = await CloudService().findFileByName(backupFileName);
      if (existingId != null) {
        await CloudService().deleteFile(existingId);
      }

      await CloudService().uploadEncryptedFile(
        filename: backupFileName,
        isImage: false,
        bytes: encrypted,
      );
    } catch (e) {
      debugPrint('Database backup failed: $e');
    } finally {
      _isBackingUp = false;
    }
  }

  /// Downloads and decrypts the cloud backup, replacing the local database.
  /// Returns true if restore succeeded, false if no backup found or error.
  Future<bool> restoreDatabase() async {
    try {
      final cloudId = await CloudService().findFileByName(backupFileName);
      if (cloudId == null) return false;

      final encrypted = await CloudService().downloadFile(cloudId);
      final decrypted = await EncryptionService.decryptFile(encrypted);

      // Validate SQLite header
      if (decrypted.length < 16 ||
          String.fromCharCodes(decrypted.sublist(0, 15)) !=
              'SQLite format 3') {
        debugPrint('Database backup: invalid SQLite header');
        return false;
      }

      final dbPath = await DatabaseService().getDatabasePath();
      await DatabaseService().closeDatabase();
      await File(dbPath).writeAsBytes(decrypted);

      return true;
    } catch (e) {
      debugPrint('Database restore failed: $e');
      return false;
    }
  }

  /// Checks whether a cloud backup exists.
  Future<bool> hasCloudBackup() async {
    final cloudId = await CloudService().findFileByName(backupFileName);
    return cloudId != null;
  }

  /// Debounced backup trigger. Collapses rapid calls into a single backup
  /// after a 5-second delay.
  void scheduleBackup() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 5), () {
      backupDatabase();
    });
  }
}
