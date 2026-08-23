import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../services/activity_center.dart';
import '../services/app_lock_service.dart';
import '../services/audio_player_service.dart';
import '../services/recycle_bin_service.dart';
import '../services/share_service.dart';
import '../services/subscription_service.dart';
import '../services/video_streaming_server.dart';
import 'config/constants.dart';
import 'config/routes.dart';
import 'config/theme_controller.dart';
import 'widgets/activity_pill.dart';

class App extends StatefulWidget {
  const App({super.key});

  /// The one app-wide navigator key. Static because the activity overlay
  /// lives ABOVE the Navigator (MaterialApp builder) — its tap handlers
  /// need a context/navigator without having one below them in the tree.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WidgetsBindingObserver {
  final _themeController = ThemeController();
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _themeController.addListener(_onThemeChanged);
    // Warm the entitlement cache so Plus gates read correctly from the
    // first frame instead of flashing Free state.
    unawaited(SubscriptionService().init());
    // Activity center: notification mirror + bg-sync bridge + lifecycle.
    unawaited(ActivityCenter().init());
    _bootstrapDeepLinks();
    // Auto-lock: defers while music plays or a video streams so playback
    // never cuts mid-session.
    AppLockService().init(
      navigatorKey: App.navigatorKey,
      isPlaybackActive: () =>
          AudioPlayerService().playing ||
          VideoStreamingServer().hasActiveSessions,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _themeController.removeListener(_onThemeChanged);
    _linkSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppLockService().onResumed();
    }
  }

  @override
  void didChangePlatformBrightness() {
    // System theme mode must re-theme the moment the OS flips.
    _themeController.onPlatformBrightnessChanged(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
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
    final nav = App.navigatorKey.currentState;
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
      navigatorKey: App.navigatorKey,
      theme: _themeController.themeData,
      initialRoute: AppRoutes.splash,
      onGenerateRoute: AppRoutes.generateRoute,
      // Every pointer-down resets the auto-lock countdown, then (for
      // Hackerman) the app-wide code-rain texture is painted behind the
      // route at low opacity, and the activity overlay (progress pill +
      // toasts) floats above every route. Builder re-runs on
      // ThemeController notify — the overlay is stateless over singletons,
      // so those rebuilds are pure paint.
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();
        if (appTex != null) {
          content = Stack(
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
              content,
            ],
          );
        }
        content = Stack(
          children: [
            content,
            const ActivityOverlay(),
          ],
        );
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => AppLockService().recordActivity(),
          child: content,
        );
      },
    );
  }
}
