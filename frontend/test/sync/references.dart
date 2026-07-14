/// Reference engines that validate the HARNESS, not the product.
///
/// The self-test gate (mandated before the harness may judge real code):
///  * [GodReference]  — correct by construction; the harness must report
///    ZERO violations against it, or the checkers are broken (false
///    positives).
///  * [SingleWriterReference] — correct under a writer-only workload,
///    exercising real cloud round-trips; also must produce zero violations.
///  * [LwwStrawman] — faithful model of the pre-Stage-1 CipherNest backup:
///    one snapshot, restore-replaces-local, upload-replaces-cloud. The
///    harness MUST catch its destruction (vanished creates, resurrected
///    deletes), or the harness is blind and worthless.
library;

import 'sim_cloud.dart';
import 'sim_engine.dart';
import 'sim_model.dart';
import 'state_machine.dart';

// ---------------------------------------------------------------------------
// God reference: one shared state, as if replication were instant + perfect.
// ---------------------------------------------------------------------------

class GodShared {
  final StateMachine state = StateMachine();
}

class GodReference implements SimSyncEngine {
  @override
  final String deviceId;
  @override
  final SimTime Function() clock;
  final GodShared shared;

  GodReference(this.deviceId, this.clock, this.shared);

  @override
  void applyLocal(LocalAction action) => shared.state.apply(action);

  @override
  void syncCycle(SimCloud cloud) {} // replication is already perfect

  @override
  void maybeCompact(SimCloud cloud) {}

  @override
  set locked(bool value) {}

  @override
  MaterializedState materialize() => shared.state.snapshot();
}

// ---------------------------------------------------------------------------
// Single-writer reference: device 0 owns the metadata; replicas adopt its
// snapshot. Correct under writer-only workloads.
// ---------------------------------------------------------------------------

class SingleWriterReference implements SimSyncEngine {
  static const String snapshotName = 'sw_snapshot';

  @override
  final String deviceId;
  @override
  final SimTime Function() clock;
  final bool isWriter;
  final StateMachine _local = StateMachine();

  /// A correct single-writer system restores from its own snapshot on a
  /// fresh install BEFORE writing — otherwise a reinstalled writer uploads
  /// an empty state over its own durable history. (Gate C caught exactly
  /// this in the first version of this reference.)
  bool _writerRestored = false;

  SingleWriterReference(this.deviceId, this.clock, {required this.isWriter});

  @override
  void applyLocal(LocalAction action) {
    assert(isWriter, 'single-writer reference got an action on a replica');
    _local.apply(action);
  }

  @override
  void syncCycle(SimCloud cloud) {
    if (isWriter) {
      if (!_writerRestored) {
        final snap = cloud.get(deviceId, snapshotName);
        if (snap is MaterializedState) {
          // Fresh install: merge cloud history under local pending actions.
          // Locally-pending creations/edits were applied to an empty state;
          // layering the snapshot first preserves both.
          final pendingView = _local.snapshot();
          _local.adopt(snap);
          for (final e in pendingView.live.entries) {
            _local.live.putIfAbsent(e.key, () => e.value);
          }
          for (final e in pendingView.binned.entries) {
            _local.live.remove(e.key);
            _local.binned.putIfAbsent(e.key, () => e.value);
          }
          for (final e in pendingView.folders.entries) {
            _local.folders.putIfAbsent(e.key, () => e.value);
          }
        }
        _writerRestored = true;
      }
      cloud.put(deviceId, snapshotName, _local.snapshot(), replace: true);
    } else {
      final snap = cloud.get(deviceId, snapshotName);
      if (snap is MaterializedState) _local.adopt(snap);
    }
  }

  @override
  void maybeCompact(SimCloud cloud) {}

  @override
  set locked(bool value) {}

  @override
  MaterializedState materialize() => _local.snapshot();
}

// ---------------------------------------------------------------------------
// LWW strawman: the pre-Stage-1 model. MUST be caught by the harness.
// ---------------------------------------------------------------------------

class LwwStrawman implements SimSyncEngine {
  static const String snapshotName = 'db_backup.cnest';

  @override
  final String deviceId;
  @override
  final SimTime Function() clock;
  final StateMachine _local = StateMachine();

  /// The old app restored exactly once (at connect) and then only ever
  /// uploaded. Modeling adopt-on-every-sync would be broken even
  /// single-device, which the old app was not — the strawman must be
  /// faithfully, not gratuitously, wrong.
  bool _restoredOnce = false;

  LwwStrawman(this.deviceId, this.clock);

  @override
  void applyLocal(LocalAction action) => _local.apply(action);

  @override
  void syncCycle(SimCloud cloud) {
    if (!_restoredOnce) {
      // Connect-time restore: "replaces your current local index".
      final snap = cloud.get(deviceId, snapshotName);
      if (snap is MaterializedState) _local.adopt(snap);
      _restoredOnce = true;
    }
    // Backup: unconditionally replace the single shared snapshot. Whatever
    // any other device knew and we don't is erased from the cloud.
    cloud.put(deviceId, snapshotName, _local.snapshot(), replace: true);
  }

  @override
  void maybeCompact(SimCloud cloud) {}

  @override
  set locked(bool value) {}

  @override
  MaterializedState materialize() => _local.snapshot();
}
