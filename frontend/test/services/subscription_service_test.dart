import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ciphernest/services/subscription_service.dart';
import 'package:ciphernest/src/config/billing.dart';

/// Entitlement is now a DEADLINE evaluated locally, not a cached verdict.
/// These tests pin the behaviour that the old bool could not express, and in
/// particular the two directions it must never get wrong:
///
///   * a lapsed subscriber must NOT keep Plus indefinitely (the bug this
///     replaced: observed on device with RevenueCat reporting no entitlement
///     while the app still allowed unlimited uploads), and
///   * a paying subscriber must NOT be downgraded just because the network
///     was unreachable.
void main() {
  final svc = SubscriptionService();

  int msFromNow(Duration d) =>
      DateTime.now().add(d).millisecondsSinceEpoch;

  /// Seeds prefs and forces a reload. init() is idempotent by design, so the
  /// in-memory copy has to be dropped first or the mock values are ignored.
  Future<void> seed(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    svc.resetForTest();
    await svc.init();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('local expiry evaluation', () {
    test('future expiry means Plus', () async {
      await seed({'plus_expires_at_v1': msFromNow(const Duration(days: 20))});
      expect(svc.isPlus, isTrue);
      expect(svc.isPastExpiry, isFalse);
    });

    test('past expiry means Free, with no network involved', () async {
      await seed({'plus_expires_at_v1': msFromNow(const Duration(days: -1))});
      expect(svc.isPastExpiry, isTrue);
      // This is the forever-free bug. A bool could never reach false here.
      expect(svc.isPlus, isFalse);
    });

    test('lifetime is Plus regardless of any expiry', () async {
      await seed({
        'plus_is_lifetime_v1': true,
        'plus_expires_at_v1': msFromNow(const Duration(days: -400)),
      });
      expect(svc.isPlus, isTrue);
      expect(svc.isPastExpiry, isFalse,
          reason: 'lifetime has no expiry to be past');
    });
  });

  group('offline tolerance', () {
    test('past expiry + attempt FAILED + inside tolerance holds Plus',
        () async {
      await seed({'plus_expires_at_v1': msFromNow(const Duration(hours: -2))});
      expect(svc.isPlus, isFalse, reason: 'no failure recorded yet');
      svc.recordVerificationFailed();
      expect(svc.isPlus, isTrue,
          reason: 'a renewal probably landed; the phone just has no signal');
    });

    test('past expiry + attempt FAILED + beyond tolerance drops to Free',
        () async {
      final beyond = kOfflineTolerance + const Duration(hours: 1);
      await seed({'plus_expires_at_v1': msFromNow(-beyond)});
      svc.recordVerificationFailed();
      expect(svc.isPlus, isFalse);
    });

    test('an ANSWER of no-entitlement is immediate, tolerance never applies',
        () async {
      await seed({'plus_expires_at_v1': msFromNow(const Duration(hours: -2))});
      svc.recordVerificationFailed();
      expect(svc.isPlus, isTrue, reason: 'tolerance active');
      // RevenueCat now answers: nothing active.
      await svc.recordVerified(expiresAt: null, isLifetime: false);
      expect(svc.isPlus, isFalse,
          reason: 'the server answered, so there is nothing to tolerate');
    });

    test('future expiry + attempt FAILED still means Plus', () async {
      await seed({'plus_expires_at_v1': msFromNow(const Duration(days: 10))});
      svc.recordVerificationFailed();
      expect(svc.isPlus, isTrue,
          reason: 'losing signal must never revoke a paying subscriber');
    });
  });

  group('migration from the legacy bool', () {
    test('legacy true is NOT downgraded, and is marked everHeld', () async {
      await seed({'entitlement_plus_v1': true});
      expect(svc.everHeld, isTrue);
      expect(svc.isPlus, isTrue,
          reason: 'an unknown expiry must not read as expired on upgrade');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('entitlement_plus_v1'), isNull,
          reason: 'legacy key consumed once, never written again');
    });

    test('legacy false stays Free', () async {
      await seed({'entitlement_plus_v1': false});
      expect(svc.everHeld, isFalse);
      expect(svc.isPlus, isFalse);
    });

    test('a verification resolves the migrated unknown expiry', () async {
      await seed({'entitlement_plus_v1': true});
      expect(svc.isPlus, isTrue);
      // The startup verification lands and says there is no entitlement.
      await svc.recordVerified(expiresAt: null, isLifetime: false);
      expect(svc.isPlus, isFalse,
          reason: 'everHeld must not keep a migrated user Plus forever');
      expect(svc.everHeld, isFalse);
    });
  });

  group('recordVerified', () {
    test('writes an expiry that then governs isPlus', () async {
      await seed({});
      expect(svc.isPlus, isFalse);
      await svc.recordVerified(
        expiresAt: DateTime.now().add(const Duration(days: 30)),
        isLifetime: false,
      );
      expect(svc.isPlus, isTrue);
      expect(svc.everHeld, isTrue);
      expect(svc.lastVerifiedAt, isNotNull);
    });

    test('clear() wipes everything, as forget-vault requires', () async {
      await seed({});
      await svc.recordVerified(
        expiresAt: DateTime.now().add(const Duration(days: 30)),
        isLifetime: false,
      );
      expect(svc.isPlus, isTrue);
      await svc.clear();
      expect(svc.isPlus, isFalse);
      expect(svc.everHeld, isFalse);
      expect(svc.lastVerifiedAt, isNull);
    });
  });
}
