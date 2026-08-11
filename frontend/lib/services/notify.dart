import 'dart:async';

import 'package:flutter/foundation.dart';

/// Context-free transient messages — the replacement for every SnackBar.
/// Pure controller (no widget imports) so services can fire messages; the
/// pill widget in lib/src/widgets/toast.dart renders [ToastController].
class Notify {
  Notify._();
  static void info(String message) =>
      ToastController().show(message, isError: false);
  static void error(String message) =>
      ToastController().show(message, isError: true);
}

class ToastEvent {
  final String message;
  final bool isError;

  /// Monotonic — keys AnimatedSwitcher transitions and lets tests assert
  /// the replace-not-queue policy.
  final int seq;
  const ToastEvent(this.message, this.isError, this.seq);

  Duration get duration => isError
      ? const Duration(milliseconds: 4000)
      : const Duration(milliseconds: 2500);
}

/// POLICY: replace, no queue. A new toast immediately replaces the visible
/// one and restarts its timer — queued messages arriving seconds after
/// their action are the SnackBar failure mode this system escapes.
class ToastController extends ChangeNotifier {
  static final ToastController _instance = ToastController._internal();
  factory ToastController() => _instance;
  ToastController._internal();

  ToastEvent? _current;
  int _seq = 0;
  Timer? _timer;

  ToastEvent? get current => _current;

  void show(String message, {required bool isError}) {
    _timer?.cancel();
    final event = ToastEvent(message, isError, ++_seq);
    _current = event;
    _timer = Timer(event.duration, () {
      _current = null;
      notifyListeners();
    });
    notifyListeners();
  }

  /// Swipe-away: gone instantly.
  void dismiss() {
    _timer?.cancel();
    _current = null;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _timer?.cancel();
    _current = null;
    _seq = 0;
  }
}
