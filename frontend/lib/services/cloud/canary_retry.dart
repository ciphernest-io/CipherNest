import 'package:flutter/foundation.dart';

import 'cloud_service.dart';

/// Two-shot canary with backoff. Absorbs the well-known google_sign_in
/// silent-cache warm-up race and short-lived token-propagation 401s from
/// Drive/Graph without confusing the user.
///
/// Only *transient* exceptions retry; a `false` return (real crypto
/// mismatch — the master key can't decrypt the first `.cnest` blob) stops
/// immediately so the caller can surface the "phrase doesn't match" path
/// without a spurious retry.
///
/// Both call sites use this:
///   - `cloud_selection_screen._connectProvider` (signup / restore probe)
///   - `key_management_screen._runCanaryTest` (Settings-triggered check)
Future<bool> canaryWithRetry({
  int attempts = 2,
  Duration backoff = const Duration(milliseconds: 400),
}) async {
  for (int i = 0; i < attempts; i++) {
    try {
      return await CloudService().canaryTest();
    } catch (e) {
      debugPrint('Canary attempt ${i + 1} threw: $e');
      if (i == attempts - 1) rethrow;
      await Future.delayed(backoff);
    }
  }
  return false;
}
