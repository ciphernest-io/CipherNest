import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'auto_sync_service.dart';

const String autoSyncTaskName = 'autoSyncTask';

/// Unique task id passed to Workmanager. Reusing the same id every launch is
/// what makes [ExistingPeriodicWorkPolicy.keep] work — Android matches the
/// scheduled task by this string and either keeps or replaces it.
const String _kPeriodicTaskUniqueName = 'ciphernest.autosync.periodic';

/// SharedPreferences key for the current mode. Stores an
/// [AutoSyncMode.name]. Backward-compat: if this key is unset but the legacy
/// `auto_sync_enabled` bool is `true`, we treat that as
/// [AutoSyncMode.foregroundOnly] (matches the pre-S18 behaviour, where the
/// bool only triggered a foreground sync on [SyncService.syncNow]).
const String _kAutoSyncModePref = 'auto_sync_mode';

/// Legacy boolean written by the pre-S18 Settings + Quick-Settings toggles.
/// Kept in sync with the new enum so any code path still reading it
/// (sync_service.dart, older widgets) doesn't break.
const String _kLegacyEnabledPref = 'auto_sync_enabled';

/// How often the periodic task fires when the user is on
/// [AutoSyncMode.background]. Six hours is the sweet spot between
/// responsiveness (new photos vaulted within a workday) and battery cost
/// (four wakeups/day × maybe 30 s of Wi-Fi + AES-GCM). Android's absolute
/// minimum for `registerPeriodicTask` is 15 minutes; we deliberately pick a
/// value well above it.
const Duration _kPeriodicFrequency = Duration(hours: 6);

/// One-shot backoff for a failed periodic run. 15 minutes lines up with
/// Workmanager's shortest interval so we don't burn a slot on rapid retries.
const Duration _kBackoffDelay = Duration(minutes: 15);

/// How the user wants auto-sync to behave.
enum AutoSyncMode {
  /// No automatic sync anywhere. User can still trigger a manual sync from
  /// Settings > Sync Now.
  off,

  /// Sync fires when [SyncService.syncNow] runs (app open, pull-to-refresh).
  /// No Workmanager task registered — zero background battery cost.
  foregroundOnly,

  /// Sync fires on foreground triggers AND a Workmanager periodic task
  /// wakes the process every [_kPeriodicFrequency] to catch new photos even
  /// when the app is closed. Constrained to require an active network and
  /// non-low battery, so it silently no-ops on airplane mode or ≤15 %
  /// battery.
  background,
}

/// Static helpers for reading, writing, and applying the persisted
/// [AutoSyncMode]. Everything is idempotent — safe to call from cold start,
/// from Settings toggle, from Quick Settings, etc.
class AutoSyncScheduler {
  AutoSyncScheduler._();

