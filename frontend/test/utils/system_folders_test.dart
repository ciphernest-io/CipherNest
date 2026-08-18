import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:ciphernest/services/system_folders.dart';

void main() {
  const acct = 'g_test@example.com';
  const key = 'samsung sm-a556e';

  test('ids are deterministic — same derivation, same id, every time', () {
    expect(SystemFolders.deviceId(acct, key),
        SystemFolders.deviceId(acct, key));
    expect(SystemFolders.albumId(acct, key, 'Camera'),
        SystemFolders.albumId(acct, key, 'Camera'));
    expect(SystemFolders.rootId(acct), SystemFolders.rootId(acct));
  });

  test('deviceKey + album name: case and whitespace variants map to ONE id',
      () {
    expect(SystemFolders.deviceKey('Samsung', 'SM-A556E'), key);
    expect(SystemFolders.deviceKey(' samsung ', ' sm-a556e '), key);
    final canonical = SystemFolders.albumId(acct, key, 'WhatsApp Images');
    expect(SystemFolders.albumId(acct, key, 'whatsapp images'), canonical);
    expect(
        SystemFolders.albumId(acct, key, '  WhatsApp   Images '), canonical);
  });

  test('account salt: variants of the SAME account fold; DIFFERENT accounts '
      'get fully disjoint trees (root included)', () {
    // Same account, cosmetic variants -> one tree (two phones converge).
    expect(SystemFolders.rootId(' G_Test@Example.com '),
        SystemFolders.rootId(acct));
    // Different account -> every level distinct, so the shared global
    // folders PK can never collide across linked accounts.
    const other = 'second@example.com';
    expect(SystemFolders.rootId(other) == SystemFolders.rootId(acct), isFalse);
    expect(
        SystemFolders.deviceId(other, key) == SystemFolders.deviceId(acct, key),
        isFalse);
    expect(
        SystemFolders.albumId(other, key, 'Camera') ==
            SystemFolders.albumId(acct, key, 'Camera'),
        isFalse);
  });

  test('deviceDisplayName capitalizes the manufacturer, model verbatim', () {
    expect(SystemFolders.deviceDisplayName('samsung', 'SM-A556E'),
        'Samsung SM-A556E');
    expect(SystemFolders.deviceDisplayName('', 'SM-A556E'), 'SM-A556E');
    expect(SystemFolders.deviceDisplayName('samsung', ''), 'Samsung');
  });

  test('root, device, and distinct album names are all DISTINCT folders', () {
    final ids = {
      SystemFolders.rootId(acct),
      SystemFolders.deviceId(acct, key),
      SystemFolders.albumId(acct, key, 'Camera'),
      SystemFolders.albumId(acct, key, 'Screenshots'),
      SystemFolders.albumId(acct, key, 'WhatsApp Images'),
    };
    expect(ids.length, 5);
  });

  test('distinct devices get distinct subtrees for the SAME album name', () {
    const other = 'google pixel 9';
    expect(
        SystemFolders.deviceId(acct, key) == SystemFolders.deviceId(acct, other),
        isFalse);
    expect(
        SystemFolders.albumId(acct, key, 'Camera') ==
            SystemFolders.albumId(acct, other, 'Camera'),
        isFalse);
  });

  test('album ids can never collide with legacy path-mirror ids', () {
    // The retired scheme derived from 'path:<device>/<segments>'; the flat
    // scheme derives from 'album:<device>/<name>'. Same visible name, two
    // different derivation domains — a wiped-and-reused vault that still
    // holds legacy folders can never alias a new album folder.
    final legacyStyle = SystemFolders.idPrefix +
        const Uuid().v5('8f6a1c2e-4b7d-4f3a-9e15-c0d2a6b83e51',
            'acct:${SystemFolders.normalize(acct)}/path:$key/camera');
    expect(SystemFolders.albumId(acct, key, 'Camera') == legacyStyle, isFalse);
  });

  test('isSystemId: sys- ids yes, user UUIDv4 ids no', () {
    expect(SystemFolders.isSystemId(SystemFolders.rootId(acct)), isTrue);
    expect(
        SystemFolders.isSystemId(SystemFolders.deviceId(acct, key)), isTrue);
    expect(
        SystemFolders.isSystemId(SystemFolders.albumId(acct, key, 'Camera')),
        isTrue);
    expect(SystemFolders.isSystemId(const Uuid().v4()), isFalse);
    expect(SystemFolders.isSystemId(''), isFalse);
  });
}
