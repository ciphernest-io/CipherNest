import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'bg_activity_bridge.dart';
import 'notify.dart';
import 'sync_service.dart';
import 'upload_foreground_guard.dart';

/// Enum ORDER is the pill priority — when several tasks run, the pill
/// fronts the lowest index (migration beats an upload beats a sync).
enum ActivityKind {
  migration,
  folderImport,
  upload,
  backup,
  export,
  binOp,
  sync,
  dbBackup,
  sweep,
}

enum ActivityState { running, success, failure }

/// quiet: sheet-only while running, surfaces ONLY failure (as an error
/// toast). For janitorial work nobody asked to watch — sweeps, the debounced
/// vault-index backup, the per-screen sync cycle.
enum ActivityVisibility { normal, quiet }

enum PillMode { hidden, active, terminal }

/// One tracked long-running operation. Mutable by design — the owning flow
/// drives it via [update]/[complete]/[fail]; every mutation notifies the
/// [ActivityCenter] listeners (pill, sheet, notification mirror).
class ActivityTask {
  final String id;
  final ActivityKind kind;
  final ActivityVisibility visibility;
  final DateTime startedAt;

  String label;

  /// Sheet sub-line (current file name, ETA…). Never shown on the pill.
  String? detail;

  int? done;

  /// null = indeterminate (spinner instead of a ring/bar).
  int? total;

  ActivityState state = ActivityState.running;
  String? resultMessage;
  DateTime? endedAt;
  bool paused = false;

  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;

  final ActivityCenter _center;

  ActivityTask._({
    required this.kind,
    required this.label,
    required this.visibility,
    required ActivityCenter center,
    this.total,
    this.detail,
    this.onPause,
    this.onResume,
    this.onCancel,
  })  : id = const Uuid().v4(),
        startedAt = DateTime.now(),
        _center = center;

  /// 0..1 when determinate, null when indeterminate.
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return ((done ?? 0) / t).clamp(0.0, 1.0);
  }

  bool get isRunning => state == ActivityState.running;

  void update(int done, {int? total, String? label, String? detail}) {
    if (!isRunning) return;
    this.done = done;
    if (total != null) this.total = total;
    if (label != null) this.label = label;
    if (detail != null) this.detail = detail;
    _center._onTaskChanged();
  }

  void setLabel(String label) {
    if (!isRunning) return;
    this.label = label;
    _center._onTaskChanged();
  }

  void setPaused(bool value) {
    if (!isRunning) return;
    paused = value;
    _center._onTaskChanged();
  }

  void complete([String? message]) => _finish(ActivityState.success, message);

  void fail([String? message]) => _finish(ActivityState.failure, message);

  /// Removes the task silently — it never enters [ActivityCenter.recent].
  /// For flows the user backed out of (e.g. a cancelled save dialog).
  void discard() {
    if (!isRunning) return;
    state = ActivityState.success;
    endedAt = DateTime.now();
    _center._discard(this);
  }

  void _finish(ActivityState terminal, String? message) {
    if (!isRunning) return;
    state = terminal;
    resultMessage = message;
    endedAt = DateTime.now();
    _center._onTaskFinished(this);
  }
}

/// The app-wide registry of ongoing and recently finished work. Single
/// isolate, single source of truth for the pill/sheet UI and the system
/// notification mirror. All state lives HERE (a singleton) because the
/// MaterialApp builder that mounts the overlay re-runs on every theme
/// change — widgets must be stateless over this.
class ActivityCenter extends ChangeNotifier {
  static final ActivityCenter _instance = ActivityCenter._internal();
  factory ActivityCenter() => _instance;
  ActivityCenter._internal();

  static const int _recentCap = 10;
  static const Duration terminalDisplay = Duration(seconds: 4);

  final List<ActivityTask> _running = [];
  final List<ActivityTask> _recent = []; // newest first, session-only

  bool _suppressed = false;
  bool _sheetOpen = false;
  ActivityTask? _terminalTask;
  Timer? _terminalTimer;

  List<ActivityTask> get running => List.unmodifiable(_running);
  List<ActivityTask> get recent => List.unmodifiable(_recent);
  bool get sheetOpen => _sheetOpen;

  Iterable<ActivityTask> get _normalRunning =>
      _running.where((t) => t.visibility == ActivityVisibility.normal);

  PillMode get pillMode {
    if (_sheetOpen) return PillMode.hidden;
    if (_terminalTask != null) return PillMode.terminal;
    if (_suppressed) return PillMode.hidden;
    return _normalRunning.isEmpty ? PillMode.hidden : PillMode.active;
  }

  /// What the collapsed pill renders: the expiring terminal task, else the
  /// highest-priority (lowest enum index) normal running task.
  ActivityTask? get pillTask {
    final terminal = _terminalTask;
    if (terminal != null) return terminal;
    ActivityTask? best;
    for (final t in _normalRunning) {
      if (best == null || t.kind.index < best.kind.index) best = t;
    }
    return best;
  }

