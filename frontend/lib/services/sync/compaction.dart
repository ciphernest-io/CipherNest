/// Compaction policy: VERBATIM consolidation, no garbage collection.
///
/// Compaction folds many old log objects into one snapshot to bound the
/// cloud OBJECT count. It never drops ops, so replay(snapshot) is exactly
/// replay(the folded segments) — provably convergent, with zero dependence
/// on any per-device clock.
///
/// Why no op-GC: dropping tombstones past a "retention horizon" cannot
/// converge under clock skew. GC eligibility would depend on each device's
/// notion of "now" (its own or the newest wall time it has seen), so
/// partitioned devices disagree on what is collectable; once one device GCs
/// a file's ops and deletes the source segments, a peer that still holds
/// part of that file's history diverges permanently. (The property harness
/// caught exactly this — a 249-day-skewed device made one file GC-eligible
/// on some devices and not others.) Eternal tombstones are also strictly
/// SAFER: a straggler create can never outlive its tombstone, so a deleted
/// file can never resurrect. Ops are ~100 bytes; the object count is bounded
/// by folding. A convergent GC scheme can be designed later if log size ever
/// becomes a real constraint.
library;

import 'sync_op.dart';

class Compaction {
  Compaction._();

  /// Objects younger than this (by PROVIDER upload time — its only role) are
  /// never folded: recently-arrived objects may not have reached every
  /// device's listing yet.
  static const int foldableAgeMs = 30 * 24 * 60 * 60 * 1000;

  /// Minimum foldable objects before compaction is worth a snapshot.
  static const int minFoldable = 2;

  /// The ops a snapshot carries: the folded ops, deduped by key, verbatim.
  /// No summarization, no GC — that is what makes folding convergent.
  static List<SyncOp> snapshotOps(List<SyncOp> ops) {
    final byKey = <String, SyncOp>{};
    for (final op in ops) {
      byKey.putIfAbsent(op.opKey, () => op);
    }
    return byKey.values.toList();
  }
}
