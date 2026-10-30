import 'dart:io';

import 'package:flutter/services.dart';

import 'auto_sync_worker.dart';

/// Answers "may a backup pass use the network right now?" for the Wi-Fi-only
/// setting. Manual uploads the user starts by hand are never gated here; this
/// is for automatic backup (auto-sync, album backfill, Sync now).
class NetworkPolicy {
  NetworkPolicy._();

  static const _channel = MethodChannel('ciphernest/platform');

  /// True when Android reports the active network as metered (mobile data,
  /// or a hotspot the user marked metered). Null when the answer is not
  /// available: not Android, no active network, or the background worker
  /// isolate where the channel is not registered. The background task
  /// carries its own `unmetered` constraint, so null there is harmless.
  static Future<bool?> isMetered() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<bool>('isNetworkMetered');
    } catch (_) {
      return null;
    }
  }

  /// True when Wi-Fi-only is on AND the device is on a metered network, so
  /// a backup pass should wait. Unknown network state never blocks.
  static Future<bool> backupBlockedByWifiOnly() async {
    if (!await AutoSyncScheduler.readWifiOnly()) return false;
    return (await isMetered()) == true;
  }
}
