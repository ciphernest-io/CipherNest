/// The four invariants. These are the product; everything else is
/// negotiable. An invariant failure is a DESIGN bug and gets reported to
/// Usman — never engineered around.
///
///  1. All devices converge to identical state.
///  2. No deleted file or folder ever resurrects — and nothing sits in the
///     bin without a real delete behind it (exact per-item cause, not a
///     global excuse).
///  3. No created file or folder ever vanishes.
///  4. The tree is always a tree: live parent pointers resolve, parent
///     chains are acyclic, no live file is orphaned into a nonexistent
///     folder.
///
/// Oracle soundness: expectations are computed only for DURABLE actions —
/// actions followed by at least one fault-free sync on their device before
/// any reinstall (never-reinstalled devices flush everything during the
/// convergence phase, so all their actions are durable). Actions that died
/// with a wiped device are excluded from "must" sets: the system MAY
/// preserve them (e.g. the blob survived) but is not required to. This
/// under-approximation cannot produce false positives, and still catches
/// every real destruction bug in the durable majority.
library;

import 'sim_model.dart';

class OracleRecord {
  final LocalAction action;
  bool durable = false;

  /// For deletes (file AND folder): whether the target was LIVE on the
  /// acting device when the action was applied. A user can only delete what
  /// their device shows them; a generated delete against an unknown/absent
  /// id is a no-op and must not feed invariant 2 (seed-20 lesson: a blind
  /// delete on a freshly-reinstalled device is not a user intention the
  /// system must honor over the item's continued existence).
  bool effective = true;

  OracleRecord(this.action);
}

