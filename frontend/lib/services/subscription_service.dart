import 'package:shared_preferences/shared_preferences.dart';

import '../src/config/flags.dart';
import 'database_service.dart';

/// Entitlement gate for Plus features (custom share expiry, password shares,
/// auto-sync, in-app editor, recycle bin, multi-cloud, extra viewer actions).
///
/// v1.0 pre-billing stub: `isPlus` reads a locally cached entitlement flag.
/// The RevenueCat integration replaces the write path with real entitlement
/// sync (`Purchases.logIn(billingIdentity)` + listener) — every `isPlus`
/// call site stays unchanged.
class SubscriptionService {
  static final SubscriptionService _instance = SubscriptionService._internal();
  factory SubscriptionService() => _instance;
  SubscriptionService._internal();

  static const _entitlementKey = 'entitlement_plus_v1';

  bool _plusCached = false;
  bool _loaded = false;

  /// Loads the cached entitlement. Idempotent; call once at startup so
  /// synchronous [isPlus] reads are accurate from the first frame.
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _plusCached = prefs.getBool(_entitlementKey) ?? false;
    _loaded = true;
  }

  /// Whether Plus features are unlocked.
  ///
  /// With the paywall disabled there is no upgrade path, so nothing is gated
  /// — the app behaves as fully unlocked rather than permanently Free.
  bool get isPlus => !kPaywallEnabled || _plusCached;

  /// Caches an entitlement locally. Only the billing flow should call this;
  /// it exists now so the purchase path has a seam to write through later.
  Future<void> setPlusEntitlement(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_entitlementKey, value);
    _plusCached = value;
    _loaded = true;
  }
}

/// The Free tier's storage cap and its single enforcement question. Both
/// upload funnels (manual UploadPipeline; auto-sync / migration per-asset)
/// ask here, so the payments project only ever swaps the entitlement
/// source. Reading, decrypting, and deleting are NEVER gated.
class FreeTierGuard {
  FreeTierGuard._();

  /// D-P1 groundwork: Free stores this many files; Plus is unlimited.
  static const int freeFileLimit = 1000;

  /// Whether [adding] more files fits the tier. Counts every live row in
  /// the vault (all accounts, pending included; recycled rows freed).
  static Future<bool> canStoreMore({int adding = 1}) async {
    await SubscriptionService().init();
    if (SubscriptionService().isPlus) return true;
    final count = await DatabaseService().countActiveFiles();
    return count + adding <= freeFileLimit;
  }
}
