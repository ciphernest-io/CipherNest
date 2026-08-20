import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/config/routes.dart';
import 'cloud/account_registry.dart';
import 'key_manager_service.dart';

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

  Timer? _timer;
  Duration _timeout = const Duration(minutes: defaultMinutes);
  DateTime _lastActivity = DateTime.now();
  GlobalKey<NavigatorState>? _navKey;
  bool Function()? _isPlaybackActive;

  int get timeoutMinutes => _timeout.inMinutes;

  Future<void> init({
    required GlobalKey<NavigatorState> navigatorKey,
    required bool Function() isPlaybackActive,
  }) async {
    _navKey = navigatorKey;
    _isPlaybackActive = isPlaybackActive;
    await reloadTimeout();
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

  /// Auto-lock is suspended until the FIRST cloud account is connected.
  /// During onboarding (password set, phrase shown, cloud picker open) the
  /// vault is empty — there is nothing cloud-reachable to protect — and a
  /// mid-signup lock used to wedge users: unlock routed to "reconnect" for
  /// a cloud that was never connected. Manual [lockNow] still works.
  bool get _onboardingInProgress => !AccountRegistry().hasAnyAccount;

  /// Resets the inactivity countdown. Call on user interaction and on unlock.
  void recordActivity() {
    _lastActivity = DateTime.now();
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

  void _onTimeout() {
    // Defer while media plays — re-check shortly instead of locking.
    if (_isPlaybackActive?.call() ?? false) {
      _timer = Timer(const Duration(seconds: 30), _onTimeout);
      return;
    }
    if (_onboardingInProgress) return;
    lockNow();
  }

  /// Locks now and routes to the login screen.
  void lockNow() {
    _timer?.cancel();
    if (!KeyManagerService().isUnlocked) return;
    KeyManagerService().lock();
    _navKey?.currentState
        ?.pushNamedAndRemoveUntil(AppRoutes.login, (_) => false);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
