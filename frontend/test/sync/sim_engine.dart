/// The contract the production sync engine must satisfy to be judged by
/// this harness (via a thin adapter, written in Stage 2d). Reference
/// implementations in this directory validate the harness itself.
library;

import 'sim_cloud.dart';
import 'sim_model.dart';

/// One device's view of the sync system.
///
/// Contract the harness enforces:
///  * [applyLocal] must always succeed and be durable on-device (it models
///    a user action already persisted locally; process crashes never lose
///    it — only [reinstall] wipes it).
///  * [syncCycle] may be interrupted at ANY point by [SimCrash]/[SimOffline]
///    (the harness sets budgets/partitions). The engine must tolerate
///    resuming later with no corruption and no loss of pending actions.
///  * [materialize] returns the user-visible state derived from local data
///    only (no cloud access) — production-wise: what SQLite shows.
abstract class SimSyncEngine {
  String get deviceId;

  /// Device clock (skewed). Engines must not consult any other time source.
  SimTime Function() get clock;

  void applyLocal(LocalAction action);

  /// Push pending local changes and pull others'. Throws SimCrash/SimOffline
  /// when the harness injects faults; the harness swallows those.
  void syncCycle(SimCloud cloud);

  /// Opportunity to compact (harness invokes to simulate concurrent
  /// compaction). Same fault rules as syncCycle. Default: nothing.
  void maybeCompact(SimCloud cloud) {}

  /// Encrypt-locked mode: while locked, the engine may append create-type
  /// ops but must not need decrypt capability. References ignore this;
  /// the production adapter (Stage 2c+) must honor it.
  set locked(bool value) {}

  MaterializedState materialize();
}

/// Factory so the runner can rebuild an engine after [DeviceSim.reinstall].
typedef EngineFactory = SimSyncEngine Function(
    String deviceId, SimTime Function() clock);

/// Harness-side wrapper: owns identity, clock skew, and reinstall.
class DeviceSim {
  final int index;
  final EngineFactory _factory;

  /// Constant clock offset (ms, either sign). The "persistently wrong
  /// clock" device is just a very large offset.
  final int clockSkewMs;

  final SimTime Function() _globalNow;

  String deviceId;
  late SimSyncEngine engine;
  int _generation = 0;

  DeviceSim({
    required this.index,
    required EngineFactory factory,
    required this.clockSkewMs,
    required SimTime Function() globalNow,
  })  : _factory = factory,
        _globalNow = globalNow,
        deviceId = 'dev$index-g0' {
    engine = _factory(deviceId, () => _globalNow() + clockSkewMs);
  }

  /// Wipe + fresh identity; old cloud segments remain as history. Pending
  /// (never-uploaded) local actions are legitimately lost — the oracle
  /// accounts for that.
  void reinstall() {
    _generation++;
    deviceId = 'dev$index-g$_generation';
    engine = _factory(deviceId, () => _globalNow() + clockSkewMs);
  }
}
