import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/encryption_service.dart';
import 'package:ciphernest/services/local_content_guard.dart';
import 'package:ciphernest/src/models/file_model.dart';

/// LocalContentGuard (#1). "Filename is not identity": a local gallery file may
/// only stand in for a vault entry if its BYTES match. These tests exercise the
/// two gates — size (always) and hash (images, memoized) — and confirm that
/// every resolution failure reads as "not trusted" so display falls to cloud.
///
/// The guard memoizes verdicts in a process-wide cache keyed by
/// (file id, length, mtime); each test uses a DISTINCT (id, size) so verdicts
/// never collide across tests.
CnestFile fileFor({
  required String id,
  required int sizeBytes,
  String? contentHash,
  CnestFileType type = CnestFileType.image,
}) =>
    CnestFile(
      id: id,
      filename: 'photo.jpg',
      sizeBytes: sizeBytes,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      type: type,
      contentHash: contentHash,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lcg_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<File> writeFile(String name, Uint8List bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  Uint8List bytesOf(int n, [int fill = 7]) =>
      Uint8List.fromList(List<int>.filled(n, fill));

  group('size gate', () {
    test('a different-size local file is rejected (edited/replaced case)',
        () async {
      final local = await writeFile('a.jpg', bytesOf(1000));
      // Vault entry expects 2000 bytes — the classic replace-original edit
      // that changes size. Must NOT be trusted.
      final ok = await LocalContentGuard.matches(
        fileFor(id: 'sz1', sizeBytes: 2000, contentHash: null),
        localFile: local,
      );
      expect(ok, isFalse);
    });

    test('size 0 means unknown (just-synced peer) — not rejected on size',
        () async {
      final local = await writeFile('b.jpg', bytesOf(1234));
      final ok = await LocalContentGuard.matches(
        fileFor(id: 'sz2', sizeBytes: 0, contentHash: null),
        localFile: local,
      );
      expect(ok, isTrue, reason: 'unknown size cannot condemn a local file');
    });

    test('a missing local file is not trusted', () async {
      final ok = await LocalContentGuard.matches(
        fileFor(id: 'sz3', sizeBytes: 10, contentHash: null),
        localFile: File('${tmp.path}/does_not_exist.jpg'),
      );
      expect(ok, isFalse);
    });
  });

  group('hash gate (images)', () {
    test('same size but different content is rejected by the hash', () async {
      final localBytes = bytesOf(2048, 9);
      final local = await writeFile('c.jpg', localBytes);
      // Same size, but the vault hash is of DIFFERENT bytes.
      final otherHash =
          await EncryptionService.hashPlaintext(bytesOf(2048, 3));
      final ok = await LocalContentGuard.matches(
        fileFor(id: 'h1', sizeBytes: 2048, contentHash: otherHash),
        localFile: local,
      );
      expect(ok, isFalse, reason: 'same-size, different-content swap');
    });

    test('matching size AND hash is trusted', () async {
      final localBytes = bytesOf(3072, 9);
      final local = await writeFile('d.jpg', localBytes);
      final hash = await EncryptionService.hashPlaintext(localBytes);
      final ok = await LocalContentGuard.matches(
        fileFor(id: 'h2', sizeBytes: 3072, contentHash: hash),
        localFile: local,
      );
      expect(ok, isTrue);
    });

    test('legacy row (no hash) trusts on the size gate alone', () async {
      final local = await writeFile('e.jpg', bytesOf(4096));
      final ok = await LocalContentGuard.matches(
        fileFor(id: 'h3', sizeBytes: 4096, contentHash: null),
        localFile: local,
      );
      expect(ok, isTrue);
    });

    test('non-image with matching size is NOT hashed, trusted on size',
        () async {
      // A "video": wrong-content hash present, but type != image means the
      // hash is skipped (never an on-thread hash of a huge file) — size wins.
      final local = await writeFile('f.mp4', bytesOf(5000, 1));
      final wrongHash =
          await EncryptionService.hashPlaintext(bytesOf(5000, 2));
      final ok = await LocalContentGuard.matches(
        fileFor(
            id: 'h4',
            sizeBytes: 5000,
            contentHash: wrongHash,
            type: CnestFileType.other),
        localFile: local,
      );
      expect(ok, isTrue, reason: 'size gate only for non-images');
    });
  });
}
