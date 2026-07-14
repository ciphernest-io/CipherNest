/// THE HARNESS JUDGING REAL CODE. From here to ship, this must stay green.
///
/// Runs the production op-log core (HLC + total order + deterministic
/// replay from lib/services/sync/) through the full property harness:
/// simulated fleets, crash budgets, partitions, clock skew, horizon-length
/// offline windows, reinstalls. Every seed asserts the three invariants:
/// convergence, no resurrection, no vanish.
///
/// A failure here is a DESIGN bug: reproduce with the printed seed, then
/// report to Usman. Do not weaken this file to get a build green.
library;

import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'oplog_adapter.dart';
import 'scenario.dart';
import 'sim_model.dart';

void main() {
  test('op-log engine: 500 seeds, all invariants, full fault battery',
      () async {
    var totalActions = 0;
    var durableActions = 0;
    for (var seed = 0; seed < 500; seed++) {
      final result = await runScenario(
        generateScenario(seed),
        (deviceId, clock) => OpLogSimEngine(deviceId, clock),
      );
      if (!result.passed) {
        failWithSeed(seed, result.violations);
      }
      totalActions += result.totalActions;
      durableActions += result.durableActions;
    }
    // ignore: avoid_print
    print('op-log engine: 500 seeds green '
        '($durableActions/$totalActions actions durable)');
  });
}
