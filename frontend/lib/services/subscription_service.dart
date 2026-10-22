import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import '../src/config/billing.dart';
import '../src/config/flags.dart';
import 'billing_service.dart';
import 'cnest_errors.dart';
import 'database_service.dart';
import 'notify.dart';

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
/// Observable: the home wordmark and the Settings row listen, so a
/// verification landing after the first frame (cold start, a renewal, an
/// expiry passing) repaints them instead of leaving a stale "Free".
class SubscriptionService extends ChangeNotifier {
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
    notifyListeners();
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

  /// Cached expiry, epoch ms; null for lifetime or no entitlement.
  int? get expiresAt => _expiresAt;

  /// The Play base plan the entitlement rides on, when the SDK reported one.
  String? get currentPlanId => _planId;

  /// The store product the entitlement rides on ("plus" for the Play
  /// subscription), which a plan change must name as the product it
  /// replaces. Null when unknown.
  String? get currentProductId => _productId;

  /// Which plan the user is on, from the last verified answer.
  PlusPlan get plan {
    if (!isPlus) return PlusPlan.none;
    if (_isLifetime) return PlusPlan.lifetime;
    // Base plan ids are whatever was typed into Play Console, so match on
    // the word rather than an exact id. The paywall refines this against
    // the live offering's own identifiers.
    final hint = '${_planId ?? ''} ${_productId ?? ''}'.toLowerCase();
    if (hint.contains('month')) return PlusPlan.monthly;
    if (hint.contains('annual') || hint.contains('year')) {
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
    notifyListeners();
  }

  /// Records that a verification was ATTEMPTED and failed. Never changes the
  /// cached entitlement: losing signal must not revoke a paying subscriber
  /// whose expiry is still in the future.
  void recordVerificationFailed() {
    _lastAttemptFailed = true;
    notifyListeners();
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
    notifyListeners();
  }
}

/// Where the vault stands against the Free cap, for every surface that
/// shows or enforces it. One query, one number: [stored] counts every row
/// that holds a slot (live, pending, Recycle Bin), see
/// [DatabaseService.countStoredFiles].
class FreeTierStatus {
  const FreeTierStatus({
    required this.isPlus,
    required this.stored,
    required this.binned,
    this.limit = FreeTierGuard.freeFileLimit,
  });

  final bool isPlus;
  final int stored;
  final int binned;
  final int limit;

  /// Slots left on Free; meaningless (and huge) on Plus.
  int get remaining => isPlus ? 1 << 30 : (limit - stored).clamp(0, limit);
  bool get atLimit => !isPlus && stored >= limit;

  /// From 90% up the UI turns amber and a one-time toast fires.
  bool get nearLimit =>
      !isPlus && stored >= (limit * FreeTierGuard.warnAtPercent) ~/ 100;
  double get fraction => limit == 0 ? 0 : (stored / limit).clamp(0.0, 1.0);
}

/// The Free tier's storage cap and its single enforcement question. Every
/// upload funnel (manual UploadPipeline; auto-sync / backfill per-asset)
/// asks here. Reading, decrypting, and deleting are NEVER gated.
class FreeTierGuard {
  FreeTierGuard._();

  /// Free stores this many files; Plus is unlimited.
  static const int freeFileLimit = 1000;

  /// Percentage of the cap at which the UI starts warning.
  static const int warnAtPercent = 90;

  static const _kWarnedBucketPref = 'free_limit_warned_bucket_v1';

  /// Epoch ms of the last cap-triggered entitlement verification. See
  /// [kCapRecheckMinGap]: at the cap every skipped asset used to ask
  /// RevenueCat again.
  static int? _lastCapRefreshMs;

  @visibleForTesting
  static void resetThrottleForTest() => _lastCapRefreshMs = null;

  /// The most recent [status] answer, for screens that need a synchronous
  /// first frame (the Upload button used to flash enabled for the frame
  /// before its async status landed, every time a folder was entered).
  static FreeTierStatus? lastKnown;

  /// Snapshot for the Home card, the buttons and the limit sheet.
  static Future<FreeTierStatus> status() async {
    final sub = SubscriptionService();
    await sub.init();
    final db = DatabaseService();
    final stored = await db.countStoredFiles();
    final binned = await db.countBinnedFiles();
    final st =
        FreeTierStatus(isPlus: sub.isPlus, stored: stored, binned: binned);
    lastKnown = st;
    return st;
  }

  /// The typed error every blocked upload surfaces, with the counts the
  /// message needs. [notStored] is how many files of the batch did not fit.
  static Future<FreeLimitReachedError> limitError({int notStored = 0}) async {
    final binned = await DatabaseService().countBinnedFiles();
    return FreeLimitReachedError(binned: binned, notStored: notStored);
  }

  /// Whether [adding] more files fits the tier.
  ///
  /// Order matters, and it is chosen so the common cases cost nothing:
  ///
  ///  1. A user with a known-good, unexpired entitlement passes immediately.
  ///  2. A user comfortably under the cap passes on a local row count.
  ///  3. Only a user who is at the cap, or whose entitlement is past its
  ///     expiry, is worth a network round trip, and that round trip is
  ///     throttled to one per [kCapRecheckMinGap].
  static Future<bool> canStoreMore({int adding = 1}) async {
    final sub = SubscriptionService();
    await sub.init();

    // Entitled and not past expiry: nothing to verify, nothing to count.
    if (sub.isPlus && !sub.isPastExpiry) return true;

    // Past expiry while still inside the offline tolerance. Confirm before
    // trusting it, because this is the moment the entitlement is being USED.
    if (sub.isPastExpiry) {
      await _refreshThrottled();
      if (sub.isPlus) return true;
    }

    final count = await DatabaseService().countStoredFiles();
    if (count + adding <= freeFileLimit) return true;

    // At or over the cap while not entitled. Worth asking once per gap: the
    // user may have bought Plus on another device, redeemed a promo code in
    // the Play Store, or restored this phrase after buying elsewhere.
    await _refreshThrottled();
    return sub.isPlus;
  }

  static Future<void> _refreshThrottled() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastCapRefreshMs;
    if (last != null && now - last < kCapRecheckMinGap.inMilliseconds) return;
    _lastCapRefreshMs = now;
    await BillingService().refreshIfStale();
  }

  /// Called after a batch or sync that stored something. Toasts once when
  /// the vault crosses [warnAtPercent] and once more when it reaches the
  /// cap; falling back below resets so the next climb warns again. Never
  /// fires on Plus.
  static Future<void> warnIfNearLimit() async {
    try {
      final st = await status();
      final bucket = st.isPlus
          ? 0
          : st.atLimit
              ? 2
              : st.nearLimit
                  ? 1
                  : 0;
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kWarnedBucketPref) ?? 0;
      if (bucket == last) return;
      await prefs.setInt(_kWarnedBucketPref, bucket);
      if (bucket < last) return; // dropped back under: silent reset
      Notify.info(bucket == 2
          ? 'Free vault is full: ${fmtCount(st.limit)} of ${fmtCount(st.limit)} files'
          : '${fmtCount(st.stored)} of ${fmtCount(st.limit)} Free files used');
    } catch (_) {
      // Advisory only. Never let a warning break the flow that called it.
    }
  }

  /// "1000" -> "1,000". Tiny, locale-neutral, no intl dependency.
  static String fmtCount(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

/// Which Plus plan is active. [unknown] is Plus without a recognised plan
/// (an old cache, or a product renamed on the dashboard): still entitled,
/// but offered no plan change because the app cannot say what it would be
/// changing from.
enum PlusPlan { none, monthly, yearly, lifetime, unknown }
