import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:ciphernest/services/system_folders.dart';
import 'package:ciphernest/services/auto_sync_service.dart';

void main() {
  const key = 'samsung sm-a556e';

  test('ids are deterministic — same derivation, same id, every time', () {
    expect(SystemFolders.deviceId(key), SystemFolders.deviceId(key));
    expect(SystemFolders.pathSegmentId(key, ['DCIM', 'Camera']),
        SystemFolders.pathSegmentId(key, ['DCIM', 'Camera']));
    expect(SystemFolders.rootId, SystemFolders.rootId);
  });

  test('deviceKey + segments: case and whitespace variants map to ONE id',
      () {
    expect(SystemFolders.deviceKey('Samsung', 'SM-A556E'), key);
    expect(SystemFolders.deviceKey(' samsung ', ' sm-a556e '), key);
    final canonical = SystemFolders.pathSegmentId(key, ['WhatsApp Images']);
    expect(SystemFolders.pathSegmentId(key, ['whatsapp images']), canonical);
    expect(
        SystemFolders.pathSegmentId(key, ['  WhatsApp   Images ']), canonical);
  });

  test('deviceDisplayName capitalizes the manufacturer, model verbatim', () {
    expect(SystemFolders.deviceDisplayName('samsung', 'SM-A556E'),
        'Samsung SM-A556E');
    expect(SystemFolders.deviceDisplayName('', 'SM-A556E'), 'SM-A556E');
    expect(SystemFolders.deviceDisplayName('samsung', ''), 'Samsung');
  });

  test('cumulative prefixes are DISTINCT folders (parent and child)', () {
    final ids = {
      SystemFolders.rootId,
      SystemFolders.deviceId(key),
      SystemFolders.pathSegmentId(key, ['DCIM']),
      SystemFolders.pathSegmentId(key, ['DCIM', 'Camera']),
      SystemFolders.pathSegmentId(key, ['Pictures']),
    };
    expect(ids.length, 5);
  });

  test('distinct devices get distinct subtrees for the SAME path', () {
    const other = 'google pixel 9';
    expect(SystemFolders.deviceId(key) == SystemFolders.deviceId(other),
        isFalse);
    expect(
        SystemFolders.pathSegmentId(key, ['DCIM']) ==
            SystemFolders.pathSegmentId(other, ['DCIM']),
        isFalse);
  });

  test('isSystemId: sys- ids yes, user UUIDv4 ids no', () {
    expect(SystemFolders.isSystemId(SystemFolders.rootId), isTrue);
    expect(SystemFolders.isSystemId(SystemFolders.deviceId(key)), isTrue);
    expect(
        SystemFolders.isSystemId(
            SystemFolders.pathSegmentId(key, ['DCIM', 'Camera'])),
        isTrue);
    expect(SystemFolders.isSystemId(const Uuid().v4()), isFalse);
    expect(SystemFolders.isSystemId(''), isFalse);
  });

  group('AutoSyncService.pathSegments', () {
    test('MediaStore RELATIVE_PATH splits into segments', () {
      expect(AutoSyncService.pathSegments('DCIM/Camera/', 'Camera'),
          ['DCIM', 'Camera']);
      expect(AutoSyncService.pathSegments('Pictures/Screenshots/', null),
          ['Pictures', 'Screenshots']);
    });

    test('Android <=9 absolute path: primary-storage prefix stripped', () {
      expect(
          AutoSyncService.pathSegments(
              '/storage/emulated/0/DCIM/Camera', 'Camera'),
          ['DCIM', 'Camera']);
    });

    test('unusable absolute path falls back to the bucket name', () {
      expect(AutoSyncService.pathSegments('/sdcard/DCIM/Camera', 'Camera'),
          ['Camera']);
    });

    test('null/blank path falls back to bucket; nothing at all -> empty', () {
      expect(AutoSyncService.pathSegments(null, 'WhatsApp Images'),
          ['WhatsApp Images']);
      expect(AutoSyncService.pathSegments('  ', 'Camera'), ['Camera']);
      expect(AutoSyncService.pathSegments(null, null), isEmpty);
      expect(AutoSyncService.pathSegments('', '  '), isEmpty);
    });
  });
}
