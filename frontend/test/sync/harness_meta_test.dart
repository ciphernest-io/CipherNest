/// THE HARNESS SELF-TEST GATE.
///
/// A harness that passes everything because it is blind is worse than no
/// harness. Before it may judge any real sync code it must prove, in both
/// directions, that it can see:
///
///  * GATE A (sensitivity): against a faithful model of the pre-Stage-1
///    LWW snapshot backup, the harness MUST catch destruction — vanished
///    creates (invariant 3) and resurrected deletes (invariant 2) — in a
///    substantial fraction of multi-writer scenarios.
///  * GATE B (specificity): against a correct-by-construction perfect-sync
///    reference, ZERO violations across hundreds of seeds.
///  * GATE C (specificity, with real cloud round-trips): against a
///    single-writer reference under writer-only workloads, ZERO violations.
///
/// Gate results are reported to Usman before any production engine is
/// evaluated. If a reference gate fails, the HARNESS is wrong, and fixing
/// it precedes everything else.
library;

import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'references.dart';
import 'scenario.dart';
import 'sim_cloud.dart';
import 'sim_model.dart';

void main() {
  group('GATE A — sensitivity: the harness catches the old LWW model', () {
    test('destruction is detected across seeds, in both flavors', () {
      const seeds = 200;
      var caught = 0;
      var vanishSeeds = 0;
      var resurrectSeeds = 0;
      var multiWriterSeeds = 0;

      for (var seed = 0; seed < seeds; seed++) {
        final scenario = generateScenario(seed);
        final result = runScenario(
          scenario,
          (deviceId, clock) => LwwStrawman(deviceId, clock),
        );
        // Only multi-writer scenarios are expected to destroy — a single
        // active writer was the old model's (accidental) safe case.
        final writers = scenario.events
            .whereType<ActionEvent>()
            .map((e) => e.action.deviceIndex)
            .toSet();
        if (writers.length > 1) multiWriterSeeds++;

        if (!result.passed) {
          caught++;
          if (result.violations.any((v) => v.invariant == 3)) vanishSeeds++;
          if (result.violations.any((v) => v.invariant == 2)) {
            resurrectSeeds++;
          }
        }
      }

      // Report for the gate record.
      // ignore: avoid_print
      print('GATE A: $caught/$seeds seeds caught '
          '($multiWriterSeeds multi-writer; '
          'vanish in $vanishSeeds, resurrection in $resurrectSeeds)');

      // The strawman must be caught in at least half of ALL seeds (nearly
      // every multi-writer interleaving destroys something), and both
      // destruction flavors must be independently demonstrated.
      expect(caught, greaterThanOrEqualTo(seeds ~/ 2),
          reason: 'harness failed to catch the known-destructive LWW model '
              'often enough — it is too blind to be trusted');
      expect(vanishSeeds, greaterThan(10),
          reason: 'invariant 3 (vanish) checker never fires on a model that '
              'demonstrably vanishes files');
      expect(resurrectSeeds, greaterThan(10),
          reason: 'invariant 2 (resurrection) checker never fires on a model '
              'that demonstrably resurrects deletes');
    });
  });

  group('GATE B — specificity: perfect-sync reference is never flagged', () {
    test('zero violations across 300 seeds', () {
      for (var seed = 0; seed < 300; seed++) {
        final shared = GodShared();
        final result = runScenario(
          generateScenario(seed),
          (deviceId, clock) => GodReference(deviceId, clock, shared),
        );
        if (!result.passed) {
          failWithSeed(seed, result.violations);
        }
      }
    });
  });

  group('GATE C — specificity: single-writer reference, writer-only load',
      () {
    test('zero violations across 300 seeds', () {
      for (var seed = 0; seed < 300; seed++) {
        final result = runScenario(
          generateScenario(seed, writerOnlyActions: true),
          (deviceId, clock) => SingleWriterReference(
            deviceId,
            clock,
            isWriter: deviceId.startsWith('dev0-'),
          ),
        );
        if (!result.passed) {
          failWithSeed(seed, result.violations);
        }
      }
    });
  });

  group('harness mechanics', () {
    test('scenarios are deterministic per seed', () {
      for (final seed in [1, 7, 42, 1337]) {
        final a = generateScenario(seed);
        final b = generateScenario(seed);
        expect(a.deviceCount, b.deviceCount);
        expect(a.clockSkewsMs, b.clockSkewsMs);
        expect(a.events.length, b.events.length);
        for (var i = 0; i < a.events.length; i++) {
          expect(a.events[i].runtimeType, b.events[i].runtimeType,
              reason: 'event $i diverged for seed $seed');
        }
      }
    });

    test('runs are deterministic per seed (same violations, same stats)',
        () {
      for (final seed in [3, 11, 99]) {
        HarnessResult run() => runScenario(
              generateScenario(seed),
              (deviceId, clock) => LwwStrawman(deviceId, clock),
            );
        final a = run();
        final b = run();
        expect(a.passed, b.passed);
        expect(a.violations.map((v) => v.toString()).toList(),
            b.violations.map((v) => v.toString()).toList());
        expect(a.durableActions, b.durableActions);
      }
    });

    test('crash budget interrupts and offline blocks', () {
      final cloud = SimCloud();
      cloud.setCrashBudget('d', 2);
      cloud.put('d', 'a', 1);
      cloud.get('d', 'a');
      expect(() => cloud.get('d', 'a'), throwsA(isA<SimCrash>()));
      // Budget consumed by the crash; next call is fine again.
      cloud.get('d', 'a');

      cloud.setOffline('d', true);
      expect(() => cloud.get('d', 'a'), throwsA(isA<SimOffline>()));
      cloud.setOffline('d', false);
      expect(cloud.get('d', 'a'), 1);
    });

    test('append-only discipline is enforced', () {
      final cloud = SimCloud();
      cloud.put('d', 'seg1', 'x');
      expect(() => cloud.put('d', 'seg1', 'y'), throwsA(isA<StateError>()));
      cloud.put('d', 'seg1', 'y', replace: true); // explicit replace only
    });

    test('scenarios exercise every fault type across the seed range', () {
      var partitions = 0, jumps = 0, reinstalls = 0, compactions = 0;
      var crashes = 0, locks = 0, horizonJumps = 0, wrongClock = 0;
      for (var seed = 0; seed < 300; seed++) {
        final s = generateScenario(seed);
        if (s.clockSkewsMs.any((ms) => ms.abs() > msPerDay)) wrongClock++;
        for (final e in s.events) {
          switch (e) {
            case PartitionEvent():
              partitions++;
            case TimeJumpEvent(:final days):
              jumps++;
              if (days >= 180) horizonJumps++;
            case ReinstallEvent():
              reinstalls++;
            case CompactEvent():
              compactions++;
            case SyncEvent(:final crashBudget):
              if (crashBudget != null) crashes++;
            case LockEvent():
              locks++;
            default:
              break;
          }
        }
      }
      expect(partitions, greaterThan(50));
      expect(jumps, greaterThan(30));
      expect(horizonJumps, greaterThan(3),
          reason: 'offline-past-tombstone-horizon must be exercised');
      expect(reinstalls, greaterThan(10));
      expect(compactions, greaterThan(20));
      expect(crashes, greaterThan(50));
      expect(locks, greaterThan(5));
      expect(wrongClock, greaterThan(30),
          reason: 'persistently-wrong-clock devices must be generated');
    });
  });
}
