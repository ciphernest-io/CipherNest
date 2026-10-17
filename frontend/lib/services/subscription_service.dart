import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../src/config/billing.dart';
import '../src/config/flags.dart';
import 'billing_service.dart';
import 'database_service.dart';

/// Entitlement gate for Plus.
///
/// Plus unlocks exactly ONE thing: the stored-file cap in [FreeTierGuard].
/// Everything else is free, including every share expiry option and
/// password-protected links. Reading, decrypting, sharing and deleting are
/// never gated.
///
/// ## A deadline, not a verdict
/// This used to cache a single `bool`. A bool cannot expire, which is exactly
/// how a lapsed subscriber kept unlimited uploads indefinitely: nothing ever
/// set it false, and both paths that could have corrected it short-circuited
/// on it. Observed on device 2026-10-01 — RevenueCat reported "No current
/// entitlements" while the app still showed Plus.
///
/// So the cache now holds the **expiry instant**. [isPlus] is a pure local
/// computation over it, which means a subscription lapses the moment it is
/// due to, offline, with no network call and no trigger required. The
/// forever-free bug cannot exist in this shape.
///
/// The one thing an expiry date cannot see is a refund, chargeback or
/// payment-failure hold, all of which revoke entitlement BEFORE the date.
/// [BillingService.verifyNow] covers those at app start.
class SubscriptionService {
  static final SubscriptionService _instance = SubscriptionService._internal();
  factory SubscriptionService() => _instance;
  SubscriptionService._internal();

  /// Legacy key: a bare bool with no expiry. Read once for migration, then
  /// never written again.
  static const _legacyEntitlementKey = 'entitlement_plus_v1';

  static const _kExpiresAt = 'plus_expires_at_v1';
  static const _kIsLifetime = 'plus_is_lifetime_v1';
  static const _kLastVerifiedAt = 'plus_last_verified_at_v1';
  static const _kEverHeld = 'plus_ever_held_v1';
  // Which product the entitlement rides on, so Settings can offer the longer
  // plans and the paywall knows what it is replacing. For Play subscriptions
  // the product is the subscription id ("plus") and the plan is the base
  // plan id ("monthly" / "annual"); lifetime is a one-time product.
  static const _kProductId = 'plus_product_v1';
  static const _kPlanId = 'plus_plan_v1';

  /// Epoch ms. Entitlement is valid strictly before this. Null means either
  /// "never had one" or "had one but the expiry is not known yet" — the two
  /// are distinguished by [everHeld].
  int? _expiresAt;
  bool _isLifetime = false;
  int? _lastVerifiedAt;
  bool _everHeld = false;
  String? _productId;
  String? _planId;

  /// True when the most recent verification ATTEMPT failed (network, auth,
  /// SDK not configurable). Session-only on purpose: a fresh process should
  /// try again rather than inherit a stale pessimism.
  bool _lastAttemptFailed = false;

  bool _loaded = false;

  /// Loads the cached entitlement, migrating the legacy bool on first run.
  /// Idempotent; call before any synchronous [isPlus] read.
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();

    _expiresAt = prefs.getInt(_kExpiresAt);
    _isLifetime = prefs.getBool(_kIsLifetime) ?? false;
    _lastVerifiedAt = prefs.getInt(_kLastVerifiedAt);
    _everHeld = prefs.getBool(_kEverHeld) ?? false;
    _productId = prefs.getString(_kProductId);
    _planId = prefs.getString(_kPlanId);

    // MIGRATION. An install from before this change holds `true` with no
    // expiry. Reading "no expiry" as "expired" would downgrade a paying
    // subscriber the instant they updated, so it is read as "entitled,
    // expiry unknown": everHeld is set, expiry stays null, and the next
    // verification resolves it to the truth. Never revoke first and ask
    // later.
    if (!_everHeld && (prefs.getBool(_legacyEntitlementKey) ?? false)) {
      _everHeld = true;
      await prefs.setBool(_kEverHeld, true);
      await prefs.remove(_legacyEntitlementKey);
    }

