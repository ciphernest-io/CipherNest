import 'dart:async';
import 'dart:math' as math;

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
/// The pill is a DYNAMIC component: a running task shows the full pill for
/// a few seconds, then MORPHS (one continuously animated blob) into a
/// small floating ball on the screen edge showing only the loader.
/// Gestures, all visible ones:
///   - TAP the pill  -> opens the activity drawer (controls + history).
///   - SWIPE the pill -> throws it into the ball at the edge you swiped
///     toward, at the default height.
///   - TAP the ball  -> morphs it back out.
///   - DRAG the ball -> place it anywhere; it snaps to the nearest edge,
///     or the opposite one on a fling.
/// Completion never barges back in: a minimized task finishes as a check
/// (or warning) inside the ball.
class ActivityOverlay extends StatefulWidget {
  const ActivityOverlay({super.key});

  @override
  State<ActivityOverlay> createState() => _ActivityOverlayState();
}

class _ActivityOverlayState extends State<ActivityOverlay> {
  /// How long the full pill stays before minimizing into the ball.
  static const _expandedHold = Duration(seconds: 4);
  static const _morph = Duration(milliseconds: 340);
  static const _ballSize = 44.0;
  static const _pillHeight = 48.0;
  static const _edgePad = 8.0;

  bool _minimized = false;
  String? _lastRunningId;
  Timer? _holdTimer;

  // Ball placement: which edge, its top offset (null = pill row), and the
  // finger position while a drag is in flight.
  bool _onLeft = false;
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
      // Results stay wherever the pill already is: a minimized task
      // finishes as a check inside the ball instead of barging back in.
      _holdTimer?.cancel();
      _holdTimer = null;
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
    if (ActivityCenter().pillMode == PillMode.active) _armHoldTimer();
    setState(() {});
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

        final visible = mode != PillMode.hidden && task != null;
        final expanded = visible && !_minimized;