  /// "+N" chip: normal running tasks beyond the one the pill fronts.
  int get extraRunningCount {
    final n = _normalRunning.length - 1;
    return n < 0 ? 0 : n;
  }

  ActivityTask start({
    required ActivityKind kind,
    required String label,
    int? total,
    String? detail,
    ActivityVisibility visibility = ActivityVisibility.normal,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onCancel,
  }) {
    final task = ActivityTask._(
      kind: kind,
      label: label,
      visibility: visibility,
      center: this,
      total: total,
      detail: detail,
      onPause: onPause,
      onResume: onResume,
      onCancel: onCancel,
    );
    _running.add(task);
    // Any new work re-reveals a swiped-away pill and preempts a lingering
    // terminal flash.
    _suppressed = false;
    _clearTerminal();
    _mirrorToFgs();
    notifyListeners();
    return task;
  }

  /// Swipe-away: hides the pill until the next task event. Work continues.
  /// Also flicks away a lingering terminal flash.
  void suppressPill() {
    _suppressed = true;
    _clearTerminal();
    notifyListeners();
  }

  /// The pill hides underneath our own expanded sheet.
  void setSheetOpen(bool open) {
    if (_sheetOpen == open) return;
    _sheetOpen = open;
    notifyListeners();
  }

  void _onTaskChanged() {
    _mirrorToFgs();
    notifyListeners();
  }

  // ---- Foreground-service notification mirror ---------------------------
  // While the upload FGS pin is held, live progress rides into the pinned
  // "Securing your file…" notification. Throttled to 500ms with a trailing
  // edge so the final state always lands without churning the shade.

  static const Duration _fgsThrottle = Duration(milliseconds: 500);
  static const Set<ActivityKind> _fgsKinds = {
    ActivityKind.migration,
    ActivityKind.folderImport,
    ActivityKind.upload,
    ActivityKind.backup,
  };
  DateTime? _lastFgsPush;
  Timer? _fgsTrailing;

  void _mirrorToFgs() {
    if (!UploadForegroundGuard().isActive) return;
    ActivityTask? task;
    for (final t in _normalRunning) {
      if (!_fgsKinds.contains(t.kind)) continue;
      if (task == null || t.kind.index < task.kind.index) task = t;
    }
    if (task == null) return;

    final now = DateTime.now();
    final last = _lastFgsPush;
    if (last != null && now.difference(last) < _fgsThrottle) {
      _fgsTrailing ??= Timer(_fgsThrottle - now.difference(last), () {
        _fgsTrailing = null;
        _mirrorToFgs();
      });
      return;
    }
    _lastFgsPush = now;
    final total = task.total;
    unawaited(UploadForegroundGuard().updateNotification(
      title: 'CipherNest',
      text: task.label,
      progress: task.done ?? 0,
      max: total ?? 0,
      indeterminate: total == null,
    ));
  }

