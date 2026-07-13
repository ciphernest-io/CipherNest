import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ciphernest/services/biometric_unlock_service.dart';
import 'package:ciphernest/services/key_manager_service.dart';

/// The service is a thin channel wrapper; what must never regress is the
/// error-code mapping (a mis-mapped 'invalidated' would skip the wipe path
/// and strand the user in a broken-prompt loop) and the teardown/flag
/// ordering. Hardware guarantees are out of scope here — device QA owns them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ciphernest/biometric_seed');
  final log = <MethodCall>[];
  Object? Function(MethodCall call)? handler;

  setUp(() {
    log.clear();
    handler = null;
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return handler?.call(call);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('capability / checkArmed string mapping', () {
    test('maps every capability string', () async {
      for (final expected in BiometricCapability.values) {
        handler = (_) => expected.name;
        expect(await BiometricUnlockService().capability(), expected);
      }
    });

    test('unknown capability string degrades to unavailable', () async {
      handler = (_) => 'somethingNew';
      expect(await BiometricUnlockService().capability(),
          BiometricCapability.unavailable);
    });

    test('maps every armed-state string', () async {
      for (final expected in BiometricArmedState.values) {
        handler = (_) => expected.name;
        expect(await BiometricUnlockService().checkArmed(), expected);
      }
    });

    test('unknown armed string degrades to invalidated (recovery path)',
        () async {
      handler = (_) => 'halfArmed';
      expect(await BiometricUnlockService().checkArmed(),
          BiometricArmedState.invalidated);
    });
  });

  group('unwrapSeed', () {
    test('returns the 64-byte seed', () async {
      final seed = Uint8List.fromList(List.generate(64, (i) => i));
      handler = (_) => seed;
      final out = await BiometricUnlockService().unwrapSeed();
      expect(out, seed);
    });

    test('returned seed is mutable even when the channel yields an '
        'unmodifiable view (zeroing must not throw)', () async {
      // Production regression: the real codec returns unmodifiable typed
      // data; KeyManagerService zeroes the seed in a finally, and the throw
      // replaced unlock's return — every biometric unlock died silently.
      final seed = Uint8List.fromList(List.generate(64, (i) => i));
      handler = (_) => seed.asUnmodifiableView();
      final out = await BiometricUnlockService().unwrapSeed();
      expect(() => out.fillRange(0, out.length, 0), returnsNormally);
      expect(out.every((b) => b == 0), isTrue);
    });

    test('rejects a wrong-length seed', () async {
      handler = (_) => Uint8List(32);
      expect(
        () => BiometricUnlockService().unwrapSeed(),
        throwsA(isA<BiometricUnlockException>().having(
            (e) => e.code, 'code', BiometricUnlockError.failed)),
      );
    });

    test('maps every platform error code to its typed error', () async {
      for (final expected in BiometricUnlockError.values) {
        handler = (_) => throw PlatformException(code: expected.name);
        expect(
          () => BiometricUnlockService().unwrapSeed(),
          throwsA(isA<BiometricUnlockException>()
              .having((e) => e.code, 'code', expected)),
          reason: 'platform code "${expected.name}" must map to itself',
        );
      }
    });

    test('unknown platform code degrades to failed', () async {
      handler = (_) => throw PlatformException(code: 'brandNewOemError');
      expect(
        () => BiometricUnlockService().unwrapSeed(),
        throwsA(isA<BiometricUnlockException>().having(
            (e) => e.code, 'code', BiometricUnlockError.failed)),
      );
    });
  });

  group('wrapSeed', () {
    test('sends the seed as binary and succeeds', () async {
      handler = (_) => true;
      final seed = Uint8List(64);
      await BiometricUnlockService().wrapSeed(seed);
      expect(log.single.method, 'enable');
      expect(log.single.arguments['seed'], seed);
    });

    test('maps enable-time cancellation', () async {
      handler = (_) => throw PlatformException(code: 'userCanceled');
      expect(
        () => BiometricUnlockService().wrapSeed(Uint8List(64)),
        throwsA(isA<BiometricUnlockException>().having(
            (e) => e.code, 'code', BiometricUnlockError.userCanceled)),
      );
    });
  });

  group('teardown and flag', () {
    test('teardown never throws, even when the channel does', () async {
      handler = (_) => throw PlatformException(code: 'failed');
      await BiometricUnlockService().teardown(); // must not throw
      expect(log.single.method, 'disable');
    });

    test('enabled flag round-trips through prefs', () async {
      final svc = BiometricUnlockService();
      expect(await svc.isEnabled(), isFalse);
      await svc.setEnabled(true);
      expect(await svc.isEnabled(), isTrue);
      await svc.setEnabled(false);
      expect(await svc.isEnabled(), isFalse);
    });
  });

  group('KeyManagerService.unlockWithBiometric invalidation handling', () {
    test(
        'invalidated → wrap torn down, flag cleared, '
        'BiometricInvalidatedException surfaced', () async {
      SharedPreferences.setMockInitialValues(
          {'biometric_enabled_v2': true});
      handler = (call) {
        if (call.method == 'unlock') {
          throw PlatformException(code: 'invalidated');
        }
        return true; // disable
      };
      await expectLater(
        () => KeyManagerService().unlockWithBiometric(),
        throwsA(isA<BiometricInvalidatedException>()),
      );
      // The wipe must have happened BEFORE the exception reached the UI:
      // native teardown was invoked and the flag is off.
      expect(log.map((c) => c.method), containsAllInOrder(
          ['unlock', 'disable']));
      expect(await BiometricUnlockService().isEnabled(), isFalse);
    });

    test('keyMissing (OEM deleted the key) takes the identical path',
        () async {
      SharedPreferences.setMockInitialValues(
          {'biometric_enabled_v2': true});
      handler = (call) {
        if (call.method == 'unlock') {
          throw PlatformException(code: 'keyMissing');
        }
        return true;
      };
      await expectLater(
        () => KeyManagerService().unlockWithBiometric(),
        throwsA(isA<BiometricInvalidatedException>()),
      );
      expect(log.map((c) => c.method), containsAllInOrder(
          ['unlock', 'disable']));
    });

    test('userCanceled rethrows untouched — no wipe', () async {
      SharedPreferences.setMockInitialValues(
          {'biometric_enabled_v2': true});
      handler = (call) {
        if (call.method == 'unlock') {
          throw PlatformException(code: 'userCanceled');
        }
        return true;
      };
      await expectLater(
        () => KeyManagerService().unlockWithBiometric(),
        throwsA(isA<BiometricUnlockException>().having(
            (e) => e.code, 'code', BiometricUnlockError.userCanceled)),
      );
      expect(log.map((c) => c.method), isNot(contains('disable')));
      expect(await BiometricUnlockService().isEnabled(), isTrue);
    });
  });
}
