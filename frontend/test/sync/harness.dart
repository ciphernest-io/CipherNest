/// The runner: executes a scenario against an engine implementation,
/// drives the convergence phase, and returns invariant violations.
library;

import 'invariants.dart';
import 'scenario.dart';
import 'sim_cloud.dart';
import 'sim_engine.dart';
import 'sim_model.dart';

class HarnessResult {
  final int seed;
  final List<InvariantViolation> violations;
  final int durableActions;
  final int totalActions;

  const HarnessResult({
    required this.seed,
    required this.violations,
    required this.durableActions,
    required this.totalActions,
  });

  bool get passed => violations.isEmpty;
}

HarnessResult runScenario(Scenario scenario, EngineFactory factory) {
  final cloud = SimCloud();
  var globalNow = 0;
  cloud.now = 0;

  final devices = List<DeviceSim>.generate(
    scenario.deviceCount,
    (i) => DeviceSim(
      index: i,
      factory: factory,
      clockSkewMs: scenario.clockSkewsMs[i],
      globalNow: () => globalNow,
    ),
  );

  final history = <OracleRecord>[];
  // Actions applied on a device's CURRENT install that no fault-free sync
  // has flushed yet. Reinstall discards these (legitimately lost); a
  // successful sync marks them durable.
  final pending = List<List<OracleRecord>>.generate(
      scenario.deviceCount, (_) => []);

  void trySync(DeviceSim d, {int? crashBudget}) {
    cloud.setCrashBudget(d.deviceId, crashBudget);
    try {
      d.engine.syncCycle(cloud);
      // Fault-free completion: everything applied so far on this install
      // is now durable.
      for (final r in pending[d.index]) {
        r.durable = true;
      }
      pending[d.index].clear();
    } on SimCrash {
      // Process died mid-sync; pending stays pending. The engine must
      // recover on a later cycle.
    } on SimOffline {
      // No connectivity; same story.
    } finally {
      cloud.setCrashBudget(d.deviceId, null);
    }
  }

  for (final event in scenario.events) {
    switch (event) {
      case ActionEvent(:final action):
        globalNow = action.at;
        cloud.now = globalNow;
        final record = OracleRecord(action);
        if (action.kind == ActionKind.deleteFile) {
          // A delete only expresses user intent if the file was visible on
          // that device at that moment (see OracleRecord.effective).
          record.effective = devices[action.deviceIndex]
              .engine
              .materialize()
              .live
              .containsKey(action.targetId);
        }
        history.add(record);
        pending[action.deviceIndex].add(record);
        devices[action.deviceIndex].engine.applyLocal(action);
      case SyncEvent(:final deviceIndex, :final crashBudget):
        trySync(devices[deviceIndex], crashBudget: crashBudget);
      case PartitionEvent(:final deviceIndex, :final offline):
        cloud.setOffline(devices[deviceIndex].deviceId, offline);
      case TimeJumpEvent(:final days):
        globalNow += days * msPerDay;
        cloud.now = globalNow;
      case ReinstallEvent(:final deviceIndex):
        final d = devices[deviceIndex];
        cloud.setOffline(d.deviceId, false);
        // Never-uploaded actions die with the install — the oracle knows.
        pending[deviceIndex].clear();
        d.reinstall();
      case CompactEvent(:final deviceIndex):
        final d = devices[deviceIndex];
        try {
          d.engine.maybeCompact(cloud);
        } on SimCrash {
          // tolerated
        } on SimOffline {
          // tolerated
        }
      case LockEvent(:final deviceIndex, :final locked):
        devices[deviceIndex].engine.locked = locked;
    }
  }

  // ---- Convergence phase: everyone online, unlocked, fault-free -----------
  for (final d in devices) {
    cloud.setOffline(d.deviceId, false);
    d.engine.locked = false;
  }
  const maxRounds = 12;
  List<MaterializedState>? previous;
  var quiesced = false;
  for (var round = 0; round < maxRounds; round++) {
    for (final d in devices) {
      trySync(d);
    }
    final states = devices.map((d) => d.engine.materialize()).toList();
    if (previous != null &&
        List.generate(states.length, (i) => states[i] == previous![i])
            .every((same) => same)) {
      quiesced = true;
      break;
    }
    previous = states;
  }

  final states = devices.map((d) => d.engine.materialize()).toList();
  final violations = <InvariantViolation>[
    if (!quiesced)
      InvariantViolation(
          1,
          'no quiescence after $maxRounds fault-free rounds — '
          'the system does not converge'),
    ...checkInvariants(
      seed: scenario.seed,
      history: history,
      deviceStates: states,
    ),
  ];

  return HarnessResult(
    seed: scenario.seed,
    violations: violations,
    durableActions: history.where((r) => r.durable).length,
    totalActions: history.length,
  );
}
