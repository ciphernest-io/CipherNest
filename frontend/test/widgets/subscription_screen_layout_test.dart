/// Paywall layout (2026-10-18 device review of build 5): the Plus card
/// fills the phone instead of leaving the lower half of the screen empty,
/// and the CTA spans the card's full inner width.
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

  // The card is the one Expanded child of the page column; its title is the
  // bare word "Plus".
  Rect card(WidgetTester tester) => tester.getRect(find
      .ancestor(of: find.text('Plus'), matching: find.byType(Expanded))
      .first);

  testWidgets('card reaches the bottom of a phone screen', (tester) async {
    const size = Size(360, 780);
    await pump(tester, size);
    final c = card(tester);
    // Below the card: 16 gap, two text links, 24 bottom padding. Whatever is
    // left belongs to the card, so its bottom lands in the last fifth.
    expect(c.bottom, greaterThan(size.height * 0.8),
        reason: 'card bottom ${c.bottom} of ${size.height}');
    expect(c.height, greaterThan(size.height * 0.5));
  });

  testWidgets('CTA spans the card width', (tester) async {
    await pump(tester, const Size(360, 780));
    final c = card(tester);
    // Prices never load in a test (no store), so the CTA reads "Unavailable
    // right now"; it is the only FilledButton on the page either way.
    final cta = tester.getRect(find.byType(FilledButton));
    // 20 padding + 2 border on each side.
    expect(cta.width, closeTo(c.width - 44, 1));
  });

  testWidgets('still scrolls instead of overflowing when short', (tester) async {
    await pump(tester, const Size(360, 420));
    expect(tester.takeException(), isNull);
    expect(find.text('Restore purchase'), findsOneWidget);
  });
}
