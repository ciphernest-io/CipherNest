import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Ref-counted handle on the Android upload foreground service
/// (UploadForegroundService.kt): while at least one caller holds a ref, the
/// process is pinned at foreground priority so backgrounding the app cannot
/// freeze an in-flight encrypt+upload.
///
/// Failure-proof by design: every platform call is best-effort — an upload
/// must NEVER fail because the notification/service couldn't start.
class UploadForegroundGuard {
  static final UploadForegroundGuard _instance =
      UploadForegroundGuard._internal();
  factory UploadForegroundGuard() => _instance;
  UploadForegroundGuard._internal();

  static const _channel = MethodChannel('ciphernest/platform');
  int _refs = 0;

  /// True while at least one flow holds the pin — the activity center only
  /// mirrors progress into the notification while this is the case.
  bool get isActive => _refs > 0;

  /// Best-effort mirror of live progress into the pinned notification.
  /// max == 0 && !indeterminate hides the progress bar.
  Future<void> updateNotification({
    required String title,
    required String text,
    int progress = 0,
    int max = 0,
    bool indeterminate = false,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('updateUploadForeground', {
        'title': title,
        'text': text,
        'progress': progress,
        'max': max,
        'indeterminate': indeterminate,
      });
    } catch (e) {
      debugPrint('UploadForegroundGuard.updateNotification: $e');
    }
  }

  Future<void> begin() async {
    if (!Platform.isAndroid) return;
    _refs++;
    if (_refs != 1) return;
    try {
      await _channel.invokeMethod('startUploadForeground');
    } catch (e) {
      debugPrint('UploadForegroundGuard.begin: $e');
    }
  }

  Future<void> end() async {
    if (!Platform.isAndroid) return;
    // Unmatched end() (a flow that bailed before begin()) must not steal a
    // concurrent upload's ref.
    if (_refs == 0) return;
    _refs--;
    if (_refs != 0) return;
    try {
      await _channel.invokeMethod('stopUploadForeground');
    } catch (e) {
      debugPrint('UploadForegroundGuard.end: $e');
    }
  }
}

/// Battery-optimization helpers for the background-sync Settings tile.
class BatteryOptimization {
  BatteryOptimization._();

  static const _channel = MethodChannel('ciphernest/platform');

  /// True when the app is exempt from Doze/App-Standby restrictions —
  /// i.e. the Workmanager periodic sync has a fighting chance on Samsung.
  static Future<bool?> isExempt() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
    } catch (_) {
      return null;
    }
  }

  /// Opens the OS battery-optimization list so the user can exempt
  /// CipherNest. Best-effort.
  static Future<void> openSettings() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('openBatteryOptimizationSettings');
    } catch (e) {
      debugPrint('BatteryOptimization.openSettings: $e');
    }
  }
}