    _loaded = true;
  }

  /// Whether Plus is unlocked, computed locally with no network.
  ///
  /// With the paywall disabled there is no upgrade path at all, so nothing is
  /// gated and the app behaves as fully unlocked rather than permanently Free.
  bool get isPlus {
    if (!kPaywallEnabled) return true;
    if (_isLifetime) return true;

    final expiry = _expiresAt;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Expiry not known yet, but an entitlement was held: the migration case,
    // or a restore whose verification has not landed. Trust it until a
    // verification says otherwise, for the same reason as the migration.
    if (expiry == null) return _everHeld;

    if (now < expiry) return true;

    // Past expiry. If RevenueCat ANSWERED and said inactive, the write path
    // cleared the expiry, so we are not here. Reaching this point with a past
    // expiry means we could not confirm a renewal, so hold briefly rather
    // than downgrade someone whose renewal probably went through while they
    // had no signal. Play's own grace period covers genuine payment failure.
    if (_lastAttemptFailed &&
        now < expiry + kOfflineTolerance.inMilliseconds) {
      return true;
    }
    return false;
  }

  /// True once an entitlement has ever been observed on this vault. Kept for
  /// the migration path above and for diagnostics; it gates nothing.
  bool get everHeld => _everHeld;

  /// True when [isPlus] is currently relying on the offline tolerance rather
  /// than a known-good expiry. Useful for diagnostics and for deciding that a
  /// verification is worth attempting.
  bool get isPastExpiry {
    if (_isLifetime) return false;
    final expiry = _expiresAt;
    if (expiry == null) return false;
    return DateTime.now().millisecondsSinceEpoch >= expiry;
  }

  int? get lastVerifiedAt => _lastVerifiedAt;

  bool get isLifetime => _isLifetime;

  /// The store product the entitlement rides on ("plus" for the Play
  /// subscription), which a plan change must name as the product it
  /// replaces. Null when unknown.
  String? get currentProductId => _productId;

  /// Which plan the user is on, from the last verified answer.
  PlusPlan get plan {
    if (!isPlus) return PlusPlan.none;
    if (_isLifetime) return PlusPlan.lifetime;
    final plan = _planId ?? '';
    final product = _productId ?? '';
    if (plan == 'monthly' || product.endsWith(':monthly')) {
      return PlusPlan.monthly;
    }
    if (plan == 'annual' || product.endsWith(':annual')) {
      return PlusPlan.yearly;
    }
    return PlusPlan.unknown;
  }

  /// Records a SUCCESSFUL answer from RevenueCat.
  ///
  /// [expiresAt] null together with [isLifetime] false means no entitlement:
  /// the user is Free immediately, with no tolerance window, because the
  /// server actually answered.
  Future<void> recordVerified({
    required DateTime? expiresAt,
    required bool isLifetime,
    String? productId,
    String? planId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().millisecondsSinceEpoch;

    _isLifetime = isLifetime;
    _expiresAt = expiresAt?.millisecondsSinceEpoch;
    _productId = productId;
    _planId = planId;
    if (productId == null) {
      await prefs.remove(_kProductId);
    } else {
      await prefs.setString(_kProductId, productId);
    }
    if (planId == null) {
      await prefs.remove(_kPlanId);
    } else {
      await prefs.setString(_kPlanId, planId);
    }
    _lastVerifiedAt = now;
    _lastAttemptFailed = false;
    if (isLifetime || expiresAt != null) _everHeld = true;

    await prefs.setBool(_kIsLifetime, _isLifetime);
    if (_expiresAt == null) {
      await prefs.remove(_kExpiresAt);
    } else {
      await prefs.setInt(_kExpiresAt, _expiresAt!);
    }
    await prefs.setInt(_kLastVerifiedAt, now);
    await prefs.setBool(_kEverHeld, _everHeld);

    // A definitive "no entitlement" must also clear the unknown-expiry
    // trust from the migration path, or a migrated user would stay Plus
    // forever on the strength of everHeld alone.
    if (!isLifetime && expiresAt == null) {
      _everHeld = false;
      await prefs.setBool(_kEverHeld, false);
    }

    _loaded = true;
  }

  /// Records that a verification was ATTEMPTED and failed. Never changes the
  /// cached entitlement: losing signal must not revoke a paying subscriber
  /// whose expiry is still in the future.
  void recordVerificationFailed() {
    _lastAttemptFailed = true;
  }

  /// Drops the in-memory copy so the next [init] re-reads storage. Tests
  /// only: production never needs to reload, and [clear] deliberately leaves
  /// the state loaded because after a wipe it IS known.
  @visibleForTesting
  void resetForTest() {
    _expiresAt = null;
    _isLifetime = false;
    _lastVerifiedAt = null;
    _everHeld = false;
    _lastAttemptFailed = false;
    _loaded = false;
  }

  /// Forget-vault teardown. A different recovery phrase is a different
  /// customer, so none of this may carry over.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [
      _kExpiresAt,
      _kIsLifetime,
      _kLastVerifiedAt,
      _kEverHeld,
      _kProductId,
      _kPlanId,
      _legacyEntitlementKey,
    ]) {
      await prefs.remove(k);
    }
    _expiresAt = null;
    _isLifetime = false;
    _lastVerifiedAt = null;
    _everHeld = false;
    _productId = null;
    _planId = null;
    _lastAttemptFailed = false;
    _loaded = true;
  }
}

/// The Free tier's storage cap and its single enforcement question. Both
/// upload funnels (manual UploadPipeline; auto-sync / migration per-asset)
/// ask here. Reading, decrypting, and deleting are NEVER gated.
class FreeTierGuard {
  FreeTierGuard._();

  /// Free stores this many files; Plus is unlimited.
  static const int freeFileLimit = 1000;

  /// Whether [adding] more files fits the tier.
  ///
  /// Order matters, and it is chosen so the common cases cost nothing:
  ///
  ///  1. A user with a known-good, unexpired entitlement passes immediately.
  ///  2. A user comfortably under the cap passes on a local row count.
  ///  3. Only a user who is at the cap, or whose entitlement is past its
  ///     expiry, is worth a network round trip.
  ///
  /// Step 3 used to be unreachable: this method began with an unconditional
  /// `if (isPlus) return true`, so a cached entitlement was never re-checked
  /// here no matter how stale.
  static Future<bool> canStoreMore({int adding = 1}) async {
    final sub = SubscriptionService();
    await sub.init();

    // Entitled and not past expiry: nothing to verify, nothing to count.
    if (sub.isPlus && !sub.isPastExpiry) return true;

    // Past expiry while still inside the offline tolerance. Confirm before
    // trusting it, because this is the moment the entitlement is being USED.
    if (sub.isPastExpiry) {
      await BillingService().refreshIfStale();
      if (sub.isPlus) return true;
    }

    final count = await DatabaseService().countActiveFiles();
    if (count + adding <= freeFileLimit) return true;

    // At or over the cap while not entitled. Worth asking: the user may have
    // bought Plus on another device, redeemed a promo code in the Play Store,
    // or restored this phrase after buying elsewhere.
    await BillingService().refreshIfStale();
    return sub.isPlus;
  }
}

/// Which Plus plan is active. [unknown] is Plus without a recognised plan
/// (an old cache, or a product renamed on the dashboard): still entitled,
/// but offered no plan change because the app cannot say what it would be
/// changing from.
enum PlusPlan { none, monthly, yearly, lifetime, unknown }
