/// Wire protocol between the background sync worker isolate and the UI
/// isolate's ActivityCenter: primitive-list round trips, tolerance for
/// malformed payloads, and the away-summary pref encoding.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/bg_activity_bridge.dart';

void main() {
  test('messages round-trip through encode/decode', () {
    final scanning = BgSyncMessage.decode(BgSyncMessage.scanning())!;
    expect(scanning.type, BgSyncMessage.typeScanning);

    final progress = BgSyncMessage.decode(BgSyncMessage.progress(3, 10))!;
    expect(progress.type, BgSyncMessage.typeProgress);
    expect(progress.a, 3);
    expect(progress.b, 10);

    final terminal = BgSyncMessage.decode(BgSyncMessage.terminal(7, 1))!;
    expect(terminal.type, BgSyncMessage.typeTerminal);
    expect(terminal.a, 7);
    expect(terminal.b, 1);
  });

  test('malformed payloads decode to null, never throw', () {
    expect(BgSyncMessage.decode(null), isNull);
    expect(BgSyncMessage.decode('nonsense'), isNull);
    expect(BgSyncMessage.decode(const <int>[]), isNull);
    expect(BgSyncMessage.decode(const [99]), isNull,
        reason: 'unknown type from a version-skewed worker');
    expect(BgSyncMessage.decode(const [BgSyncMessage.typeProgress]), isNull,
        reason: 'progress without its operands');
    expect(BgSyncMessage.decode(const ['a', 'b', 'c']), isNull);
  });

  test('away-summary pref encoding round-trips; garbage decodes null', () {
    final raw = encodeBgSummary(12, 2, 1754900000000);
    final decoded = decodeBgSummary(raw)!;
    expect(decoded.synced, 12);
    expect(decoded.failed, 2);
    expect(decoded.epochMs, 1754900000000);

    expect(decodeBgSummary(''), isNull);
    expect(decodeBgSummary('1|2'), isNull);
    expect(decodeBgSummary('a|b|c'), isNull);
  });
}
