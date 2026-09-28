/// App-wide constants. Centralized so things like the share host can be
/// swapped in one place without touching call sites.
class AppConstants {
  /// The Cloudflare host serving the share web viewer. Recipients open magic
  /// links pointing here. Served by the `ciphernest` Worker (worker.js +
  /// web-viewer/) on its custom domain. This base URL is baked into every share
  /// link at creation, so keep it stable. The old workers.dev host is DEAD
  /// (404 on every path since the custom domain was attached; verified
  /// 18 Sep 2026). No real user ever minted a link against it, so nothing
  /// needs to resolve there.
  static const String shareHost = 'share.ciphernest.io';

  /// Custom URL scheme used for app deep linking (OAuth callback + share open-in-app).
  static const String urlScheme = 'ciphernest';
}
