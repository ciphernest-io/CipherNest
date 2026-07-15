/// The three invariants. These are the product; everything else is
/// negotiable. An invariant failure is a DESIGN bug and gets reported to
/// Usman — never engineered around.
///
///  1. All devices converge to identical state.
///  2. No deleted file ever resurrects.
///  3. No created file ever vanishes.
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

  /// For deletes: whether the target was LIVE on the acting device when the
  /// action was applied. A user can only delete what their device shows
  /// them; a generated delete against an unknown/absent id is a no-op and
  /// must not feed invariant 2 (seed-20 lesson: a blind delete on a
  /// freshly-reinstalled device is not a user intention the system must
  /// honor over the file's continued existence).
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
  var anyFolderDelete = false;
  final anyDelete = <String>{};

  for (final r in history) {
    switch (r.action.kind) {
      case ActionKind.createFile:
        if (r.durable) durableCreates.add(r.action.targetId);
      case ActionKind.deleteFile:
        anyDelete.add(r.action.targetId);
        if (r.durable && r.effective) durableDeletes.add(r.action.targetId);
      case ActionKind.purgeFile:
        if (r.durable) durablePurges.add(r.action.targetId);
      case ActionKind.restoreFile:
        // Once a file has BOTH deletes and restores, which one wins is
        // legitimately decided by HLC order, which under clock skew may
        // differ from the runner's wall-clock ordering. Asserting either
        // outcome would be unsound — such files are excused from strict
        // invariant 2 and remain covered by convergence (1) and
        // presence (3).
        everRestored.add(r.action.targetId);
      case ActionKind.deleteFolder:
        anyFolderDelete = true;
      default:
        break;
    }
  }
  durableDeletes.removeAll(everRestored);

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
    // Nothing enters the bin without a cause.
    for (final id in s.binned.keys) {
      if (!anyDelete.contains(id) && !anyFolderDelete) {
        violations.add(InvariantViolation(
          2,
          'file $id is in device[$d]\'s recycle bin but no delete action of '
          'any kind exists in the entire history',
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
      if (durablePurges.contains(id)) continue; // terminal, meant to be gone
      if (!s.live.containsKey(id) && !s.binned.containsKey(id)) {
        violations.add(InvariantViolation(
          3,
          'file $id was durably created but is ABSENT (not live, not '
          'binned) on device[$d]',
        ));
      }
    }
  }

  return violations;
}
