/// "Continue without password" on the RESTORE path (2026-10-17): a staged
/// recovery committed with no password lands in the Keystore-backed secure
/// store, exactly like a passwordless signup, and a vault is only ever in one
/// mode at a time.
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

  test('staging without a password persists nothing', () async {
    final svc = KeyManagerService();
    await svc.stageRecovery(bip39.generateMnemonic());
    expect(svc.isUnlocked, isTrue, reason: 'keys derived for the canary');
    expect(svc.hasStagedRecovery, isTrue);
    expect(await svc.hasAccount(), isFalse);
    expect(await svc.isPasswordless(), isFalse);
    svc.discardStagedRecovery();
  });

  test('committing a passwordless restore opens without a password', () async {
    final svc = KeyManagerService();
    final mnemonic = bip39.generateMnemonic();
    await svc.stageRecovery(mnemonic);
    final pub = svc.vaultPublicKey.bytes;
    await svc.commitStagedRecovery();

    expect(await svc.isPasswordless(), isTrue);
    expect(await svc.hasAccount(), isTrue);
    expect(await svc.revealMnemonicNoAuth(), mnemonic);

    svc.lock();
    expect(await svc.unlockWithoutPassword(), isTrue);
    expect(svc.vaultPublicKey.bytes, pub,
        reason: 'the restored seed must be the one that was staged');
    expect(await svc.unlock('anything'), isFalse,
        reason: 'there is no password blob to open');
  });

  test('a password restore over a passwordless vault leaves one mode',
      () async {
    final svc = KeyManagerService();
    await svc.createAccountWithoutPassword();
    expect(await svc.isPasswordless(), isTrue);

    await svc.stageRecovery(bip39.generateMnemonic(), 'new-pw');
    await svc.commitStagedRecovery();

    expect(await svc.isPasswordless(), isFalse,
        reason: 'the password mode must clear the passwordless flag');
    expect(await svc.revealMnemonicNoAuth(), isNull);
    svc.lock();
    expect(await svc.unlockWithoutPassword(), isFalse);
    expect(await svc.unlock('new-pw'), isTrue);
  });

  test('a passwordless restore over a password vault leaves one mode',
      () async {
    final svc = KeyManagerService();
    await svc.createAccount('old-pw');

    await svc.stageRecovery(bip39.generateMnemonic());
    await svc.commitStagedRecovery();

    expect(await svc.isPasswordless(), isTrue);
    svc.lock();
    expect(await svc.unlock('old-pw'), isFalse,
        reason: 'the old password blob must be gone');
    expect(await svc.unlockWithoutPassword(), isTrue);
  });

  test('a passwordless signup can hand off to a passwordless restore',
      () async {
    final svc = KeyManagerService();
    await svc.createAccountWithoutPassword();
    expect(svc.hasSignupPassword, isTrue,
        reason: 'the hand-off is offered for a no-password signup too');

    await svc.abandonSignupForRestore(bip39.generateMnemonic());
    expect(svc.hasStagedRecovery, isTrue);
    await svc.commitStagedRecovery();

    expect(await svc.isPasswordless(), isTrue);
    svc.lock();
    expect(await svc.unlockWithoutPassword(), isTrue);
  });
}
