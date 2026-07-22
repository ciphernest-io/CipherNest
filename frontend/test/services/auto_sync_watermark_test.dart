/// The watermark prefix-advance law: the scan watermark may only move past
/// the capture-ordered prefix of outcomes that went cleanly. A failure pins
/// it, so the failed asset stays inside the next scan window — the property
/// that makes an offline-taken photo retryable instead of a permanent ghost.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/auto_sync_service.dart';

typedef O = ({int capturedMs, bool ok});

void main() {
  const windowMax = 10000;
  const current = 100;

  int? advance(List<O> outcomes) =>
      AutoSyncService.computeWatermarkAdvance(outcomes, windowMax, current);

  test('all ok advances to the window max', () {
    expect(
      advance([(capturedMs: 200, ok: true), (capturedMs: 300, ok: true)]),
      windowMax,
    );
  });

  test('empty window (no assets) advances to the window max', () {
    expect(advance([]), windowMax);
  });

  test('first outcome failed: no advance at all', () {
    expect(
      advance([(capturedMs: 200, ok: false), (capturedMs: 300, ok: true)]),
      isNull,
    );
  });

  test('mid failure advances only to the last clean capture before it', () {
    expect(
      advance([
        (capturedMs: 200, ok: true),
        (capturedMs: 300, ok: true),
        (capturedMs: 400, ok: false),
        (capturedMs: 500, ok: true),
      ]),
      300,
    );
  });

  test('duplicates (ok) inside the prefix count toward the advance', () {
    expect(
      advance([
        (capturedMs: 250, ok: true), // duplicate = ok
        (capturedMs: 350, ok: false),
      ]),
      250,
    );
  });

  test('never moves backwards', () {
    // Clean prefix whose capture times are all BEFORE the current watermark
    // (inclusive-min rescan of already-passed assets) must not regress it.
    expect(
      AutoSyncService.computeWatermarkAdvance(
        [(capturedMs: 50, ok: true), (capturedMs: 80, ok: false)],
        windowMax,
        current,
      ),
      isNull,
    );
  });

  test('windowMax below current watermark never regresses (clock skew)', () {
    expect(
      AutoSyncService.computeWatermarkAdvance(
        [(capturedMs: 20, ok: true)],
        50, // windowMax < current watermark
        current,
      ),
      isNull,
    );
  });
}