  /// Reads the persisted mode. Falls back to the legacy boolean the first
  /// time this key is missing.
  static Future<AutoSyncMode> readMode() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kAutoSyncModePref);
    if (raw != null) {
      return AutoSyncMode.values.firstWhere(
        (m) => m.name == raw,
        orElse: () => AutoSyncMode.off,
      );
    }
    // Backward-compat: honour a pre-S18 install where the user opted into
    // auto-sync via the plain bool. The 6-hour periodic task is opt-in —
    // don't upgrade them to `background` silently.
    final legacy = prefs.getBool(_kLegacyEnabledPref) ?? false;
    return legacy ? AutoSyncMode.foregroundOnly : AutoSyncMode.off;
  }

  /// Persists [mode] and applies it: registers or cancels the Workmanager
  /// periodic task, and mirrors the derived boolean into the legacy pref so
  /// [SyncService] and other consumers stay in sync during the migration.
  static Future<void> writeMode(AutoSyncMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAutoSyncModePref, mode.name);
    await prefs.setBool(_kLegacyEnabledPref, mode != AutoSyncMode.off);
    await _applyMode(mode);
  }

  /// Called from [main] on cold start. Re-registers the periodic task if
  /// the user is on [AutoSyncMode.background] — the OS occasionally kills
  /// scheduled work when the app is force-stopped, so we treat every launch
  /// as a chance to reconcile.
  static Future<void> reconcileWithPersistedMode() async {
    try {
      final mode = await readMode();
      await _applyMode(mode);
    } catch (e) {
      debugPrint('AutoSyncScheduler.reconcileWithPersistedMode: $e');
    }
  }

  static Future<void> _applyMode(AutoSyncMode mode) async {
    if (mode == AutoSyncMode.background) {
      // registerPeriodicTask with existingWorkPolicy.keep is safe to call
      // every launch — it's a no-op when the task is already scheduled and
      // registers it if the OS dropped it.
      try {
        await Workmanager().registerPeriodicTask(
          _kPeriodicTaskUniqueName,
          autoSyncTaskName,
          frequency: _kPeriodicFrequency,
          existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
          constraints: Constraints(
            networkType: NetworkType.connected,
            requiresBatteryNotLow: true,
          ),
          backoffPolicy: BackoffPolicy.exponential,
          backoffPolicyDelay: _kBackoffDelay,
        );
        await _log('background mode enabled: periodic task scheduled '
            'every ${_kPeriodicFrequency.inHours}h');
      } catch (e) {
        debugPrint('AutoSyncScheduler: registerPeriodicTask failed: $e');
      }
      return;
    }

    // off / foregroundOnly: make sure no periodic task lingers.
    try {
      await Workmanager().cancelByUniqueName(_kPeriodicTaskUniqueName);
    } catch (e) {
      debugPrint('AutoSyncScheduler: cancelByUniqueName failed: $e');
    }
    await _log('mode set to ${mode.name}: periodic task cancelled');
  }

  /// Appends a line to a plain-text log file under the app documents dir.
  /// Only used for local debugging / letting the user or a beta tester
  /// verify the worker actually fired. Never records any file content or
  /// encryption metadata.
  static Future<void> _log(String message) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/autosync_debug.log');
      final line = '${DateTime.now().toIso8601String()} $message\n';
      await file.writeAsString(line, mode: FileMode.append, flush: false);
    } catch (_) {
      // Debug log is best-effort. Don't fail the whole scheduler if the
      // filesystem hiccups.
    }
  }
}

/// Top-level callback dispatcher for WorkManager.
/// Must be a top-level function (not a method).
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    if (taskName != autoSyncTaskName) return true;

    await AutoSyncScheduler._log('worker fired');

    try {
      final notifications = FlutterLocalNotificationsPlugin();
      await notifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );

      // Show "syncing" notification
      await _showNotification(
        notifications,
        title: 'CipherNest',
        body: 'Scanning for new photos...',
        ongoing: true,
      );

      final result = await AutoSyncService().runFullSync();

      // Show result notification
      if (result.synced > 0 || result.failed > 0) {
        final body = result.failed > 0
            ? '${result.synced} secured, ${result.failed} failed'
            : '${result.synced} photo${result.synced == 1 ? '' : 's'} secured';
        await _showNotification(
          notifications,
          title: 'CipherNest',
          body: body,
          ongoing: false,
        );
        await AutoSyncScheduler._log(
          'worker done: synced=${result.synced} failed=${result.failed} '
          'skipped=${result.skipped}',
        );
      } else {
        // Nothing to sync — dismiss notification
        await notifications.cancel(0);
        await AutoSyncScheduler._log('worker done: nothing to sync');
      }

      return true;
    } catch (e) {
      debugPrint('Auto-sync worker error: $e');
      await AutoSyncScheduler._log('worker error: $e');
      return false;
    }
  });
}

Future<void> _showNotification(
  FlutterLocalNotificationsPlugin notifications, {
  required String title,
  required String body,
  required bool ongoing,
}) async {
  await notifications.show(
    0,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        'auto_sync_channel',
        'Auto-Sync',
        channelDescription: 'Background photo sync notifications',
        importance: ongoing ? Importance.low : Importance.defaultImportance,
        priority: ongoing ? Priority.low : Priority.defaultPriority,
        ongoing: ongoing,
        autoCancel: !ongoing,
      ),
    ),
  );
}
