import 'dart:async';

import 'package:purchases_flutter/purchases_flutter.dart';

import '../src/config/billing.dart';
import '../src/config/flags.dart';
import 'key_manager_service.dart';
import 'subscription_service.dart';

/// RevenueCat client.
///
/// ## When RevenueCat is contacted
///
///   1. **cold start** — always,
///   2. **resume** — only past [kResumeMinGap], or if the entitlement is past
///      its expiry,
///   3. paywall open,
///   4. purchase,
///   5. restore,
///   6. a [FreeTierGuard] cap hit, or a cap check by someone past expiry.
///
/// ## Why app start is on that list
/// An earlier revision of this file promised RevenueCat was "never contacted
/// at app start", on the grounds that the App User ID is derived from the
/// vault seed, so contact reports when someone opens their vault.
///
/// That rule was **withdrawn on 2026-10-01**, deliberately. Two reasons.
/// Onboarding already routes every user through the paywall, so RevenueCat
/// holds every user's ID and first-seen timestamp before they reach the
/// gallery; the rule was protecting app-open timing only. And it left real
/// purchase routes undetected: a promo code redeemed in the Play Store, or a
/// pending cash or carrier payment completing hours later, are both a user's
/// FIRST entitlement arriving while the app is closed. Nothing short of a
/// startup check sees those.
///
/// The Play Data Safety declaration says so: the pseudonymous ID is sent at
/// every app start, for every user.
///
/// ## Configure once, with the ID
/// [Purchases.configure] is called with `appUserID` already set. Configuring
/// without it mints an anonymous `$RCAnonymousID`, calls home as that, and a
/// later [Purchases.logIn] creates a server-side alias linking the two — two
/// identities per install and an extra request.
///
/// ## Locked vaults never configure
/// [KeyManagerService.billingId] is null while locked, because the seed is
/// never retained. Background auto-sync and migration run in that state and
/// fall back to the cached entitlement, which is now a local expiry check and
/// so is still correct. This is load bearing, not an edge case.
///
/// ## collectDeviceIdentifiers is never called
/// It would acquire the advertising ID, which requires the `AD_ID` permission
/// and changes the Data Safety declaration's category. The shipped APK has no
/// such permission and must keep it that way.
class BillingService {
  static final BillingService _instance = BillingService._internal();
  factory BillingService() => _instance;
  BillingService._internal();

  bool _configured = false;
  bool _listenerAttached = false;

  /// Shared in-flight verification. Concurrent callers await this one request
  /// rather than each firing their own.
  Future<void>? _inFlight;

  /// Fires just after the cached expiry while the app is open, so a renewal
  /// (or a lapse) is confirmed at the moment it matters instead of at the
  /// next resume. Without this the wordmark dropped "Plus" at expiry and
  /// only came back once something else asked RevenueCat. Very visible on
  /// license-tester subscriptions, which renew every five minutes.
  Timer? _expiryTimer;

  void _scheduleExpiryCheck() {
    _expiryTimer?.cancel();
    final sub = SubscriptionService();
    final at = sub.expiresAt;
    if (at == null || sub.isLifetime) return;
    var wait = Duration(milliseconds: at - DateTime.now().millisecondsSinceEpoch) +
        const Duration(seconds: 5);
    if (wait.isNegative) return; // already past: the callers verify now
    // Long timers are re-armed in steps rather than trusted for a month.
    const step = Duration(hours: 12);
    if (wait > step) wait = step;
    _expiryTimer = Timer(wait, () {
      if (SubscriptionService().isPastExpiry) {
        unawaited(verifyNow(coldStart: false));
      } else {
        _scheduleExpiryCheck();
      }
    });
  }

  bool get isConfigured => _configured;

  /// Configures the SDK exactly once, or reports why it cannot.
  ///
  /// Returns false, with no network activity, when the paywall is off, the
  /// public key has not been set, or the vault is locked.
  Future<bool> ensureConfigured() async {
    if (_configured) return true;
    if (!kPaywallEnabled) return false;
    if (kRevenueCatPublicKey.isEmpty) return false;

    final appUserId = KeyManagerService().billingId;
    if (appUserId == null) return false; // locked: never configure

    await Purchases.setLogLevel(LogLevel.error);
    await Purchases.configure(
      PurchasesConfiguration(kRevenueCatPublicKey)..appUserID = appUserId,
    );
    _configured = true;

    // In-session push updates: a renewal landing, or a purchase completing on
    // another surface, reaches the cache without another explicit call. This
    // is what makes the resume throttle safe to have.
    if (!_listenerAttached) {
      Purchases.addCustomerInfoUpdateListener(_onCustomerInfo);
      _listenerAttached = true;
    }
    return true;
  }

  void _onCustomerInfo(CustomerInfo info) {
    // Fire and forget: the listener signature is synchronous.
    unawaited(_writeThrough(info));
  }

