import 'dart:async';
import 'dart:io';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'auto_sync_service.dart';
import 'bg_activity_bridge.dart';

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

/// SharedPreferences key for the user-chosen background interval, in
/// minutes. Default 360 (six hours) — the sweet spot between responsiveness
/// and battery cost. Android's absolute minimum for `registerPeriodicTask`
/// is 15 minutes; the picker's choices respect it.
const String _kIntervalPref = 'auto_sync_interval_minutes';

/// The interval most recently REGISTERED with Workmanager. Registration
/// must use `update` only when the desired interval actually changed —
/// unconditionally re-registering on every cold start would reset the
/// periodic timer each launch, so a 6-hour task would never fire for a
/// user who opens the app every few hours.
const String _kIntervalAppliedPref = 'auto_sync_interval_applied';

const int kAutoSyncIntervalDefaultMinutes = 360;

/// Picker choices, minutes. 15 is Workmanager's floor.
const List<int> kAutoSyncIntervalChoices = [15, 60, 360, 1440];

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

  /// Reads the user-chosen background interval.
  static Future<Duration> readInterval() async {
    final prefs = await SharedPreferences.getInstance();
    final minutes =
        prefs.getInt(_kIntervalPref) ?? kAutoSyncIntervalDefaultMinutes;
    return Duration(minutes: minutes < 15 ? 15 : minutes);
  }

  /// Persists a new background interval and re-applies the current mode so
  /// the Workmanager task picks it up.
  static Future<void> writeInterval(Duration interval) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kIntervalPref, interval.inMinutes);
    await _applyMode(await readMode());
  }

  static Future<void> _applyMode(AutoSyncMode mode) async {
    if (mode == AutoSyncMode.background) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final desired = await readInterval();
        final applied = prefs.getInt(_kIntervalAppliedPref);
        // `keep` when the registered task already runs at the desired
        // interval (re-registers only if the OS dropped it); `update` when
        // the user picked a new interval. Never unconditionally replace —
        // that resets the periodic timer on every cold start.
        final policy = applied == desired.inMinutes
            ? ExistingPeriodicWorkPolicy.keep
            : ExistingPeriodicWorkPolicy.update;
        await Workmanager().registerPeriodicTask(
          _kPeriodicTaskUniqueName,
          autoSyncTaskName,
          frequency: desired,
          existingWorkPolicy: policy,
          constraints: Constraints(
            networkType: NetworkType.connected,
            requiresBatteryNotLow: true,
          ),
          backoffPolicy: BackoffPolicy.exponential,
          backoffPolicyDelay: _kBackoffDelay,
        );
        await prefs.setInt(_kIntervalAppliedPref, desired.inMinutes);
        await _log('background mode enabled: periodic task scheduled '
            'every ${desired.inMinutes}m (policy ${policy.name})');
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

    // Live bridge to the UI isolate's ActivityCenter — null when the app
    // isn't running (or hasn't registered yet); every send is best-effort.
    final port = IsolateNameServer.lookupPortByName(kBgSyncPortName);

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
      port?.send(BgSyncMessage.scanning());

      // Live per-asset progress: to the UI isolate AND into this worker's
      // own notification (determinate bar). Cleared in the finally below —
      // the AutoSyncService singleton is isolate-local but a stale closure
      // must not outlive the run.
      AutoSyncService().onProgress = (done, total) {
        port?.send(BgSyncMessage.progress(done, total));
        unawaited(_showNotification(
          notifications,
          title: 'CipherNest',
          body: 'Backing up $done/$total',
          ongoing: true,
          progress: done,
          max: total,
        ));
      };

      final AutoSyncResult result;
      try {
        result = await AutoSyncService().runFullSync();
      } finally {
        AutoSyncService().onProgress = null;
      }

      // Proof-of-life stamp: distinct from auto_sync_last_run (which every
      // caller writes) — this one only ever moves when the BACKGROUND
      // worker actually fired, which is what Settings surfaces so Samsung's
      // battery killer can't silently disable background sync.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'auto_sync_last_bg_run',
        DateTime.now().millisecondsSinceEpoch,
      );

      // Show result notification
      if (result.synced > 0 || result.failed > 0) {
        // Away-summary for the next app open. The UI isolate clears it the
        // moment it sees the live terminal, so it only surfaces when the
        // app was dead for the run.
        await prefs.setString(
          kBgSyncSummaryPref,
          encodeBgSummary(
            result.synced,
            result.failed,
            DateTime.now().millisecondsSinceEpoch,
          ),
        );
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
      port?.send(BgSyncMessage.terminal(result.synced, result.failed));

      return true;
    } catch (e) {
      debugPrint('Auto-sync worker error: $e');
      await AutoSyncScheduler._log('worker error: $e');
      port?.send(BgSyncMessage.terminal(0, 1));
      return false;
    }
  });
}

Future<void> _showNotification(
  FlutterLocalNotificationsPlugin notifications, {
  required String title,
  required String body,
  required bool ongoing,
  int? progress,
  int? max,
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
        onlyAlertOnce: true,
        showProgress: max != null,
        maxProgress: max ?? 0,
        progress: progress ?? 0,
      ),
    ),
  );
}
