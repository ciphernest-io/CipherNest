/// Staged recovery (MTR#1 F9): a restore phrase must prove ownership BEFORE
/// anything persists. The old flow wrote the seed blob at the password
/// screen; a wrong-but-checksum-valid phrase permanently overwrote the vault
/// keys and only a reinstall recovered the device.
library;

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/services/key_manager_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('stageRecovery loads keys in memory and persists NOTHING', () async {
    final svc = KeyManagerService();
    final mnemonic = bip39.generateMnemonic();

    await svc.stageRecovery(mnemonic, 'local-password-1');

    expect(svc.isUnlocked, isTrue, reason: 'canary needs the staged keys');
    expect(svc.canEncrypt, isTrue);
    expect(svc.hasStagedRecovery, isTrue);
    expect(await svc.hasAccount(), isFalse,
        reason: 'no seed blob before ownership is proven');

    svc.discardStagedRecovery();
    expect(svc.isUnlocked, isFalse);
    expect(svc.canEncrypt, isFalse);
    expect(svc.hasStagedRecovery, isFalse);
    expect(await svc.hasAccount(), isFalse);
  });

  test('commitStagedRecovery persists; the phrase round-trips via unlock',
      () async {
    final svc = KeyManagerService();
    final mnemonic = bip39.generateMnemonic();

    await svc.stageRecovery(mnemonic, 'local-password-2');
    await svc.commitStagedRecovery();

    expect(await svc.hasAccount(), isTrue);
    expect(svc.hasStagedRecovery, isFalse);
    expect(svc.isUnlocked, isTrue, reason: 'keys stay resident post-commit');

    // The persisted blob must decrypt with the staged password and derive
    // the same public key (the anti-tamper check inside unlock verifies).
    svc.lock();
    expect(svc.isUnlocked, isFalse);
    expect(await svc.unlock('wrong-password'), isFalse);
    expect(await svc.unlock('local-password-2'), isTrue);
  });

  test('wipeVault destroys every key artifact', () async {
    final svc = KeyManagerService();
    await svc.stageRecovery(bip39.generateMnemonic(), 'pw');
    await svc.commitStagedRecovery();
    expect(await svc.hasAccount(), isTrue);

    await svc.wipeVault();

    expect(await svc.hasAccount(), isFalse);
    expect(svc.isUnlocked, isFalse);
    expect(svc.canEncrypt, isFalse);
    expect(await svc.hasSignupInProgress(), isFalse);
    expect(await svc.unlock('pw'), isFalse,
        reason: 'no blob left to unlock');
  });

  test('re-staging replaces a previous staged candidate cleanly', () async {
    final svc = KeyManagerService();
    await svc.stageRecovery(bip39.generateMnemonic(), 'pw-a');
    await svc.stageRecovery(bip39.generateMnemonic(), 'pw-b');
    await svc.commitStagedRecovery();

    svc.lock();
    expect(await svc.unlock('pw-a'), isFalse);
    expect(await svc.unlock('pw-b'), isTrue);
  });
}
