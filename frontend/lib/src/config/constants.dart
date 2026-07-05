/// App-wide constants. Centralized so things like the share host can be
/// swapped in one place without touching call sites.
class AppConstants {
  /// The Cloudflare host serving the share web viewer. Recipients open magic
  /// links pointing here. Deployed as a Workers-with-static-assets project
  /// (Cloudflare killed the standalone Pages create flow in 2026, so new
  /// projects live under `<name>.<subdomain>.workers.dev`). If you migrate
  /// to a custom domain later, set up a 302 redirect from the old host so
  /// previously-issued links keep working.
  static const String shareHost = 'ciphernest.ciphernest20.workers.dev';

  /// Custom URL scheme used for app deep linking (OAuth callback + share open-in-app).
  static const String urlScheme = 'ciphernest';
}
