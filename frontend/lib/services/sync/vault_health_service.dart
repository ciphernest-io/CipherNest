import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../cloud/cloud_service.dart';
import '../database_service.dart';
import 'op_replay.dart';
import 'sync_op.dart';

/// Pref key: unreadable segments from the last pull (written by SyncEngine).
const String kUnreadableSegmentsPref = 'sync_unreadable_segments_v1';

/// Pref key + threshold: a device clock looked far off at the last pull.
const String kClockSkewPref = 'sync_clock_skew_v1';
const int kClockSkewThresholdMs = 24 * 60 * 60 * 1000;

/// A snapshot of vault integrity for the Settings "Vault Health" surface.
class VaultHealthReport {
  /// Cloud blobs in vault/ that NO sync op references — data the app can no
  /// longer see. Never auto-deleted; the user chooses recover or forget.
  final List<String> orphanBlobIds;

  /// Files the log knows about whose cloud blob is missing — potential data
  /// loss to warn about (a blob deleted out-of-band in the cloud UI).
  final List<String> missingBlobFileIds;

  /// Sync segments that failed to decrypt on the last pull (corrupt or
  /// foreign). Surfaced, retried each cycle, never silently absorbed.
  final int unreadableSegments;

  /// A device's clock looked far off at the last pull (advisory only).
  final bool clockSkewDetected;

  const VaultHealthReport({
    required this.orphanBlobIds,
    required this.missingBlobFileIds,
    required this.unreadableSegments,
    required this.clockSkewDetected,
  });

  bool get isHealthy =>
      orphanBlobIds.isEmpty &&
      missingBlobFileIds.isEmpty &&
      unreadableSegments == 0 &&
      !clockSkewDetected;
}

/// Diffs the cloud vault against the op-log's known file set.
///
/// The op-log is the source of truth for "what files should exist". A blob
/// with no op is an ORPHAN (recoverable, never auto-deleted — we never
/// silently remove user data, even data nothing references). A referenced
/// file with no blob is MISSING (a warning; the blob may have been deleted
/// in the provider's web UI).
class VaultHealthService {
  static final VaultHealthService _instance = VaultHealthService._();
  factory VaultHealthService() => _instance;
  VaultHealthService._();

  final ValueNotifier<VaultHealthReport?> lastReport = ValueNotifier(null);

  Future<VaultHealthReport> scan({required String accountId}) async {
    // 1. Cloud vault blob stems (uuid before .cnest; skip thumbs).
    final cloudFiles = await CloudService().listCloudFiles();
    final blobStems = <String>{};
    for (final f in cloudFiles) {
      final name = f['name'] as String? ?? '';
      if (!name.endsWith('.cnest')) continue;
      if (name.endsWith('_thumb.cnest')) continue;
      blobStems.add(name.substring(0, name.length - '.cnest'.length));
    }

    // 2. Files the op-log says should exist (live or binned; purged files
    //    are already gone from replay state).
    final db = await DatabaseService().database;
    final opRows = await db.query('sync_ops',
        where: 'account_id = ?', whereArgs: [accountId]);
    final known = replayOps(opRows.map(_rowToOp)).files.keys.toSet();

    // Rows without ops (pre-sync legacy / recoveries) also legitimately
    // reference blobs — a blob backing such a row is NOT an orphan.
    final rowIds = (await db.query('files',
            columns: ['id'], where: 'account_id = ?', whereArgs: [accountId]))
        .map((r) => r['id'] as String)
        .toSet();
    final referenced = {...known, ...rowIds};

    final orphans = blobStems.difference(referenced).toList()..sort();
    final missing = known.difference(blobStems).toList()..sort();

    final prefs = await SharedPreferences.getInstance();
    final report = VaultHealthReport(
      orphanBlobIds: orphans,
      missingBlobFileIds: missing,
      unreadableSegments: prefs.getInt(kUnreadableSegmentsPref) ?? 0,
      clockSkewDetected: prefs.getBool(kClockSkewPref) ?? false,
    );
    lastReport.value = report;
    return report;
  }

  /// Permanently removes an orphan blob (and its thumb, if any). Requires
  /// explicit user confirmation upstream — we never auto-delete user data.
  Future<void> forgetOrphan(String stem) async {
    final cloudFiles = await CloudService().listCloudFiles();
    for (final f in cloudFiles) {
      final name = f['name'] as String? ?? '';
      if (name == '$stem.cnest' || name == '${stem}_thumb.cnest') {
        final id = f['id'] as String?;
        if (id != null) {
          try {
            await CloudService().deleteFile(id);
          } catch (_) {}
        }
      }
    }
  }

  SyncOp _rowToOp(Map<String, Object?> row) => SyncOp.fromJson({
        'k': row['kind'],
        'd': row['device_id'],
        's': row['seq'],
        'h': {'w': row['hlc_wall'], 'c': row['hlc_counter']},
        't': row['target_id'],
        'n': row['name'],
        'f': row['folder_id'],
        'v': row['favorite'] == null ? null : (row['favorite'] as int) == 1,
      });
}
