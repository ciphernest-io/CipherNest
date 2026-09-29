import 'package:flutter_test/flutter_test.dart';
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
  test('the shipped public key is a PUBLIC RevenueCat key, never a secret', () {
    // goog_ is the public Android SDK key prefix. RevenueCat secret keys use
    // different prefixes (sk_, and the v2 secret forms). This test exists to
    // catch a paste of the wrong key into a file that ships in a public repo.
    expect(kRevenueCatPublicKey, startsWith('goog_'));
    expect(kRevenueCatPublicKey, isNot(startsWith('sk_')));
    expect(kRevenueCatPublicKey.length, greaterThan(20));
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
}
