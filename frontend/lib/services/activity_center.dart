import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'notify.dart';
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

  /// Wired up across later commits: notification mirror, lifecycle watcher,
  /// background-sync bridge. Kept idempotent.
  Future<void> init() async {}

  /// "N photos secured while you were away" — consumed on init/resume.
  Future<void> consumePendingBgSummary() async {}

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
