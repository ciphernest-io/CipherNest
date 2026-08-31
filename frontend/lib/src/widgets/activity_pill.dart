import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/activity_center.dart';
import '../app.dart';
import '../config/theme_controller.dart';
import 'activity_sheet.dart';
import 'theme_icon.dart';
import 'toast.dart';

/// TOP-inset claim STACK for the globally mounted overlay. The overlay
/// floats just below a standard AppBar; screens whose top chrome is TALLER
/// (an AppBar TabBar, an in-body selection bar) claim the extra height and
/// release it in dispose (or when the bar hides); the overlay drops below
/// `_claims.last` — route disposal is LIFO, so the last claim always
/// belongs to the visible screen.
class ActivityPillInset {
  ActivityPillInset._();

  static final List<InsetClaim> _claims = [];
  static final ValueNotifier<double> effective = ValueNotifier(0);

  static InsetClaim claim(double height) {
    final c = InsetClaim._(height);
    _claims.add(c);
    _recompute();
    return c;
  }

  static void _recompute() {
    effective.value = _claims.isEmpty ? 0 : _claims.last._height;
  }
}

class InsetClaim {
  double _height;
  bool _released = false;
  InsetClaim._(this._height);

  void update(double height) {
    _height = height;
    ActivityPillInset._recompute();
  }

  void release() {
    if (_released) return;
    _released = true;
    ActivityPillInset._claims.remove(this);
    ActivityPillInset._recompute();
  }
}

/// The global overlay layer mounted in the MaterialApp builder — progress
/// pill + toast above every route. The Material(transparency) wrapper is
/// LOAD-BEARING: this tree lives above the Navigator, so without it every
/// Text renders Flutter's missing-Material error style.
///
/// The pill is a DYNAMIC component (Aug 31 ruling): a running task shows
/// the full pill for a few seconds, then minimizes into a small floating
/// ball on the screen edge that shows only the loader. Tapping the ball
/// re-expands (for another few seconds); tapping the expanded pill
/// minimizes it immediately; long-press opens the task sheet. The ball can
/// be dragged anywhere and snaps to the nearest edge on release — or to
/// the opposite edge when flung. Terminal results always show the full
/// pill (ActivityCenter hides them on its own clock).
class ActivityOverlay extends StatefulWidget {
  const ActivityOverlay({super.key});

  @override
  State<ActivityOverlay> createState() => _ActivityOverlayState();
}

class _ActivityOverlayState extends State<ActivityOverlay> {
  /// How long the full pill stays before minimizing into the ball.
  static const _expandedHold = Duration(seconds: 4);
  static const _ballSize = 44.0;
  static const _edgePad = 8.0;

  bool _minimized = false;
  String? _lastRunningId;
  Timer? _holdTimer;

  // Ball placement: which edge, its top offset (null = pill row), and the
  // finger position while a drag is in flight.
  bool _onLeft = true;
  double? _ballTop;
  Offset? _dragPos;

  @override
  void initState() {
    super.initState();
    ActivityCenter().addListener(_onCenterChanged);
  }

