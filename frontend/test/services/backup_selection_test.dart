import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/services/backup_selection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('default (no prefs) is ALL mode — everything backs up', () async {
    final s = await BackupSelectionService().load();
    expect(s.mode, BackupMode.all);
    expect(s.includes('Camera'), isTrue);
    expect(s.includes('Some Random Bucket'), isTrue);
  });

  test('selected mode: only enrolled buckets, matched case- and '
      'whitespace-insensitively', () async {
    await BackupSelectionService().setMode(BackupMode.selected);
    await BackupSelectionService().enroll('WhatsApp Images', backfill: false);
    final s = await BackupSelectionService().load();
    expect(s.mode, BackupMode.selected);
    expect(s.includes('WhatsApp Images'), isTrue);
    expect(s.includes('whatsapp  images'), isTrue);
    expect(s.includes('Camera'), isFalse);
  });

  test('unenroll removes the bucket and its queued backfill', () async {
    await BackupSelectionService().setMode(BackupMode.selected);
    await BackupSelectionService().enroll('Camera', backfill: true);
    expect(await BackupSelectionService().pendingBackfills(), {'camera'});

    await BackupSelectionService().unenroll('Camera');
    final s = await BackupSelectionService().load();
    expect(s.includes('Camera'), isFalse);
    expect(await BackupSelectionService().pendingBackfills(), isEmpty);
  });

  test('mode flip keeps the checklist (all -> selected -> all)', () async {
    await BackupSelectionService().setMode(BackupMode.selected);
    await BackupSelectionService().enroll('Camera', backfill: false);
    await BackupSelectionService().setMode(BackupMode.all);
    await BackupSelectionService().setMode(BackupMode.selected);
    final s = await BackupSelectionService().load();
    expect(s.includes('Camera'), isTrue);
    expect(s.includes('Screenshots'), isFalse);
  });

  test('backfill queue: enroll-with-backfill + bulk queue + clear', () async {
    await BackupSelectionService().enroll('Camera', backfill: true);
    await BackupSelectionService()
        .queueBackfills(['Screenshots', 'WhatsApp Images']);
    expect(await BackupSelectionService().pendingBackfills(),
        {'camera', 'screenshots', 'whatsapp images'});

    await BackupSelectionService().clearBackfill('Screenshots');
    expect(await BackupSelectionService().pendingBackfills(),
        {'camera', 'whatsapp images'});
  });
}
