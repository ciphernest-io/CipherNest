/// Paywall layout (2026-10-18 device review of build 5): the Plus card has
/// room to breathe but is NOT stretched to the screen, and the CTA spans the
/// card's full inner width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/src/screens/subscription/subscription_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SubscriptionScreen()));
    await tester.pump(const Duration(milliseconds: 100));
  }

  // The card is the decorated Container whose title is the bare word "Plus".
  Rect card(WidgetTester tester) => tester.getRect(find
      .ancestor(of: find.text('Plus'), matching: find.byType(Container))
      .first);

  testWidgets('card is tall but leaves the page unscrolled on a phone',
      (tester) async {
    const size = Size(360, 780);
    await pump(tester, size);
    final c = card(tester);
    expect(c.height, greaterThan(400), reason: 'card height ${c.height}');
    expect(c.bottom, lessThan(size.height - 80),
        reason: 'card must not be stretched to the screen (${c.bottom})');
    // Everything, links included, fits without scrolling.
    final restore = tester.getRect(find.text('Restore purchase'));
    expect(restore.bottom, lessThan(size.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets('CTA spans the card width', (tester) async {
    await pump(tester, const Size(360, 780));
    final c = card(tester);
    // Prices never load in a test (no store), so the CTA reads "Unavailable
    // right now"; it is the only FilledButton on the page either way.
    final cta = tester.getRect(find.byType(FilledButton));
    // 24 padding + 2 border on each side.
    expect(cta.width, closeTo(c.width - 52, 1));
  });

  testWidgets('still scrolls instead of overflowing when short',
      (tester) async {
    await pump(tester, const Size(360, 420));
    expect(tester.takeException(), isNull);
    expect(find.text('Restore purchase'), findsOneWidget);
  });
}
