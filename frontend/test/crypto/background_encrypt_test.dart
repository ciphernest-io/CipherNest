/// The worker-isolate encrypt path must be byte-compatible with the main
/// path: same v1 format, decryptable by the existing code, same content
/// hash. (It IS the same code — these tests pin that it stays that way.)
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/services/encryption_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    await KeyManagerService().stageRecovery(bip39.generateMnemonic(), 'pw');
    await KeyManagerService().commitStagedRecovery();
  });

  Uint8List randomBytes(int n) {
    final rnd = Random(42);
    return Uint8List.fromList(List.generate(n, (_) => rnd.nextInt(256)));
  }

  test('encryptFileWithHashInBackground round-trips and hashes identically',
      () async {
    // Crosses the 512 KiB chunk boundary so multi-chunk framing is covered.
    final plain = randomBytes(700 * 1024);

    final bg = await EncryptionService.encryptFileWithHashInBackground(plain);
    expect(bg.hash, await EncryptionService.hashPlaintext(plain));

    final decrypted = await EncryptionService.decryptFile(bg.encrypted);
    expect(decrypted, equals(plain));
  });

  test('encryptFileInBackground output opens with the existing path',
      () async {
    final plain = randomBytes(64 * 1024);
    final encrypted = await EncryptionService.encryptFileInBackground(plain);
    expect(encrypted[0], EncryptionService.formatVersion);
    expect(encrypted.length,
        EncryptionService.calculateEncryptedSize(plain.length));
    expect(await EncryptionService.decryptFile(encrypted), equals(plain));
  });
}
