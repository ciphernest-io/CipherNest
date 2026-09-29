import 'dart:async';

import 'package:purchases_flutter/purchases_flutter.dart';

import '../src/config/billing.dart';
import '../src/config/flags.dart';
import 'key_manager_service.dart';
import 'subscription_service.dart';

/// RevenueCat client, deliberately lazy.
///
/// ## The contact rule
/// RevenueCat is contacted on exactly four occasions:
///
///   1. the paywall screen opens (to read live prices),
///   2. a purchase,
///   3. a restore,
///   4. a [FreeTierGuard] cap hit by a user the local cache thinks is Free.
///
/// **Never at app start, and never on a launch that touches none of those.**
/// The App User ID is derived from the vault seed, so an app-start call would
/// report a stable, seed-derived identifier to a third party on every single
/// launch, which for a vault app leaks a log of when the vault is opened.
///
/// ## Configure once, with the ID
/// [Purchases.configure] is called with `appUserID` already set. Configuring
/// without it mints an anonymous `$RCAnonymousID`, calls home as that identity,
/// and a later [Purchases.logIn] creates a server-side alias linking the two —
/// two identities per install and an extra network request. So: configure with
/// the real ID, or do not configure.
///
/// ## Locked vaults never configure
/// [KeyManagerService.billingId] is null while locked because the seed is never
/// retained. Background auto-sync and migration run in that state, so they fall
/// back to the locally cached entitlement and make no request. This is load
/// bearing, not an edge case.
///
/// ## collectDeviceIdentifiers is never called
/// Calling it acquires the advertising ID, which requires the `AD_ID`
/// permission and changes the Play Data Safety declaration's category. The
/// shipped APK has no such permission and must keep it that way.
class BillingService {
  static final BillingService _instance = BillingService._internal();
  factory BillingService() => _instance;
  BillingService._internal();

  bool _configured = false;

  /// Shared in-flight refresh. Concurrent callers await this one request
  /// rather than each firing their own.
  Future<void>? _inFlight;

  /// When the last successful refresh completed. Throttles the cap-hit path,
  /// which is reached per-asset by auto-sync and migration.
  DateTime? _lastRefresh;
  static const Duration _minRefreshGap = Duration(minutes: 5);

  /// True once the SDK holds a real key and a real App User ID.
  bool get isConfigured => _configured;

  /// Configures the SDK exactly once, or reports why it cannot.
  ///
  /// Returns false, without any network activity, when the paywall is off,
  /// the public key has not been set yet, or the vault is locked.
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
    return true;
  }

  /// Reads entitlement state and writes it through to the local cache.
  ///
  /// Silent on failure: a network error must never present as "your
  /// subscription expired". The cached value stands until a call succeeds.
  Future<void> refreshEntitlement() async {
    final existing = _inFlight;
    if (existing != null) return existing;
    final run = _refresh();
    _inFlight = run;
    try {
      await run;
    } finally {
      _inFlight = null;
    }
  }

  Future<void> _refresh() async {
    if (!await ensureConfigured()) return;
    try {
      final info = await Purchases.getCustomerInfo();
      await _writeThrough(info);
    } catch (_) {
      // Keep the cached entitlement. Never downgrade a paying user because
      // their train went into a tunnel.
    }
  }

  /// Refresh, but only if it is worth a request. Used by the cap-hit path.
  ///
  /// Skips when the cache already says Plus, when a refresh happened recently,
  /// or when the SDK cannot be configured at all.
  Future<void> refreshIfStale() async {
    if (SubscriptionService().isPlus) return;
    final last = _lastRefresh;
    if (last != null && DateTime.now().difference(last) < _minRefreshGap) {
      return;
    }
    if (KeyManagerService().billingId == null) return;
    await refreshEntitlement();
  }

  /// Live offerings for the paywall, so prices are editable from the dashboard
  /// without an app update. Null when the SDK is not configured; the caller
  /// shows its fallback copy rather than an error.
  Future<Offerings?> offerings() async {
    if (!await ensureConfigured()) return null;
    try {
      return await Purchases.getOfferings();
    } catch (_) {
      return null;
    }
  }

  /// Buys [package]. Returns true when the Plus entitlement is active
  /// afterwards. Throws [PlatformException] upward so the caller can tell a
  /// user cancellation apart from a real failure.
  Future<bool> purchase(Package package) async {
    if (!await ensureConfigured()) return false;
    final info = await Purchases.purchasePackage(package);
    await _writeThrough(info);
    return _isActive(info);
  }

  /// Restores purchases already attached to this App User ID. Because the ID
  /// is derived from the recovery phrase, this is what makes a subscription
  /// follow the phrase onto a new device.
  Future<bool> restore() async {
    if (!await ensureConfigured()) return false;
    final info = await Purchases.restorePurchases();
    await _writeThrough(info);
    return _isActive(info);
  }

  /// Forget-vault teardown.
  ///
  /// Deliberately does NOT call [Purchases.logOut]: that makes a network
  /// request and mints a fresh anonymous identity, which would be a fifth
  /// contact point outside the four allowed above. The SDK identity dies with
  /// the process, and the next vault configures with its own derived ID.
  Future<void> forgetVault() async {
    _configured = false;
    _lastRefresh = null;
    await SubscriptionService().setPlusEntitlement(false);
  }

  bool _isActive(CustomerInfo info) =>
      info.entitlements.active.containsKey(kPlusEntitlementId);

  Future<void> _writeThrough(CustomerInfo info) async {
    _lastRefresh = DateTime.now();
    await SubscriptionService().setPlusEntitlement(_isActive(info));
  }
}