  @override
  void dispose() {
    ActivityCenter().removeListener(_onCenterChanged);
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onCenterChanged() {
    if (!mounted) return;
    final center = ActivityCenter();
    final mode = center.pillMode;
    final task = center.pillTask;
    if (mode == PillMode.hidden || task == null) {
      // Fresh start for the next task.
      _holdTimer?.cancel();
      _holdTimer = null;
      _minimized = false;
      _lastRunningId = null;
    } else if (mode == PillMode.terminal) {
      // Results are always shown in full.
      _holdTimer?.cancel();
      _holdTimer = null;
      _minimized = false;
    } else {
      if (task.id != _lastRunningId) {
        // A new task announces itself expanded.
        _lastRunningId = task.id;
        _minimized = false;
        _armHoldTimer();
      } else if (!_minimized && _holdTimer == null) {
        _armHoldTimer();
      }
    }
    setState(() {});
  }

  void _armHoldTimer() {
    _holdTimer?.cancel();
    _holdTimer = Timer(_expandedHold, () {
      _holdTimer = null;
      if (!mounted) return;
      if (ActivityCenter().pillMode == PillMode.active) {
        setState(() => _minimized = true);
      }
    });
  }

  void _expand() {
    _minimized = false;
    _armHoldTimer();
    setState(() {});
  }

  void _minimizeNow() {
    _holdTimer?.cancel();
    _holdTimer = null;
    setState(() => _minimized = true);
  }

  void _openSheet() {
    final ctx = App.navigatorKey.currentContext;
    if (ctx != null) showActivitySheet(ctx);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: ActivityPillInset.effective,
      builder: (context, inset, _) {
        final center = ActivityCenter();
        final mode = center.pillMode;
        final task = center.pillTask;
        final size = MediaQuery.sizeOf(context);
        final topY =
            MediaQuery.paddingOf(context).top + kToolbarHeight + 10 + inset;

        final pillVisible =
            mode != PillMode.hidden && task != null && !_minimized;
        final ballVisible =
            mode == PillMode.active && task != null && _minimized;

        return Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                // Pill FIRST: it is the long-lived element and keeps a
                // stable y regardless of toast lifecycle.
                Positioned(
                  left: 0,
                  right: 0,
                  top: topY,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (pillVisible) _buildPill(context, mode, task),
                      if (pillVisible) const SizedBox(height: 8),
                      const ToastPill(),
                    ],
                  ),
                ),
                if (ballVisible) _buildBall(context, task, size, topY),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBall(
      BuildContext context, ActivityTask task, Size size, double topY) {
    final cs = Theme.of(context).colorScheme;
    final maxTop = size.height - _ballSize - 96;
    final dragging = _dragPos != null;
    final top = (dragging ? _dragPos!.dy - _ballSize / 2 : (_ballTop ?? topY))
        .clamp(topY, maxTop)
        .toDouble();
    final left = dragging
        ? (_dragPos!.dx - _ballSize / 2)
            .clamp(0.0, size.width - _ballSize)
            .toDouble()
        : (_onLeft ? _edgePad : size.width - _ballSize - _edgePad);

    return AnimatedPositioned(
      duration: dragging ? Duration.zero : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: left,
      top: top,
      child: GestureDetector(
        onTap: _expand,
        onLongPress: _openSheet,
        onPanStart: (d) => setState(() => _dragPos = d.globalPosition),
        onPanUpdate: (d) => setState(() => _dragPos = d.globalPosition),
        onPanEnd: (d) {
          final at = _dragPos;
          if (at == null) return;
          final vx = d.velocity.pixelsPerSecond.dx;
          setState(() {
            // A real fling beats position: throw it to the edge it points
            // at (which may be the opposite one).
            _onLeft = vx.abs() > 500 ? vx < 0 : at.dx < size.width / 2;
            _ballTop = (at.dy - _ballSize / 2).clamp(topY, maxTop).toDouble();
            _dragPos = null;
          });
        },
        child: Container(
          width: _ballSize,
          height: _ballSize,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            shape: BoxShape.circle,
            border: Border.all(color: cs.outline.withAlpha(90)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(40),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              value: task.fraction,
              strokeWidth: 3,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPill(BuildContext context, PillMode mode, ActivityTask task) {
    final center = ActivityCenter();
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final terminal = mode == PillMode.terminal;
    final failed = task.state == ActivityState.failure;
    final label = terminal ? (task.resultMessage ?? task.label) : task.label;
    final extra = center.extraRunningCount;

    final Widget leading = terminal
        ? ThemeIcon(failed ? 'warning' : 'check',
            color: failed ? t.danger : cs.primary, size: 22)
        : SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              value: task.fraction,
              strokeWidth: 3,
            ),
          );

    return Dismissible(
      key: ValueKey('activity-pill-${task.id}-${mode.name}'),
      direction: DismissDirection.horizontal,
      onDismissed: (_) => center.suppressPill(),
      child: GestureDetector(
        // Running: tap toggles down to the ball (the sheet moved to
        // long-press). Terminal: tap opens the sheet as before.
        onTap: terminal ? _openSheet : _minimizeNow,
        onLongPress: _openSheet,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 340),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(t.rPill),
            border: Border.all(
                color: failed && terminal
                    ? t.danger.withAlpha(160)
                    : cs.outline.withAlpha(90)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (!terminal && extra > 0) ...[
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(t.rPill),
                  ),
                  child: Text(
                    '+$extra',
                    style: TextStyle(
                      color: cs.onSurface.withAlpha(160),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
