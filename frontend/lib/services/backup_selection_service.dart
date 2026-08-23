import 'package:shared_preferences/shared_preferences.dart';

import 'system_folders.dart';

/// Which device albums (MediaStore buckets) auto-sync backs up.
enum BackupMode {
  /// Every album on this phone, including buckets that appear later.
  all,

  /// Only the explicitly enrolled albums (Ente-style checklist).
  selected,
}

/// Immutable snapshot of the user's backup-album choice.
class BackupSelection {
  final BackupMode mode;

  /// Normalized ([SystemFolders.normalize]) bucket names. Meaningful only
  /// in [BackupMode.selected]; kept across mode switches so flipping
  /// all -> selected -> all doesn't lose the checklist.
  final Set<String> enrolled;

  const BackupSelection({required this.mode, required this.enrolled});

  /// Whether assets from [bucketName] should back up.
  bool includes(String bucketName) =>
      mode == BackupMode.all ||
      enrolled.contains(SystemFolders.normalize(bucketName));
}

/// Device-global backup-album selection, persisted in SharedPreferences
/// (same scope as the auto-sync watermark: one choice per phone, applied
/// to whichever account is active — the tree it lands in is account-salted
/// regardless).
///
/// `pendingBackfill` is the set of enrolled albums whose "include existing
/// photos" backfill hasn't completed yet. The backfill runner clears an
/// entry only after a clean pass, so an interrupted backfill retries on the
/// next sync cycle (re-runs are safe: the migration dedup index skips
/// everything already vaulted).
class BackupSelectionService {
  static final BackupSelectionService _instance =
      BackupSelectionService._internal();
  factory BackupSelectionService() => _instance;
  BackupSelectionService._internal();

  static const String _kMode = 'backup_selection_mode';
  static const String _kEnrolled = 'backup_enrolled_buckets';
  static const String _kPendingBackfill = 'backup_pending_backfill';

  /// SharedPreferences caches per isolate. The background sync worker runs
  /// in its own isolate, so every read-modify-write on the shared sets must
  /// reload first or it writes back a stale snapshot — the worker's
  /// clearBackfill could silently erase an album the foreground enrolled
  /// seconds earlier (same reason AutoSyncService.acquireRunLease reloads).
  Future<SharedPreferences> _freshPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }

  Future<BackupSelection> load() async {
    final prefs = await SharedPreferences.getInstance();
    // Absent pref = ALL: preserves the pre-selection behavior (sync
    // everything) for installs that enabled auto-sync before this existed.
    final mode = prefs.getString(_kMode) == 'selected'
        ? BackupMode.selected
        : BackupMode.all;
    final enrolled = (prefs.getStringList(_kEnrolled) ?? const []).toSet();
    return BackupSelection(mode: mode, enrolled: enrolled);
  }

  Future<void> setMode(BackupMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _kMode, mode == BackupMode.selected ? 'selected' : 'all');
  }

  /// Enrolls [bucketName]; with [backfill] its existing photos are queued
  /// for the bucket-scoped backfill runner.
  Future<void> enroll(String bucketName, {required bool backfill}) async {
    final prefs = await _freshPrefs();
    final key = SystemFolders.normalize(bucketName);
    final enrolled = (prefs.getStringList(_kEnrolled) ?? []).toSet()..add(key);
    await prefs.setStringList(_kEnrolled, enrolled.toList());
    if (backfill) {
      final pending = (prefs.getStringList(_kPendingBackfill) ?? []).toSet()
        ..add(key);
      await prefs.setStringList(_kPendingBackfill, pending.toList());
    }
  }

  /// Removes [bucketName] from the checklist (and any queued backfill).
  /// Already-vaulted copies stay — unenrolling only stops future uploads.
  Future<void> unenroll(String bucketName) async {
    final prefs = await _freshPrefs();
    final key = SystemFolders.normalize(bucketName);
    final enrolled = (prefs.getStringList(_kEnrolled) ?? []).toSet()
      ..remove(key);
    await prefs.setStringList(_kEnrolled, enrolled.toList());
    final pending = (prefs.getStringList(_kPendingBackfill) ?? []).toSet()
      ..remove(key);
    await prefs.setStringList(_kPendingBackfill, pending.toList());
  }

  /// Normalized names of albums with an incomplete "include existing"
  /// backfill.
  Future<Set<String>> pendingBackfills() async {
    final prefs = await _freshPrefs();
    return (prefs.getStringList(_kPendingBackfill) ?? const []).toSet();
  }

  /// Queues backfills for [bucketNames] (the all-albums "include existing
  /// photos" onboarding shortcut).
  Future<void> queueBackfills(Iterable<String> bucketNames) async {
    final prefs = await _freshPrefs();
    final pending = (prefs.getStringList(_kPendingBackfill) ?? []).toSet()
      ..addAll(bucketNames.map(SystemFolders.normalize));
    await prefs.setStringList(_kPendingBackfill, pending.toList());
  }

  /// Marks one album's backfill complete.
  Future<void> clearBackfill(String bucketName) async {
    final prefs = await _freshPrefs();
    final pending = (prefs.getStringList(_kPendingBackfill) ?? []).toSet()
      ..remove(SystemFolders.normalize(bucketName));
    await prefs.setStringList(_kPendingBackfill, pending.toList());
  }
}