  void _onTaskFinished(ActivityTask task) {
    _running.remove(task);
    _recent.insert(0, task);
    if (_recent.length > _recentCap) _recent.removeLast();

    if (task.visibility == ActivityVisibility.normal) {
      _maybeNotifyBackgroundTerminal(task);
    }

    if (task.visibility == ActivityVisibility.quiet) {
      // Quiet success is silent (sheet history only); quiet failure must
      // still reach the user.
      if (task.state == ActivityState.failure) {
        Notify.error(task.resultMessage ?? '${task.label} failed');
      }
      notifyListeners();
      return;
    }

    // Terminal flash ONLY when this was the last normal task — otherwise it
    // folds straight into recent and the pill keeps showing the remainder.
    if (_normalRunning.isEmpty) {
      _suppressed = false;
      _terminalTask = task;
      _terminalTimer?.cancel();
      _terminalTimer = Timer(terminalDisplay, () {
        _terminalTask = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void _discard(ActivityTask task) {
    _running.remove(task);
    notifyListeners();
  }

  void _clearTerminal() {
    _terminalTimer?.cancel();
    _terminalTimer = null;
    _terminalTask = null;
  }

  // ---- Backgrounded-completion notifications ----------------------------
  // A task finishing while the app is paused/hidden posts a one-shot
  // notification so "leave mid-upload" ends in a visible receipt, not
  // silence. Channel 'activity_done' (id 42) is separate from the FGS pin
  // (41) and the bg worker (0) so users can silence completion pings
  // without silencing progress.

  FlutterLocalNotificationsPlugin? _notifications;
  bool _inited = false;

  /// Idempotent. Foreground-isolate plugin init (the bg worker initializes
  /// its OWN instance in its own isolate) + lifecycle watcher + the
  /// background-sync bridge port.
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final plugin = FlutterLocalNotificationsPlugin();
    try {
      await plugin.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_ciphernest')));
      _notifications = plugin;
    } catch (e) {
      debugPrint('ActivityCenter: notification init failed: $e');
    }
    // Hot restart leaves a stale mapping pointing at a dead port — always
    // remove before re-registering.
    IsolateNameServer.removePortNameMapping(kBgSyncPortName);
    _bgPort = ReceivePort();
    IsolateNameServer.registerPortWithName(_bgPort!.sendPort, kBgSyncPortName);
    _bgPort!.listen(_onBgSyncMessage);
    WidgetsBinding.instance.addObserver(_LifecycleWatcher(this));
    await consumePendingBgSummary();
  }

  // ---- Background-sync bridge -------------------------------------------
  // The WorkManager isolate streams progress here (see bg_activity_bridge)
  // so opening the app mid-run shows "Backing up 3/10" LIVE instead of
  // photos silently materializing.

  ReceivePort? _bgPort;
  ActivityTask? _bgSyncTask;

  void _onBgSyncMessage(Object? raw) {
    final msg = BgSyncMessage.decode(raw);
    if (msg == null) return;
    switch (msg.type) {
      case BgSyncMessage.typeStarted:
      case BgSyncMessage.typeScanning:
        _bgSyncTask ??= start(
            kind: ActivityKind.backup, label: 'Checking for new photos…');
      case BgSyncMessage.typeProgress:
        _bgSyncTask ??= start(
            kind: ActivityKind.backup, label: 'Backing up…');
        _bgSyncTask!.update(msg.a,
            total: msg.b, label: 'Backing up ${msg.a}/${msg.b}');
      case BgSyncMessage.typeTerminal:
        final task = _bgSyncTask;
        _bgSyncTask = null;
        // Seen live — the away-summary would be a duplicate on next open.
        unawaited(_clearBgSummaryPref());
        final synced = msg.a;
        final failed = msg.b;
        if (task != null) {
          if (synced == 0 && failed == 0) {
            // Nothing happened — say nothing. Every sibling path (the
            // worker's own notification, the away-summary) already guards
            // the zero case; this one didn't, and a 15-minute background
            // interval turned it into a "No new photos found" notification
            // drumbeat (MTR#1 X5).
            task.discard();
          } else {
            final message = failed > 0
                ? '$synced backed up · $failed failed'
                : '$synced photo${synced == 1 ? '' : 's'} secured';
            failed > 0 ? task.fail(message) : task.complete(message);
          }
        }
        // The worker isolate's own notifier bump never crosses isolates —
        // THIS is what makes bg-synced photos appear in the gallery live.
        if (synced > 0) SyncService().syncNotifier.value++;
    }
  }

  Future<void> _clearBgSummaryPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kBgSyncSummaryPref);
    } catch (_) {
      // Best-effort — worst case the summary shows once redundantly.
    }
  }

  void _maybeNotifyBackgroundTerminal(ActivityTask task) {
    final plugin = _notifications;
    if (plugin == null) return;
    final state = WidgetsBinding.instance.lifecycleState;
    // null (cold start, before the first frame) and inactive (mid
    // transition, e.g. the share sheet is up) both count as "visible
    // enough" — only a genuinely hidden/paused app gets the ping.
    if (state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      return;
    }
    unawaited(plugin.show(
      42,
      'CipherNest',
      task.resultMessage ?? task.label,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'activity_done',
          'Completed activities',
          channelDescription:
              'Finished uploads, syncs and other activities',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          autoCancel: true,
        ),
      ),
    ));
  }

  /// "N photos secured while you were away" — a background run that ended
  /// while the app was dead stamped a summary pref; surface it once as a
  /// pre-completed entry (recent row + terminal pill flash), then clear.
  Future<void> consumePendingBgSummary() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kBgSyncSummaryPref);
      if (raw == null) return;
      await prefs.remove(kBgSyncSummaryPref);
      final summary = decodeBgSummary(raw);
      if (summary == null) return;
      if (summary.synced == 0 && summary.failed == 0) return;
      final message = summary.failed > 0
          ? '${summary.synced} secured · ${summary.failed} failed while '
              'you were away'
          : '${summary.synced} photo${summary.synced == 1 ? '' : 's'} '
              'secured while you were away';
      final task =
          start(kind: ActivityKind.backup, label: 'Background backup');
      summary.failed > 0 ? task.fail(message) : task.complete(message);
      if (summary.synced > 0) SyncService().syncNotifier.value++;
    } catch (e) {
      debugPrint('ActivityCenter: bg summary consume failed: $e');
    }
  }

  @visibleForTesting
  void debugReset() {
    _running.clear();
    _recent.clear();
    _suppressed = false;
    _sheetOpen = false;
    _clearTerminal();
    _fgsTrailing?.cancel();
    _fgsTrailing = null;
    _lastFgsPush = null;
  }
}

/// The center isn't a widget — this small observer feeds it lifecycle
/// transitions (resume → consume the background-sync away-summary).
class _LifecycleWatcher with WidgetsBindingObserver {
  final ActivityCenter _center;
  _LifecycleWatcher(this._center);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_center.consumePendingBgSummary());
    }
  }
}