List<InvariantViolation> checkInvariants({
  required int seed,
  required List<OracleRecord> history,
  required List<MaterializedState> deviceStates,
}) {
  final violations = <InvariantViolation>[];

  // ---- Invariant 1: convergence ----------------------------------------
  for (var i = 1; i < deviceStates.length; i++) {
    if (deviceStates[i] != deviceStates[0]) {
      violations.add(InvariantViolation(
        1,
        'device[0] and device[$i] differ after convergence:\n'
        '${deviceStates[0].diff(deviceStates[i])}',
      ));
    }
  }

  final durableCreates = <String>{};
  final durableDeletes = <String>{};
  final durablePurges = <String>{}; // terminal: may be absent, never live
  final everRestored = <String>{};
  final durableFolderCreates = <String>{};
  final durableFolderDeletes = <String>{};
  final durableFolderPurges = <String>{};
  final everRestoredFolders = <String>{};
  // ALL-history cause sets (any device, wiped or not): over-approximations
  // used only to excuse, never to require — sound for the bin-cause check.
  final anyDelete = <String>{};
  final anyFolderDeleteTargets = <String>{};
  // Purge excusals for invariant 3 must ALSO be all-history (seed-115
  // lesson): a crashed push can land the segment BEFORE the crash, so a
  // purge op may legitimately propagate even though the oracle never saw a
  // fault-free sync mark it durable (the purging device was reinstalled
  // first). "MAY be absent if any purge was ever attempted; MUST be absent
  // only when the purge is durable" — durablePurges stays the strict set
  // for invariant 2.
  final anyPurge = <String>{};
  final anyFolderPurge = <String>{};

  for (final r in history) {
    switch (r.action.kind) {
      case ActionKind.createFile:
        if (r.durable) durableCreates.add(r.action.targetId);
      case ActionKind.deleteFile:
        anyDelete.add(r.action.targetId);
        if (r.durable && r.effective) durableDeletes.add(r.action.targetId);
      case ActionKind.purgeFile:
        anyPurge.add(r.action.targetId);
        if (r.durable) durablePurges.add(r.action.targetId);
      case ActionKind.restoreFile:
        // Once a file has BOTH deletes and restores, which one wins is
        // legitimately decided by HLC order, which under clock skew may
        // differ from the runner's wall-clock ordering. Asserting either
        // outcome would be unsound — such files are excused from strict
        // invariant 2 and remain covered by convergence (1) and
        // presence (3).
        everRestored.add(r.action.targetId);
      case ActionKind.createFolder:
        if (r.durable) durableFolderCreates.add(r.action.targetId);
      case ActionKind.deleteFolder:
        anyFolderDeleteTargets.add(r.action.targetId);
        if (r.durable && r.effective) {
          durableFolderDeletes.add(r.action.targetId);
        }
      case ActionKind.restoreFolder:
        // Same HLC-order excusal as restoreFile.
        everRestoredFolders.add(r.action.targetId);
      case ActionKind.purgeFolder:
        anyFolderPurge.add(r.action.targetId);
        if (r.durable) durableFolderPurges.add(r.action.targetId);
      default:
        break;
    }
  }
  durableDeletes.removeAll(everRestored);
  durableFolderDeletes.removeAll(everRestoredFolders);

  for (var d = 0; d < deviceStates.length; d++) {
    final s = deviceStates[d];

    // ---- Invariant 2: no resurrection ----------------------------------
    // A durably deleted file must never be LIVE again anywhere. (Binned is
    // fine — soft delete IS the design.)
    for (final id in durableDeletes) {
      if (s.live.containsKey(id)) {
        violations.add(InvariantViolation(
          2,
          'file $id was durably deleted but is LIVE on device[$d] '
          '(${s.live[id]})',
        ));
      }
    }
    // A durably PURGED file is terminal — never live, never binned, gone.
    for (final id in durablePurges) {
      if (s.live.containsKey(id) || s.binned.containsKey(id)) {
        violations.add(InvariantViolation(
          2,
          'file $id was durably purged but reappeared on device[$d]',
        ));
      }
    }
    // Folders, same law.
    for (final id in durableFolderDeletes) {
      if (s.folders.containsKey(id)) {
        violations.add(InvariantViolation(
          2,
          'folder $id was durably deleted but is LIVE on device[$d] '
          '(${s.folders[id]})',
        ));
      }
    }
    for (final id in durableFolderPurges) {
      if (s.folders.containsKey(id) || s.binnedFolders.containsKey(id)) {
        violations.add(InvariantViolation(
          2,
          'folder $id was durably purged but reappeared on device[$d]',
        ));
      }
    }
    // Nothing enters the bin without an EXACT cause. The old check excused
    // every binned file whenever ANY folder delete existed in the run —
    // Model A's explicit cascade cause makes it precise per item.
    for (final e in s.binned.entries) {
      final cause = e.value.deletedByFolder;
      final excused = cause == null
          ? anyDelete.contains(e.key)
          : anyFolderDeleteTargets.contains(cause);
      if (!excused) {
        violations.add(InvariantViolation(
          2,
          'file ${e.key} is in device[$d]\'s recycle bin '
          '(cause=${cause ?? 'individual'}) but no matching delete action '
          'exists in the entire history',
        ));
      }
    }
    for (final e in s.binnedFolders.entries) {
      final cause = e.value.deletedByFolder;
      final excused =
          anyFolderDeleteTargets.contains(cause ?? e.key);
      if (!excused) {
        violations.add(InvariantViolation(
          2,
          'folder ${e.key} is in device[$d]\'s recycle bin '
          '(cause=${cause ?? 'direct'}) but no matching deleteFolder action '
          'exists in the entire history',
        ));
      }
    }

    // ---- Invariant 3: no vanish ----------------------------------------
    // With eternal tombstones (no GC), every durably-created file must be
    // PRESENT (live or binned) on every device — deletion bins it, it is
    // never forgotten. EXCEPT a durably-PURGED file, which is meant to be
    // gone (the 30-day bin sweep). A concurrent folder-vs-create ordering
    // may leave a file live on one device and binned on another, but
    // "present" holds either way, and invariant 1 guarantees the two
    // devices still agree.
    for (final id in durableCreates) {
      // Excused by ANY purge attempt (see anyPurge note above) — a purge op
      // can escape in a crashed push and legitimately erase the file.
      if (anyPurge.contains(id)) continue;
      if (!s.live.containsKey(id) && !s.binned.containsKey(id)) {
        violations.add(InvariantViolation(
          3,
          'file $id was durably created but is ABSENT (not live, not '
          'binned) on device[$d]',
        ));
      }
    }
    // Folders too — Model A makes deleted folders visible (binnedFolders),
    // so folder presence is fully assertable, same law as files.
    for (final id in durableFolderCreates) {
      if (anyFolderPurge.contains(id)) continue;
      if (!s.folders.containsKey(id) && !s.binnedFolders.containsKey(id)) {
        violations.add(InvariantViolation(
          3,
          'folder $id was durably created but is ABSENT (not live, not '
          'binned) on device[$d]',
        ));
      }
    }

    // ---- Invariant 4: the tree is always a tree ------------------------
    // Checked on the LIVE materialized tree (binned entries keep raw
    // pointers by design — the bin shows original context).
    for (final e in s.folders.entries) {
      final parent = e.value.parentId;
      if (parent != null && !s.folders.containsKey(parent)) {
        violations.add(InvariantViolation(
          4,
          'live folder ${e.key} on device[$d] has dangling parent '
          '$parent (not a live folder)',
        ));
      }
    }
    for (final start in s.folders.keys) {
      final seen = <String>{};
      String? cursor = start;
      while (cursor != null) {
        if (!seen.add(cursor)) {
          violations.add(InvariantViolation(
            4,
            'folder parent chain from $start on device[$d] revisits '
            '$cursor — the tree has a cycle',
          ));
          break;
        }
        cursor = s.folders[cursor]?.parentId;
      }
    }
    for (final e in s.live.entries) {
      final folder = e.value.folderId;
      if (folder != null && !s.folders.containsKey(folder)) {
        violations.add(InvariantViolation(
          4,
          'live file ${e.key} on device[$d] is orphaned into $folder '
          '(not a live folder) — it would be invisible in a folder UI',
        ));
      }
    }
  }

  return violations;
}
