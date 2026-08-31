/// The pill's visibility state machine at the WIDGET level — the one piece
/// of this feature with no prior art in the codebase (first global overlay).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/activity_center.dart';
import 'package:ciphernest/src/widgets/activity_pill.dart';

Widget _host() => MaterialApp(
      builder: (context, child) => Stack(
        children: [
          const Scaffold(body: SizedBox.expand()),
          const ActivityOverlay(),
        ],
      ),
      home: const SizedBox.shrink(),
    );

void main() {
  final center = ActivityCenter();

  setUp(center.debugReset);

  testWidgets('hidden at rest -> active on start -> +N chip -> terminal '
      'flash -> gone after 4s', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.byType(ActivityOverlay), findsOneWidget);
    expect(find.textContaining('Encrypting'), findsNothing);

    final a = center.start(
        kind: ActivityKind.upload, label: 'Encrypting 0/3…', total: 3);
    await tester.pump();
    expect(find.text('Encrypting 0/3…'), findsOneWidget);

    final b = center.start(kind: ActivityKind.export, label: 'Decrypting…');
    await tester.pump();
    expect(find.text('+1'), findsOneWidget,
        reason: 'upload outranks export, so it fronts with a +1 chip');

    b.complete('B done');
    await tester.pump();
    expect(find.text('B done'), findsNothing,
        reason: 'mid-batch completion folds into recent, no flash');

    a.complete('3 files secured');
    await tester.pump();
    expect(find.text('3 files secured'), findsOneWidget,
        reason: 'LAST task terminal flashes its summary');

    await tester.pump(ActivityCenter.terminalDisplay);
    await tester.pump();
    expect(find.text('3 files secured'), findsNothing);
  });

  testWidgets('swipe-suppress hides; next start re-reveals', (tester) async {
    await tester.pumpWidget(_host());
    center.start(kind: ActivityKind.upload, label: 'Working…');
    await tester.pump();
    expect(find.text('Working…'), findsOneWidget);

    center.suppressPill();
    await tester.pump();
    expect(find.text('Working…'), findsNothing);

    center.start(kind: ActivityKind.export, label: 'More work…');
    await tester.pump();
    // Re-revealed — and the pill fronts the higher-priority ORIGINAL task,
    // with the newcomer in the +N count.
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);

    // Drain the auto-minimize hold timer (tasks are still running).
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('quiet tasks never render the pill', (tester) async {
    await tester.pumpWidget(_host());
    center.start(
        kind: ActivityKind.sweep,
        label: 'Cleaning…',
        visibility: ActivityVisibility.quiet);
    await tester.pump();
    expect(find.text('Cleaning…'), findsNothing);
  });

  testWidgets('top-anchored: pill sits below a standard AppBar; a top '
      'claim pushes it further down', (tester) async {
    await tester.pumpWidget(_host());
    center.start(kind: ActivityKind.upload, label: 'Working…');
    await tester.pump();
    final unclaimed = tester.getTopLeft(find.text('Working…')).dy;
    expect(unclaimed, greaterThanOrEqualTo(kToolbarHeight),
        reason: 'the pill must never overlap a plain AppBar');

    final claim = ActivityPillInset.claim(48);
    addTearDown(claim.release);
    await tester.pump();
    final claimed = tester.getTopLeft(find.text('Working…')).dy;
    expect(claimed, greaterThanOrEqualTo(unclaimed + 48),
        reason: 'a TabBar/selection-bar claim must push the pill below it');

    // Drain the auto-minimize hold timer (the task is still running).
    await tester.pump(const Duration(seconds: 5));
  });
}
