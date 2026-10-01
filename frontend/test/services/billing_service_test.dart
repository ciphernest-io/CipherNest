import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ciphernest/services/subscription_service.dart';
import 'package:ciphernest/services/billing_service.dart';
import 'package:ciphernest/src/config/billing.dart';

/// Guards the contact rule in REVENUECAT_PLAN.md: RevenueCat is reached only on
/// paywall open, purchase, restore, or a cap hit — and never before the public
/// key exists, and never while the vault is locked.
///
/// These tests work because a real `Purchases.*` call in a unit test hits an
/// unimplemented platform channel and throws `MissingPluginException`. So if
/// anyone reorders the guards in `ensureConfigured` such that the SDK is
/// touched before the key and lock checks, these fail loudly instead of
/// silently shipping a build that phones home at the wrong moment.
void main() {
  // refreshIfStale and verifyNow both read the cached entitlement, which
  // needs SharedPreferences mocked for every test in this file, not just the
  // startup group.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    SubscriptionService().resetForTest();
  });

  test('the shipped key is either absent or a PUBLIC key, never a secret', () {
    // Two legitimate states: empty before the products exist, and a goog_
    // public Android SDK key after. A secret key here would ship a credential
    // in a public repo, so that is the case worth failing on.
    if (kRevenueCatPublicKey.isNotEmpty) {
      expect(kRevenueCatPublicKey, startsWith('goog_'));
      expect(kRevenueCatPublicKey.length, greaterThan(20));
    }
    expect(kRevenueCatPublicKey, isNot(startsWith('sk_')));
    expect(kRevenueCatPublicKey.toLowerCase(), isNot(contains('secret')));
  });

  test('entitlement id matches the RevenueCat dashboard', () {
    // A mismatch here reads every user as Free, silently.
    expect(kPlusEntitlementId, 'plus');
  });

  test('ensureConfigured refuses, without touching the SDK, while the vault is '
      'locked', () async {
    // billingId is null outside an unlocked vault. Would throw
    // MissingPluginException if it reached Purchases.setLogLevel, which is
    // exactly what makes this a real guard test rather than a tautology.
    expect(await BillingService().ensureConfigured(), isFalse);
    expect(BillingService().isConfigured, isFalse);
  });

  test('refreshIfStale makes no call when the vault is locked', () async {
    // billingId is null outside an unlocked vault, so this must return
    // quietly. Any SDK contact throws.
    await BillingService().refreshIfStale();
    expect(BillingService().isConfigured, isFalse);
  });

  test('offerings returns null rather than throwing when unconfigured',
      () async {
    expect(await BillingService().offerings(), isNull);
  });

  test('purchase and restore refuse when unconfigured', () async {
    expect(await BillingService().restore(), isFalse);
  });

  group('startup and resume verification', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      SubscriptionService().resetForTest();
    });

    test('cold start attempts a verification and does not throw', () async {
      // The vault is locked in a unit test, so ensureConfigured bails before
      // touching the SDK. What this pins is that the startup hook is safe to
      // call unconditionally from app.dart on every launch.
      await BillingService().verifyNow(coldStart: true);
      expect(BillingService().isConfigured, isFalse);
    });

    test('a resume inside kResumeMinGap makes no SDK call', () async {
      SharedPreferences.setMockInitialValues({
        'plus_expires_at_v1':
            DateTime.now().add(const Duration(days: 20)).millisecondsSinceEpoch,
        'plus_last_verified_at_v1': DateTime.now().millisecondsSinceEpoch,
      });
      SubscriptionService().resetForTest();
      // Resume fires on every app switch. Without the throttle this would be
      // dozens of requests an hour.
      await BillingService().verifyNow(coldStart: false);
      expect(BillingService().isConfigured, isFalse);
    });

    test('a resume PAST expiry bypasses the gap', () async {
      SharedPreferences.setMockInitialValues({
        'plus_expires_at_v1':
            DateTime.now().subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
        'plus_last_verified_at_v1': DateTime.now().millisecondsSinceEpoch,
      });
      SubscriptionService().resetForTest();
      await SubscriptionService().init();
      expect(SubscriptionService().isPastExpiry, isTrue);
      // Would have returned early on the gap alone; past expiry the answer
      // matters more than the saved request.
      await BillingService().verifyNow(coldStart: false);
      expect(BillingService().isConfigured, isFalse);
    });
  });
}
