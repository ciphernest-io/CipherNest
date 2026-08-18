import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/backup_backfill_runner.dart';

void main() {
  test('matchPending: normalized match, device-list order, others ignored',
      () {
    final matched = BackupBackfillRunner.matchPending(
      {'camera', 'whatsapp images'},
      ['Screenshots', 'WhatsApp  Images', 'Camera', 'Downloads'],
    );
    expect(matched, ['WhatsApp  Images', 'Camera']);
  });

  test('matchPending: pending album missing from device is simply skipped',
      () {
    final matched = BackupBackfillRunner.matchPending(
      {'gone album'},
      ['Camera'],
    );
    expect(matched, isEmpty);
  });
}
