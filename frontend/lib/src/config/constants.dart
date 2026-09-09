/// App-wide constants. Centralized so things like the share host can be
/// swapped in one place without touching call sites.
class AppConstants {
  /// The Cloudflare host serving the share web viewer. Recipients open magic
  /// links pointing here. Served by the `ciphernest` Worker (worker.js +
  /// web-viewer/) on its custom domain. This base URL is baked into every share
  /// link at creation, so keep it stable. The old workers.dev host
  /// (ciphernest.ciphernest20.workers.dev) stays enabled on the same Worker, so
  /// links minted before this cutover still resolve.
  static const String shareHost = 'share.ciphernest.io';

  /// Custom URL scheme used for app deep linking (OAuth callback + share open-in-app).
  static const String urlScheme = 'ciphernest';
}
