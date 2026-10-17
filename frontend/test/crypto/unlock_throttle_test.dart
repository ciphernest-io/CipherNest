/// MASVS F-15 (2026-10-17): repeated wrong passwords earn a persisted,
/// doubling lockout; a correct password clears it; wiping the vault clears it.
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

  test('five wrong passwords lock the vault, the sixth is refused', () async {
    final svc = KeyManagerService();
    await svc.createAccount('right-pw');
    svc.lock();

    for (var i = 0; i < 5; i++) {
      expect(await svc.unlock('wrong-$i'), isFalse);
    }
    expect(await svc.unlockLockoutRemaining(), greaterThan(Duration.zero));
    await expectLater(
      svc.unlock('right-pw'),
      throwsA(isA<UnlockThrottledException>()),
      reason: 'even the correct password waits out the lockout',
    );
  });

  test('a correct password before the limit clears the counter', () async {
    final svc = KeyManagerService();
    await svc.createAccount('right-pw');
    svc.lock();

    for (var i = 0; i < 4; i++) {
      expect(await svc.unlock('wrong-$i'), isFalse);
    }
    expect(await svc.unlock('right-pw'), isTrue);
    expect(await svc.unlockLockoutRemaining(), Duration.zero);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('unlock_failures_v1'), isNull);
    svc.lock();
    // The counter restarted: four more misses still do not lock.
    for (var i = 0; i < 4; i++) {
      expect(await svc.unlock('again-$i'), isFalse);
    }
    expect(await svc.unlockLockoutRemaining(), Duration.zero);
  });

  test('the lockout is persisted, not in memory', () async {
    final svc = KeyManagerService();
    await svc.createAccount('right-pw');
    svc.lock();
    for (var i = 0; i < 5; i++) {
      await svc.unlock('wrong-$i');
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('unlock_locked_until_v1'), isNotNull);
    expect(prefs.getInt('unlock_failures_v1'), 5);
  });

  test('wiping the vault clears the throttle', () async {
    final svc = KeyManagerService();
    await svc.createAccount('right-pw');
    svc.lock();
    for (var i = 0; i < 5; i++) {
      await svc.unlock('wrong-$i');
    }
    await svc.wipeVault();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('unlock_locked_until_v1'), isNull);
    expect(prefs.getInt('unlock_failures_v1'), isNull);
  });
}
