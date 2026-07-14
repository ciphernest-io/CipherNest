import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/database_backup_service.dart';

/// Stage 1 of multi-device sync: per-device snapshot naming. What must never
/// regress is the naming discipline (a device only ever writes its own name)
/// and the classification logic the restore picker and the second-device
/// notice hang off.
void main() {
  group('isBackupFile', () {
    test('matches both snapshot generations, rejects vault names', () {
      expect(
          DatabaseBackupService.isBackupFile('ciphernest_db_backup.cnest'),
          isTrue);
      expect(
          DatabaseBackupService.isBackupFile(
              'db_backup_1f2e3d4c-aaaa-bbbb-cccc-1234567890ab.cnest'),
          isTrue);
      // Vault blobs and thumbs must never be treated as backups.
      expect(
          DatabaseBackupService.isBackupFile(
              '9c1b2a3f-dddd-eeee-ffff-0987654321fe.cnest'),
          isFalse);
      expect(
          DatabaseBackupService.isBackupFile(
              '9c1b2a3f-dddd-eeee-ffff-0987654321fe_thumb.cnest'),
          isFalse);
      // OneDrive metadata-encoded vault names.
      expect(
          DatabaseBackupService.isBackupFile('abc.cnest__m__kX9aB'), isFalse);
      expect(DatabaseBackupService.isBackupFile('db_backup_.txt'), isFalse);
    });
  });

  group('deviceIdFromName', () {
    test('extracts the id from per-device names', () {
      expect(
        DatabaseBackupService.deviceIdFromName('db_backup_dev-123.cnest'),
        'dev-123',
      );
    });

    test('legacy and malformed names yield null', () {
      expect(
        DatabaseBackupService.deviceIdFromName('ciphernest_db_backup.cnest'),
        isNull,
      );
      expect(DatabaseBackupService.deviceIdFromName('db_backup_.cnest'),
          isNull);
      expect(DatabaseBackupService.deviceIdFromName('random.cnest'), isNull);
    });

    test('round-trips with the prefix scheme', () {
      const id = '1f2e3d4c-aaaa-bbbb-cccc-1234567890ab';
      final name = '${DatabaseBackupService.backupPrefix}$id.cnest';
      expect(DatabaseBackupService.deviceIdFromName(name), id);
      expect(DatabaseBackupService.isBackupFile(name), isTrue);
    });
  });

  group('snapshot ordering and classification', () {
    BackupSnapshot snap({
      required String id,
      String? deviceId,
      DateTime? modified,
      bool mine = false,
    }) =>
        BackupSnapshot(
          cloudId: id,
          name: deviceId == null
              ? DatabaseBackupService.legacyBackupFileName
              : 'db_backup_$deviceId.cnest',
          deviceId: deviceId,
          modified: modified,
          sizeBytes: 1024,
          isThisDevice: mine,
        );

    test('sorts newest first, undated (legacy) last', () {
      final list = [
        snap(id: 'legacy'),
        snap(id: 'old', deviceId: 'a', modified: DateTime(2026, 7, 1)),
        snap(
            id: 'new',
            deviceId: 'b',
            modified: DateTime(2026, 7, 14),
            mine: true),
      ];
      DatabaseBackupService.sortSnapshots(list);
      expect(list.map((s) => s.cloudId).toList(), ['new', 'old', 'legacy']);
    });

    test('foreign detection ignores legacy and own snapshots', () {
      final onlyMineAndLegacy = [
        snap(id: 'mine', deviceId: 'me', mine: true),
        snap(id: 'legacy'),
      ];
      expect(
        onlyMineAndLegacy.any((s) => !s.isLegacy && !s.isThisDevice),
        isFalse,
        reason: 'own snapshot + legacy must NOT trigger the notice',
      );

      final withForeign = [
        ...onlyMineAndLegacy,
        snap(id: 'tablet', deviceId: 'other-device'),
      ];
      expect(
        withForeign.any((s) => !s.isLegacy && !s.isThisDevice),
        isTrue,
        reason: 'a second device\'s snapshot must trigger the notice',
      );
    });
  });
}