  /// Verifies entitlement against RevenueCat.
  ///
  /// [coldStart] true always verifies. On resume it honours [kResumeMinGap],
  /// unless the entitlement is past its expiry, in which case the answer
  /// matters more than the saved request.
  Future<void> verifyNow({required bool coldStart}) async {
    final sub = SubscriptionService();
    await sub.init();
    _scheduleExpiryCheck();

    if (!coldStart && !sub.isPastExpiry) {
      final last = sub.lastVerifiedAt;
      if (last != null &&
          DateTime.now().millisecondsSinceEpoch - last <
              kResumeMinGap.inMilliseconds) {
        return;
      }
    }
    await _verify(authoritative: true);
  }

  /// Verifies when it is worth a request: not entitled, or entitled but past
  /// expiry. Used by the cap path, which auto-sync and migration reach once
  /// per asset, so the shared in-flight future matters here.
  Future<void> refreshIfStale() async {
    final sub = SubscriptionService();
    await sub.init();
    if (sub.isPlus && !sub.isPastExpiry) return;
    if (KeyManagerService().billingId == null) return;
    await _verify(authoritative: sub.isPastExpiry);
  }

  /// Plain refresh, for the paywall, purchase and restore paths.
  Future<void> refreshEntitlement() => _verify(authoritative: false);

  Future<void> _verify({required bool authoritative}) async {
    final existing = _inFlight;
    if (existing != null) return existing;
    final run = _verifyImpl(authoritative: authoritative);
    _inFlight = run;
    try {
      await run;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _verifyImpl({required bool authoritative}) async {
    if (!await ensureConfigured()) {
      // Not a failure to record when the vault is simply locked or billing is
      // switched off: there was nothing to verify against.
      return;
    }
    try {
      if (authoritative) {
        // The SDK will otherwise answer from its own cache, which is exactly
        // what we are trying to look past at app start and at expiry.
        await Purchases.invalidateCustomerInfoCache();
      }
      final info = await Purchases.getCustomerInfo();
      await _writeThrough(info);
    } catch (_) {
      // Keep the cached entitlement. A tunnel must never present as "your
      // subscription expired".
      SubscriptionService().recordVerificationFailed();
    }
  }

  /// Live offerings for the paywall, so prices are editable from the
  /// dashboard without an app update. Null when the SDK is not configured;
  /// the caller shows its fallback rather than an error.
  Future<Offerings?> offerings() async {
    if (!await ensureConfigured()) return null;
    try {
      return await Purchases.getOfferings();
    } catch (_) {
      return null;
    }
  }

  /// Buys [package]. Returns true when Plus is active afterwards. Throws
  /// [PlatformException] upward so the caller can tell a user cancellation
  /// apart from a real failure.
  ///
  /// [change] names the subscription being replaced and how, for a plan
  /// change within the same Play subscription (monthly to yearly). Null for
  /// a fresh purchase and for the lifetime product, which is a separate
  /// one-time purchase that Play cannot "replace" a subscription with.
  Future<bool> purchase(Package package,
      {StoreProductChangeInfo? change}) async {
    if (!await ensureConfigured()) return false;
    final result = await Purchases.purchase(
        PurchaseParams.package(package, productChangeInfo: change));
    await _writeThrough(result.customerInfo);
    return SubscriptionService().isPlus;
  }

  /// Restores purchases attached to this App User ID, and reconciles Play's
  /// on-device purchase list. Because the ID derives from the recovery
  /// phrase, this is what carries a subscription onto a new device. It is
  /// also the backstop if a Real-Time Developer Notification is ever missed.
  Future<bool> restore() async {
    if (!await ensureConfigured()) return false;
    final info = await Purchases.restorePurchases();
    await _writeThrough(info);
    return SubscriptionService().isPlus;
  }

  /// Play's subscription-management page for this user, or null when the SDK
  /// cannot say. Used after a lifetime purchase, so the subscription it
  /// supersedes can be cancelled where Play keeps it.
  Future<String?> managementUrl() async {
    if (!await ensureConfigured()) return null;
    try {
      return (await Purchases.getCustomerInfo()).managementURL;
    } catch (_) {
      return null;
    }
  }

  /// Forget-vault teardown.
  ///
  /// Deliberately does NOT call [Purchases.logOut]: that makes a network
  /// request and mints a fresh anonymous identity. The SDK identity dies with
  /// the process, and the next vault configures with its own derived ID.
  Future<void> forgetVault() async {
    _configured = false;
    await SubscriptionService().clear();
  }

  /// Translates a [CustomerInfo] into the cached deadline.
  ///
  /// `expirationDate` is null for the non-subscription lifetime product, so
  /// "active with no expiry" means lifetime. An absent entitlement is a
  /// definitive Free, recorded as a successful verification so no tolerance
  /// window applies.
  Future<void> _writeThrough(CustomerInfo info) async {
    final ent = info.entitlements.active[kPlusEntitlementId];
    if (ent == null) {
      await SubscriptionService()
          .recordVerified(expiresAt: null, isLifetime: false);
      return;
    }
    final raw = ent.expirationDate;
    final expires = raw == null ? null : DateTime.tryParse(raw);
    await SubscriptionService().recordVerified(
      expiresAt: expires,
      isLifetime: raw == null,
      productId: ent.productIdentifier,
      planId: ent.productPlanIdentifier,
    );
    _scheduleExpiryCheck();
  }
}
