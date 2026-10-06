import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

/// Per-screen control of FLAG_SECURE.
///
/// Screenshots, screen recording and casting are **allowed by default**
/// (2026-10-06 ruling): users are trusted with their own gallery. The flag is
/// applied only by screens that put a credential on the display.
///
/// Those screens are not a matter of preference and are never governed by a
/// user setting. A screenshot of a recovery phrase or a share link is a
/// credential written to `DCIM/Screenshots`, where photo backup syncs it off
/// the device. That is MASVS F-05, and it stays closed there.
class SecureWindowService {
  SecureWindowService._();
  static final SecureWindowService instance = SecureWindowService._();

  static const _channel = MethodChannel('ciphernest/secure_window');

  /// How many screens currently want the window secured. A counter rather than
  /// a boolean because these screens can stack: "view phrase" can sit over a
  /// share sheet, and the inner one popping must not unsecure the outer one.
  int _depth = 0;

  Future<void> acquire() async {
    _depth++;
    if (_depth == 1) await _apply(true);
  }

  Future<void> release() async {
    if (_depth == 0) return;
    _depth--;
    if (_depth == 0) await _apply(false);
  }

  Future<void> _apply(bool on) async {
    try {
      await _channel.invokeMethod<void>('set', {'on': on});
    } on PlatformException {
      // Never let a missing channel take down a screen that is showing a
      // phrase. Failing to CLEAR the flag is harmless; failing to SET it is
      // only reachable on a platform without the channel at all.
    } on MissingPluginException {
      // Same, for unit tests and any non-Android host.
    }
  }
}

/// Mixin for a [State] whose screen displays a credential.
///
/// Secures the window while the route is mounted and releases it on dispose,
/// so a screen cannot leak by forgetting to clean up on one of its exits.
mixin SecureScreenMixin<T extends StatefulWidget> on State<T> {
  @override
  void initState() {
    super.initState();
    SecureWindowService.instance.acquire();
  }

  @override
  void dispose() {
    SecureWindowService.instance.release();
    super.dispose();
  }
}
