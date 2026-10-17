/// The phrase screen must lay out without throwing on every phone class.
/// (The type-back stage was removed on 2026-10-06; only one stage remains.)
/// It once shipped blank: a LayoutBuilder (then a shrink-wrapped GridView)
/// sat inside an IntrinsicHeight, and neither can report intrinsic sizes.
library;

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/src/screens/auth/recovery_phrase_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: RecoveryPhraseScreen(mnemonic: bip39.generateMnemonic()),
      ),
    );
    await tester.pump();
  }

  for (final size in const [Size(411, 891), Size(360, 640), Size(320, 533)]) {
    testWidgets('renders at ${size.width}x${size.height}',
        (tester) async {
      await pumpAt(tester, size);
      expect(tester.takeException(), isNull);
      expect(find.text('Your recovery phrase'), findsOneWidget);
      expect(find.text('I have written it down'), findsOneWidget);
      expect(find.text('Have a phrase?'), findsOneWidget);
    });
  }
}
