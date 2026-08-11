import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/src/utils/bulk_ops.dart';

void main() {
  test('returns REAL successes, keeps going past failures, ticks onEach',
      () async {
    final ticks = <int>[];
    final ok = await honestCount<int>(
      [1, 2, 3, 4, 5],
      (n) async {
        if (n.isEven) throw StateError('boom');
      },
      onEach: ticks.add,
    );
    expect(ok, 3, reason: 'odd items succeed, even ones fail');
    expect(ticks, [1, 2, 3, 4, 5],
        reason: 'every item ticks, failed or not');
  });

  test('empty input -> zero, no ticks', () async {
    expect(await honestCount<int>(const [], (_) async {}), 0);
  });
}
