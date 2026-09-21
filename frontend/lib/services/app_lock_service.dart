import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/config/routes.dart';
import 'audio_player_service.dart';
import 'cache_manager_service.dart';
import 'key_manager_service.dart';
import 'thumb_store.dart';
import 'video_streaming_server.dart';

/// Auto-lock: zeroes the vault private key after a period of inactivity and
/// routes to the login screen. Encryption keeps working after a lock (the
/// public key stays resident), so background sync is unaffected — only
/// decryption/viewing is gated behind re-unlock.
///
/// Playback defer: while music is playing or a video is streaming, the lock
/// is postponed so media never cuts out mid-session. This is an explicit
/// trade — an active stream keeps the private key in memory for on-demand
/// chunk decryption, and the threat model documents it.
///
/// The timer alone can't measure time while the OS suspends the app, so on
/// resume we also compare wall-clock against the last activity timestamp and
/// lock immediately if the window already elapsed.
class AppLockService {
  static final AppLockService _instance = AppLockService._();
  factory AppLockService() => _instance;
  AppLockService._();

  /// Minutes of inactivity before locking. 0 = never (disabled).
  static const String prefsKeyMinutes = 'auto_lock_minutes';
  static const int defaultMinutes = 5;

  /// Opt-in: leave media playing, and the process alive, after the vault
  /// closes or the app is swiped out of recents.
  ///
  /// Off by default, because the safe reading of "I closed the app" is that
  /// the vault closed with it. When on, locking leaves playback running and
  /// the native [TaskExitService] leaves the process alone on a swipe-away.
  ///
  /// The key is duplicated in TaskExitService.kt, which reads it straight out
  /// of Flutter's preferences file. Renaming it here means renaming it there.
  static const String prefsKeyKeepPlaying = 'keep_playing_on_close_v1';

  Timer? _timer;
  Duration _timeout = const Duration(minutes: defaultMinutes);
  DateTime _lastActivity = DateTime.now();
  GlobalKey<NavigatorState>? _navKey;
  bool Function()? _isPlaybackActive;

  int get timeoutMinutes => _timeout.inMinutes;

  bool _keepPlayingOnClose = false;

  /// Cached so [lockNow] can stay synchronous. Kept in step by
  /// [setKeepPlayingOnClose] and reloaded at [init].
  bool get keepPlayingOnClose => _keepPlayingOnClose;

