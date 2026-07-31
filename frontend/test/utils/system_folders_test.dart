import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:ciphernest/services/system_folders.dart';

void main() {
  test('bucket ids are deterministic — two devices mint the same id', () {
    expect(SystemFolders.bucketId('Camera'), SystemFolders.bucketId('Camera'));
    expect(SystemFolders.rootId, SystemFolders.rootId);
  });

  test('normalization: case and whitespace variants map to ONE folder', () {
    final canonical = SystemFolders.bucketId('WhatsApp Images');
    expect(SystemFolders.bucketId('whatsapp images'), canonical);
    expect(SystemFolders.bucketId('  WhatsApp   Images '), canonical);
  });

  test('distinct buckets get distinct ids, none colliding with the root', () {
    final ids = {
      SystemFolders.rootId,
      SystemFolders.bucketId('Camera'),
      SystemFolders.bucketId('Screenshots'),
      SystemFolders.bucketId('WhatsApp Images'),
    };
    expect(ids.length, 4);
  });

  test('isSystemId: sys- ids yes, user UUIDv4 ids no', () {
    expect(SystemFolders.isSystemId(SystemFolders.rootId), isTrue);
    expect(SystemFolders.isSystemId(SystemFolders.bucketId('Camera')), isTrue);
    expect(SystemFolders.isSystemId(const Uuid().v4()), isFalse);
    expect(SystemFolders.isSystemId(''), isFalse);
  });
}
