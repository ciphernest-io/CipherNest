/// Pill state machine + task lifecycle for the ActivityCenter — the single
/// source of truth the global overlay renders. Timers driven by fakeAsync.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/activity_center.dart';
import 'package:ciphernest/services/notify.dart';

void main() {
  final center = ActivityCenter();

  setUp(() {
    center.debugReset();
    ToastController().debugReset();
  });

  test('start -> active pill; update -> fraction; complete -> terminal '
      'flash then hidden', () {
    fakeAsync((async) {
      expect(center.pillMode, PillMode.hidden);
      final task = center.start(
          kind: ActivityKind.upload, label: 'Encrypting 0/4…', total: 4);
      expect(center.pillMode, PillMode.active);
      expect(center.pillTask, same(task));

      task.update(2, label: 'Encrypting 2/4…');
      expect(task.fraction, 0.5);

      task.complete('4 files secured');
      expect(center.running, isEmpty);
      expect(center.recent.single, same(task));
      expect(center.pillMode, PillMode.terminal);
      expect(center.pillTask!.resultMessage, '4 files secured');

      async.elapse(ActivityCenter.terminalDisplay);
      expect(center.pillMode, PillMode.hidden);
    });
  });

  test('priority: pill fronts the lowest enum index; +N counts the rest',
      () {
    fakeAsync((async) {
      final up = center.start(
          kind: ActivityKind.upload, label: 'Encrypting…', total: 3);
      final mig = center.start(
          kind: ActivityKind.migration, label: 'Migrating…', total: 100);
      expect(center.pillTask, same(mig));
      expect(center.extraRunningCount, 1);
      mig.complete();
      expect(center.pillTask, same(up));
      expect(center.extraRunningCount, 0);
    });
  });

  test('terminal flash ONLY when the last normal task ends', () {
    fakeAsync((async) {
      final a =
          center.start(kind: ActivityKind.upload, label: 'A', total: 1);
      final b =
          center.start(kind: ActivityKind.export, label: 'B', total: 1);
      a.complete('A done');
      expect(center.pillMode, PillMode.active,
          reason: 'B still runs — A folds straight into recent');
      expect(center.recent.single.resultMessage, 'A done');
      b.complete('B done');
      expect(center.pillMode, PillMode.terminal);
      expect(center.pillTask!.resultMessage, 'B done');
    });
  });

  test('recent caps at 10, newest first; discard never enters recent', () {
    fakeAsync((async) {
      for (var i = 0; i < 12; i++) {
        center
            .start(kind: ActivityKind.binOp, label: 'op $i')
            .complete('done $i');
      }
      expect(center.recent.length, 10);
      expect(center.recent.first.resultMessage, 'done 11');

      final d = center.start(kind: ActivityKind.export, label: 'never');
      d.discard();
      expect(center.running, isEmpty);
      expect(center.recent.any((t) => t.label == 'never'), isFalse);
    });
  });

  test('quiet tasks never touch the pill; quiet failure fires an error '
      'toast', () {
    fakeAsync((async) {
      final sweep = center.start(
          kind: ActivityKind.sweep,
          label: 'Cleaning up…',
          visibility: ActivityVisibility.quiet);
      expect(center.pillMode, PillMode.hidden);
      expect(center.running.single, same(sweep));

      sweep.fail('Cleanup failed');
      expect(center.pillMode, PillMode.hidden,
          reason: 'no terminal flash for quiet tasks');
      expect(ToastController().current?.message, 'Cleanup failed');
      expect(ToastController().current?.isError, isTrue);
    });
  });

  test('swipe suppression hides the pill; next start OR the terminal event '
      're-reveals', () {
    fakeAsync((async) {
      final a = center.start(kind: ActivityKind.upload, label: 'A');
      center.suppressPill();
      expect(center.pillMode, PillMode.hidden);

      center.start(kind: ActivityKind.export, label: 'B');
      expect(center.pillMode, PillMode.active,
          reason: 'new work re-reveals');

      center.suppressPill();
      a.complete('A done');
      expect(center.pillMode, PillMode.hidden,
          reason: 'a sibling finishing mid-batch respects the swipe-away; '
              'only new work or the LAST task\'s terminal re-reveals');
    });
  });

  test('suppressed pill still shows the LAST task\'s terminal flash', () {
    fakeAsync((async) {
      final a = center.start(kind: ActivityKind.upload, label: 'A');
      center.suppressPill();
      a.complete('A done');
      expect(center.pillMode, PillMode.terminal);
    });
  });

  test('sheet open hides the pill; start during terminal cancels the timer',
      () {
    fakeAsync((async) {
      final a = center.start(kind: ActivityKind.upload, label: 'A');
      center.setSheetOpen(true);
      expect(center.pillMode, PillMode.hidden);
      center.setSheetOpen(false);

      a.complete('A done');
      expect(center.pillMode, PillMode.terminal);
      center.start(kind: ActivityKind.export, label: 'B');
      expect(center.pillMode, PillMode.active,
          reason: 'terminal preempted by new work');
      async.elapse(ActivityCenter.terminalDisplay);
      expect(center.pillMode, PillMode.active,
          reason: 'the cancelled timer must not hide the active pill');
    });
  });

  test('terminal mutation guards: update/complete after finish are no-ops',
      () {
    fakeAsync((async) {
      final a =
          center.start(kind: ActivityKind.upload, label: 'A', total: 2);
      a.complete('done');
      a.update(9, label: 'zombie');
      a.fail('zombie');
      expect(a.label, 'A');
      expect(a.state, ActivityState.success);
      expect(a.resultMessage, 'done');
    });
  });
}
