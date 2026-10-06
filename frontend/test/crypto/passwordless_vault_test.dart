/// "Continue without password" (2026-10-06 ruling): a vault whose seed is held
/// by the Keystore-backed secure store instead of an Argon2id password wrap.
///
/// The two things that must never break:
///   * an existing password vault must migrate as a NO-OP, and
///   * a passwordless vault must still be reachable, wipeable, and must leave
///     nothing behind that would let a later password vault inherit its seed.
library;

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

  group('passwordless vault', () {
    test('creates, unlocks with no password, and reports its mode', () async {
      final svc = KeyManagerService();
      final mnemonic = await svc.createAccountWithoutPassword();

      expect(mnemonic.split(' ').length, 12);
      expect(svc.isUnlocked, isTrue);
      expect(await svc.isPasswordless(), isTrue);
      expect(await svc.hasAccount(), isTrue,
          reason: 'hasAccount keys off the password blob, which this mode '
              'never writes; a regression here sends the user to onboarding '
              'and silently abandons their vault');

      final pub = svc.vaultPublicKey.bytes;
      svc.lock();
      expect(svc.isUnlocked, isFalse);

      expect(await svc.unlockWithoutPassword(), isTrue);
      expect(svc.isUnlocked, isTrue);
      expect(svc.vaultPublicKey.bytes, pub,
          reason: 'the same seed must come back, or every file is unreadable');
    });

    test('the phrase is still recoverable, since it is the only root',
        () async {
      final svc = KeyManagerService();
      final mnemonic = await svc.createAccountWithoutPassword();
      expect(await svc.revealMnemonicNoAuth(), mnemonic);
    });

    test('wipe destroys the seed, the phrase and the mode flag', () async {
      final svc = KeyManagerService();
      await svc.createAccountWithoutPassword();
      await svc.wipeVault();

      expect(svc.isUnlocked, isFalse);
      expect(await svc.isPasswordless(), isFalse);
      expect(await svc.hasAccount(), isFalse);
      expect(await svc.revealMnemonicNoAuth(), isNull);
      expect(await svc.unlockWithoutPassword(), isFalse,
          reason: 'a wiped vault must not reopen itself');
    });

    test('a password vault is NOT reported as passwordless', () async {
      final svc = KeyManagerService();
      await svc.createAccount('local-password-1');
      expect(await svc.isPasswordless(), isFalse);
      expect(await svc.hasAccount(), isTrue);
    });
  });

  group('migration', () {
    test('an install with no mode flag reads as password mode', () async {
      // Every vault that exists today. Absent flag must mean password, or
      // existing users are routed into a passwordless unlock that cannot work.
      SharedPreferences.setMockInitialValues({});
      final svc = KeyManagerService();
      expect(await svc.isPasswordless(), isFalse);
    });

    test('a password vault still unlocks with its password', () async {
      final svc = KeyManagerService();
      await svc.createAccount('local-password-1');
      svc.lock();
      expect(await svc.unlock('local-password-1'), isTrue);
      expect(await svc.unlock('wrong-password'), isFalse);
    });
  });
}
