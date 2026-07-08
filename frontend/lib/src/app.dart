import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../services/recycle_bin_service.dart';
import '../services/share_service.dart';
import 'config/constants.dart';
import 'config/routes.dart';
import 'config/theme_controller.dart';

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final _themeController = ThemeController();
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    _themeController.addListener(_onThemeChanged);
    _bootstrapDeepLinks();
  }

  @override
  void dispose() {
    _themeController.removeListener(_onThemeChanged);
    _linkSub?.cancel();
    super.dispose();
  }

  void _onThemeChanged() {
    setState(() {});
  }

  /// Wires both cold-start (`getInitialLink`) and warm (`uriLinkStream`)
  /// inbound links into [_handleIncomingUri]. Only links that look like share
  /// magic links are routed; everything else (e.g. OAuth callbacks handled by
  /// flutter_web_auth_2) is ignored.
  Future<void> _bootstrapDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _handleIncomingUri(initial, isColdStart: true);
    } catch (e) {
      debugPrint('App: getInitialLink failed: $e');
    }
    _linkSub = _appLinks.uriLinkStream.listen(
      (uri) => _handleIncomingUri(uri, isColdStart: false),
      onError: (Object e) => debugPrint('App: uriLinkStream error: $e'),
    );
    // Fire-and-forget: purge soft-deleted rows whose 30-day TTL has lapsed.
    // Runs after the deep-link listener is up so it never blocks an incoming
    // share. The DB query is account-scoped and falls through quickly when
    // no account has been bound yet.
    unawaited(RecycleBinService().sweepRecycleBin());
    // Same cadence for expired shares — revokes the cloud blob and removes
    // the local row for anything past its `expires_at`. Without this call
    // expired shares linger indefinitely on Drive/OneDrive and clutter the
    // Active Shares screen with dead rows.
    unawaited(ShareService().sweepExpired());
  }

  void _handleIncomingUri(Uri uri, {required bool isColdStart}) {
    if (!_isShareUri(uri)) return;
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    if (isColdStart) {
      // Cold start: replace the splash entirely so its deferred
      // pushReplacementNamed can't clobber the shared viewer.
      nav.pushNamedAndRemoveUntil(
        AppRoutes.sharedViewer,
        (_) => false,
        arguments: uri,
      );
    } else {
      // Warm receive (user already in the app): push on top so back
      // returns them to whatever screen they were on.
      nav.pushNamed(AppRoutes.sharedViewer, arguments: uri);
    }
  }

  bool _isShareUri(Uri uri) {
    // App Link form: https://<shareHost>/s/<encoded>#...
    if (uri.scheme == 'https' &&
        uri.host == AppConstants.shareHost &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments[0] == 's') {
      return true;
    }
    // Custom scheme form: ciphernest://share/<encoded>#...
    if (uri.scheme == AppConstants.urlScheme && uri.host == 'share') {
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _themeController.tokens;
    final appTex = tokens.appTexAsset;
    return MaterialApp(
      title: 'CipherNest',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: _themeController.themeData,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.generateRoute,
      // App-wide texture (currently only Hackerman's code-rain). Painted
      // behind every route, beneath route content, at low opacity so screens
      // remain legible. Builder runs once per route push and re-runs when
      // ThemeController notifies, so switching themes swaps the texture.
      builder: appTex == null
          ? null
          : (context, child) => Stack(
                children: [
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.35,
                      child: Image.asset(
                        appTex,
                        fit: BoxFit.cover,
                        repeat: ImageRepeat.repeat,
                      ),
                    ),
                  ),
                  if (child != null) child,
                ],
              ),
    );
  }
}
