import 'dart:math';

import 'package:flutter/foundation.dart';

import 'cnest_errors.dart';

/// Retry policy for one cloud write (a blob, a thumbnail, the vault index).
///
/// Drive enforces a per-user create rate; two creates per photo across a
/// thousand-photo import trips it reliably, and the device walkthrough on
/// 20 Oct 2026 lost a third of an import to exactly that. Each attempt is
/// retried only for errors [isTransientCloudError] recognises, with
/// exponential backoff plus jitter so a batch does not hammer the provider
/// in lockstep. Anything else propagates on the first attempt.
///
/// [attempt] must be a FACTORY: a byte upload can be replayed as is, but a
/// streamed upload has to reopen its source, so the caller rebuilds the
/// stream inside the closure.
Future<T> retryTransientUpload<T>(
  Future<T> Function() attempt, {
  int maxAttempts = 4,
  Duration baseDelay = const Duration(seconds: 1),
  Future<void> Function(Duration)? sleep,
}) async {
  final rng = Random();
  var n = 0;
  while (true) {
    n++;
    try {
      return await attempt();
    } catch (e) {
      if (n >= maxAttempts || !isTransientCloudError(e)) rethrow;
      final backoff = baseDelay * (1 << (n - 1)) +
          Duration(milliseconds: rng.nextInt(500));
      debugPrint('Cloud write attempt $n failed, retrying in '
          '${backoff.inMilliseconds} ms');
      await (sleep ?? Future<void>.delayed)(backoff);
    }
  }
}