        return Positioned.fill(
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                // Toast: fixed top slot; slides down while the expanded
                // pill occupies the row above it.
                Positioned(
                  left: 0,
                  right: 0,
                  top: topY,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: _morph,
                        curve: Curves.easeInOutCubic,
                        height: expanded ? _pillHeight + 8 : 0,
                      ),
                      const ToastPill(),
                    ],
                  ),
                ),
                if (visible) _buildBlob(context, mode, task, size, topY),
              ],
            ),
          ),
        );
      },
    );
  }

  double _textWidth(String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  /// The single morphing element. Expanded and minimized are two target
  /// rects of the SAME AnimatedPositioned container, so every state change
  /// is one continuous blob movement instead of a swap.
  Widget _buildBlob(BuildContext context, PillMode mode, ActivityTask task,
      Size size, double topY) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final terminal = mode == PillMode.terminal;
    final failed = task.state == ActivityState.failure;
    final expanded = !_minimized;
    final dragging = _dragPos != null;

    final label = terminal ? (task.resultMessage ?? task.label) : task.label;
    final extra = terminal ? 0 : ActivityCenter().extraRunningCount;

    // Shrink-wrap: measure the content instead of taking a fixed width
    // (which read as a full-width bar).
    final labelStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      fontFamily: t.fontFamily,
    );
    var needed = 14 + 24 + 10 + _textWidth(label, labelStyle) + 14 + 2;
    if (extra > 0) {
      const chipStyle = TextStyle(fontSize: 11, fontWeight: FontWeight.w600);
      needed += 8 + 14 + _textWidth('+$extra', chipStyle);
    }
    final expandedWidth =
        needed.clamp(120.0, math.min(340.0, size.width - 32.0)).toDouble();

    final maxTop = size.height - _ballSize - 96;
    final double width = expanded ? expandedWidth : _ballSize;
    final double height = expanded ? _pillHeight : _ballSize;
    final double left;
    final double top;
    if (expanded) {
      left = (size.width - expandedWidth) / 2;
      top = topY;
    } else if (dragging) {
      left = (_dragPos!.dx - _ballSize / 2)
          .clamp(0.0, size.width - _ballSize)
          .toDouble();
      top = (_dragPos!.dy - _ballSize / 2).clamp(topY, maxTop).toDouble();
    } else {
      left = _onLeft ? _edgePad : size.width - _ballSize - _edgePad;
      top = (_ballTop ?? topY).clamp(topY, maxTop).toDouble();
    }

    return AnimatedPositioned(
      duration: dragging ? Duration.zero : _morph,
      curve: Curves.easeInOutCubic,
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        // Tap: drawer from the pill (details + controls live there), morph
        // back out from the ball.
        onTap: expanded ? _openSheet : _expand,
        // Swipe the pill toward an edge -> it becomes the ball on that
        // edge, at the default height.
        onHorizontalDragEnd: expanded
            ? (d) {
                final vx = d.velocity.pixelsPerSecond.dx;
                if (vx.abs() < 150) return;
                _holdTimer?.cancel();
                _holdTimer = null;
                setState(() {
                  _onLeft = vx < 0;
                  _ballTop = null;
                  _minimized = true;
                });
              }
            : null,
        onPanStart: expanded
            ? null
            : (d) => setState(() => _dragPos = d.globalPosition),
        onPanUpdate: expanded
            ? null
            : (d) => setState(() => _dragPos = d.globalPosition),
        onPanEnd: expanded
            ? null
            : (d) {
                final at = _dragPos;
                if (at == null) return;
                final vx = d.velocity.pixelsPerSecond.dx;
                setState(() {
                  // A real fling beats position: throw it to the edge it
                  // points at (which may be the opposite one).
                  _onLeft =
                      vx.abs() > 500 ? vx < 0 : at.dx < size.width / 2;
                  _ballTop =
                      (at.dy - _ballSize / 2).clamp(topY, maxTop).toDouble();
                  _dragPos = null;
                });
              },
        child: AnimatedContainer(
          duration: dragging ? Duration.zero : _morph,
          curve: Curves.easeInOutCubic,
          decoration: BoxDecoration(
            color: cs.surfaceContainerHigh,
            // rPill (999) rounds both shapes: pill when wide, circle at 44.
            borderRadius: BorderRadius.circular(t.rPill),
            border: Border.all(
                color: failed && terminal
                    ? t.danger.withAlpha(160)
                    : cs.outline.withAlpha(90)),
            boxShadow: expanded
                ? const []
                : [
                    BoxShadow(
                      color: Colors.black.withAlpha(40),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.center,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: expanded
                ? _pillContent(context, task, terminal, failed, expandedWidth,
                    label, labelStyle, extra)
                : _ballContent(context, task, terminal, failed),
          ),
        ),
      ),
    );
  }

  Widget _leadingFor(BuildContext context, ActivityTask task, bool terminal,
      bool failed, double dim) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    if (terminal) {
      return ThemeIcon(failed ? 'warning' : 'check',
          color: failed ? t.danger : cs.primary, size: dim);
    }
    return SizedBox(
      width: dim,
      height: dim,
      child: CircularProgressIndicator(
        value: task.fraction,
        strokeWidth: 3,
        // A faint full track so 0% still reads as a loader filling in,
        // not an empty hole.
        backgroundColor: cs.onSurface.withAlpha(31),
      ),
    );
  }

  Widget _ballContent(
      BuildContext context, ActivityTask task, bool terminal, bool failed) {
    return KeyedSubtree(
      key: const ValueKey('ball'),
      child: _leadingFor(context, task, terminal, failed, 22),
    );
  }

  Widget _pillContent(
      BuildContext context,
      ActivityTask task,
      bool terminal,
      bool failed,
      double expandedWidth,
      String label,
      TextStyle labelStyle,
      int extra) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    // OverflowBox pins the row at its full width during the morph, so the
    // shrinking container clips it instead of the Row overflowing.
    return KeyedSubtree(
      key: const ValueKey('pill'),
      child: OverflowBox(
        minWidth: expandedWidth,
        maxWidth: expandedWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _leadingFor(context, task, terminal, failed, 24),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle.copyWith(color: cs.onSurface),
                ),
              ),
              if (extra > 0) ...[
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