  Future<void> setKeepPlayingOnClose(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKeyKeepPlaying, value);
    _keepPlayingOnClose = value;
  }

  Future<void> init({
    required GlobalKey<NavigatorState> navigatorKey,
    required bool Function() isPlaybackActive,
  }) async {
    _navKey = navigatorKey;
    _isPlaybackActive = isPlaybackActive;
    final prefs = await SharedPreferences.getInstance();
    _setupCompleted = prefs.getBool('setup_completed_v1') ?? false;
    _keepPlayingOnClose = prefs.getBool(prefsKeyKeepPlaying) ?? false;
    await reloadTimeout();
  }

  /// HomeScreen calls this the first time it mounts — from that moment
  /// onboarding is over and the inactivity lock arms.
  void notifySetupCompleted() {
    if (_setupCompleted) return;
    _setupCompleted = true;
    recordActivity();
  }

  /// VaultResetService calls this on forget-vault: back to the unarmed
  /// pre-onboarding state.
  void onVaultForgotten() {
    _setupCompleted = false;
    cancel();
  }

  Future<void> reloadTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    _timeout =
        Duration(minutes: prefs.getInt(prefsKeyMinutes) ?? defaultMinutes);
    recordActivity();
  }

  Future<void> setTimeoutMinutes(int minutes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(prefsKeyMinutes, minutes);
    _timeout = Duration(minutes: minutes);
    recordActivity();
  }

  /// Whether the user has EVER landed on the home screen (the true end of
  /// onboarding). Cached from 'setup_completed_v1' at [init]; flipped live
  /// by [notifySetupCompleted] / [onVaultForgotten].
  bool _setupCompleted = false;

  /// Auto-lock is suspended until onboarding is COMPLETE (first home
  /// landing). The earlier hasAnyAccount guard still let the lock fire on
  /// the post-connect quick-settings step, silently losing that step
  /// forever (MTR#1 F8). During onboarding nothing cloud-reachable needs
  /// protecting yet; manual [lockNow] still works.
  bool get _onboardingInProgress => !_setupCompleted;

  /// Resets the inactivity countdown. Call on user interaction and on unlock.
  void recordActivity() {
    _lastActivity = DateTime.now();
    _deferringSince = null;
    _timer?.cancel();
    if (_timeout.inMinutes <= 0) return; // disabled
    if (!KeyManagerService().isUnlocked) return; // nothing to lock
    if (_onboardingInProgress) return; // no auto-lock mid-signup
    _timer = Timer(_timeout, _onTimeout);
  }

  /// Called from the app's lifecycle observer when the app returns to the
  /// foreground. Locks immediately if the inactivity window already elapsed
  /// while the app was suspended; otherwise restarts the countdown.
  void onResumed() {
    if (_timeout.inMinutes <= 0 || !KeyManagerService().isUnlocked) return;
    if (_onboardingInProgress) return;
    final elapsed = DateTime.now().difference(_lastActivity);
    if (elapsed >= _timeout && !(_isPlaybackActive?.call() ?? false)) {
      lockNow();
    } else {
      recordActivity();
    }
  }

  /// Hard ceiling on how long playback may hold the lock open past its
  /// timeout. Defence in depth behind the [isPlaybackActive] fix: even if a
  /// future liveness signal gets stuck true, the vault still closes.
  static const Duration _maxPlaybackDeferral = Duration(minutes: 30);

  /// When the current run of playback deferrals started. Null when not
  /// deferring.
  DateTime? _deferringSince;

  void _onTimeout() {
    // Defer while media plays, re-checking shortly instead of locking, but
    // never indefinitely. Before the cap, a stuck liveness signal meant the
    // vault could never lock again for the life of the process (MASVS F-33).
    if (_isPlaybackActive?.call() ?? false) {
      final since = _deferringSince ??= DateTime.now();
      if (DateTime.now().difference(since) < _maxPlaybackDeferral) {
        _timer = Timer(const Duration(seconds: 30), _onTimeout);
        return;
      }
      // Cap reached: fall through and lock despite playback.
    }
    _deferringSince = null;
    if (_onboardingInProgress) return;
    lockNow();
  }

  /// Locks now and routes to the login screen.
  ///
  /// Reachable from the Settings "Lock vault" action as well as the
  /// inactivity timer. Until that action existed this method had no callers
  /// at all, so there was no way for a user to close their own vault
  /// (MASVS F-32).
  void lockNow() {
    _timer?.cancel();
    _deferringSince = null;
    if (!KeyManagerService().isUnlocked) return;
    KeyManagerService().lock();
    // Plaintext thumbnails (bytes + decoded bitmaps) leave memory with
    // the keys.
    ThumbStore.instance.clear();
    PaintingBinding.instance.imageCache.clear();
    // Memory alone was never enough. Locking used to leave whole decrypted
    // videos, audio tracks and images on disk, and leave the loopback server
    // that hands them out still listening. Both were confirmed on a device
    // (MASVS F-01, F-02, F-03). Fire-and-forget: the UI must not wait on
    // disk IO to show the login screen.
    // Playback is the one thing a user may legitimately want to outlive the
    // lock, so it is the one thing that is opt-out rather than unconditional.
    // Left running, it also keeps the decrypted track title on the lock
    // screen, which is why the default is to stop.
    if (!_keepPlayingOnClose) {
      unawaited(AudioPlayerService().stop());
    }
    unawaited(VideoStreamingServer().stop());
    unawaited(CacheManagerService().purgeAllLargePlaintext());
    _navKey?.currentState
        ?.pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
