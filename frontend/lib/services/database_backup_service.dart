import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../src/models/file_model.dart';
import 'activity_center.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'device_identity_service.dart';
import 'encryption_service.dart';

/// One cloud snapshot of the metadata database.
class BackupSnapshot {
  final String cloudId;
  final String name;

  /// Null for the legacy single-filename format.
  final String? deviceId;
  final DateTime? modified;
  final int sizeBytes;
  final bool isThisDevice;

  const BackupSnapshot({
    required this.cloudId,
    required this.name,
    required this.deviceId,
    required this.modified,
    required this.sizeBytes,
    required this.isThisDevice,
  });

  bool get isLegacy => deviceId == null;
}

/// Encrypted cloud snapshots of the SQLite metadata database.
///
/// STAGE 1 OF MULTI-DEVICE SYNC — destruction is now structurally
/// impossible: every device writes to its OWN snapshot name
/// (`db_backup_<deviceId>.cnest`) and never touches another device's.
/// The old single fixed filename was unconditional Last-Write-Wins: two
/// devices meant one silently obliterated the other's entire metadata DB,
/// orphaning every blob the loser knew about. That call path no longer
/// exists.
///
/// Conflicts remain unsolved in Stage 1 (each device's snapshot is its own
/// view); the op-log (Stage 2) builds convergence on top of this floor.
class DatabaseBackupService {
  static final DatabaseBackupService _instance =
      DatabaseBackupService._internal();
  factory DatabaseBackupService() => _instance;
  DatabaseBackupService._internal();

  /// Pre-Stage-1 fixed filename. Read-only legacy: still restorable, never
  /// written again. Providers also use this to route to the backup/ folder.
  static const String legacyBackupFileName = 'ciphernest_db_backup.cnest';

  static const String backupPrefix = 'db_backup_';

  /// True for anything that must live in backup/ and skip vault-file
  /// metadata treatment — both snapshot generations.
  static bool isBackupFile(String filename) =>
      filename == legacyBackupFileName ||
      (filename.startsWith(backupPrefix) && filename.endsWith('.cnest'));

  /// Extracts the device id from a per-device snapshot name; null for the
  /// legacy name or anything unrecognized.
  static String? deviceIdFromName(String filename) {
    if (!filename.startsWith(backupPrefix) || !filename.endsWith('.cnest')) {
      return null;
    }
    final id = filename.substring(
        backupPrefix.length, filename.length - '.cnest'.length);
    return id.isEmpty ? null : id;
  }

  bool _isBackingUp = false;
  Timer? _debounceTimer;

  Future<String> _thisDeviceBackupName() async =>
      '$backupPrefix${await DeviceIdentityService().deviceId()}.cnest';

  /// Encrypts the SQLite database and uploads it as THIS device's snapshot.
  /// Replaces only our own previous snapshot; other devices' snapshots are
  /// never listed for deletion, let alone touched.
  ///
  /// Returns whether the backup LANDED — errors are swallowed here (a
  /// debounced janitor must never throw into its trigger), so callers that
  /// want to report success must branch on the return, not on "no throw".
  Future<bool> backupDatabase() async {
    if (_isBackingUp) return false;
    _isBackingUp = true;

    // Quiet task: debounce-triggered janitorial work — sheet history while
    // running, surfaces ONLY a failure (as an error toast).
    final task = ActivityCenter().start(
        kind: ActivityKind.dbBackup,
        label: 'Backing up vault index…',
        visibility: ActivityVisibility.quiet);
    try {
      final dbPath = await DatabaseService().getDatabasePath();
      await DatabaseService().closeDatabase();

      final dbFile = File(dbPath);
      if (!await dbFile.exists()) {
        task.discard(); // nothing to back up — not a failure, not history
        return false;
      }
      final dbBytes = await dbFile.readAsBytes();

      final encrypted = await EncryptionService.encryptFile(dbBytes);
      final ownName = await _thisDeviceBackupName();

      // Replace our own previous snapshot only.
      final existingOwnId = await CloudService().findFileByName(ownName);
      if (existingOwnId != null) {
        await CloudService().deleteFile(existingOwnId);
      }

      await CloudService().uploadEncryptedFile(
        filename: ownName,
        type: CnestFileType.other,
        bytes: encrypted,
      );

      // The legacy single-name snapshot is strictly older data from the
      // pre-Stage-1 build; once a per-device snapshot exists, retire it so
      // the restore picker doesn't show a stale entry forever.
      final legacyId =
          await CloudService().findFileByName(legacyBackupFileName);
      if (legacyId != null) {
        await CloudService().deleteFile(legacyId);
      }
      task.complete('Vault index backed up');
      return true;
    } catch (e) {
      debugPrint('Database backup failed: $e');
      task.fail('Vault index backup failed');
      return false;
    } finally {
      _isBackingUp = false;
    }
  }

  /// All snapshots in the cloud's backup folder, newest first.
  Future<List<BackupSnapshot>> listSnapshots() async {
    final ownId = await DeviceIdentityService().deviceId();
    final raw = await CloudService().listBackups();
    final out = <BackupSnapshot>[];
    for (final f in raw) {
      final name = f['name'] as String? ?? '';
      if (!isBackupFile(name)) continue;
      final devId = deviceIdFromName(name);
      DateTime? modified;
      final m = f['modified'];
      if (m is String) modified = DateTime.tryParse(m);
      int size = 0;
      if (f['size'] is int) {
        size = f['size'] as int;
      } else if (f['size'] is String) {
        size = int.tryParse(f['size'] as String) ?? 0;
      }
      out.add(BackupSnapshot(
        cloudId: f['id'] as String,
        name: name,
        deviceId: devId,
        modified: modified,
        sizeBytes: size,
        isThisDevice: devId == ownId,
      ));
    }
    sortSnapshots(out);
    return out;
  }

  /// Newest first; unknown dates sink to the end (legacy typically has one).
  @visibleForTesting
  static void sortSnapshots(List<BackupSnapshot> snapshots) {
    snapshots.sort((a, b) {
      final am = a.modified, bm = b.modified;
      if (am == null && bm == null) return 0;
      if (am == null) return 1;
      if (bm == null) return -1;
      return bm.compareTo(am);
    });
  }

  /// True when another device has written a snapshot to this vault —
  /// the Stage 1 signal for the "multi-device sync is coming" notice.
  Future<bool> hasForeignSnapshots() async {
    final snapshots = await listSnapshots();
    return snapshots.any((s) => !s.isLegacy && !s.isThisDevice);
  }

  /// Downloads and decrypts a snapshot, replacing the local database.
  /// [cloudId] selects a specific snapshot (from [listSnapshots]); when
  /// null, the newest available one is used.
  Future<bool> restoreDatabase({String? cloudId}) async {
    try {
      var targetId = cloudId;
      if (targetId == null) {
        final snapshots = await listSnapshots();
        if (snapshots.isEmpty) return false;
        targetId = snapshots.first.cloudId;
      }

      final encrypted = await CloudService().downloadFile(targetId);
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

  /// Whether any snapshot (either generation) exists.
  Future<bool> hasCloudBackup() async {
    final snapshots = await listSnapshots();
    return snapshots.isNotEmpty;
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
