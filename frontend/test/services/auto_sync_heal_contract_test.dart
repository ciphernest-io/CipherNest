import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/auto_sync_service.dart';

void main() {
  test(
      'C1 contract: a failed FRESH upload rolls its row back; a failed HEAL '
      'retry NEVER does (the pending row is the retry state — deleting it '
      'after the watermark passed the asset silently loses the photo)', () {
    expect(
        AutoSyncService.shouldRollbackFailedAttempt(isHealRetry: false),
        isTrue);
    expect(
        AutoSyncService.shouldRollbackFailedAttempt(isHealRetry: true),
        isFalse,
        reason:
            'Heal-path rollback re-introduces the silent-photo-loss data '
            'bug: row deleted -> assetId leaves the dedup index -> capture '
            'time already behind the watermark -> never scanned again.');
  });
}
