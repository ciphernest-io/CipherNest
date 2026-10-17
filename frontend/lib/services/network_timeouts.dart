import 'dart:io';

/// Connection and idle timeouts for every `HttpClient` the app creates
/// (MASVS F-19).
///
/// `package:http`, the Drive API client and the share viewer's own client all
/// end up constructing a `dart:io` `HttpClient`, and `HttpOverrides.global`
/// is the one place that reaches all of them. Without it a connect to a host
/// that never answers hangs forever and the operation it belongs to never
/// completes or fails.
///
/// Only the connect and the keep-alive idle time are bounded here. A whole-
/// request deadline is wrong for the upload and download paths, where a
/// legitimate transfer on a slow link can run for minutes.
///
/// `HttpOverrides.global` is per isolate, so this is installed from both
/// `main()` and the background sync entry point.
class CipherNestHttpOverrides extends HttpOverrides {
  static const Duration connectTimeout = Duration(seconds: 20);
  static const Duration idleTimeout = Duration(seconds: 30);

  static void install() {
    HttpOverrides.global = CipherNestHttpOverrides();
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.connectionTimeout = connectTimeout;
    client.idleTimeout = idleTimeout;
    return client;
  }
}
