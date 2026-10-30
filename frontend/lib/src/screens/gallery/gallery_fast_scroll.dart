import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/theme_controller.dart';

/// A Samsung-style fast-scroll handle: a draggable pill on the right edge of
/// a long grid. It fades in while the grid scrolls (or while held) and fades
/// out when idle. Dragging it scrubs straight to any point in the list.
///
/// Layered as a [Positioned.fill] child inside the grid's Stack. It drives
/// the SAME [ScrollController] the grid uses, so position stays in sync both
/// ways. [topInset] is the collapsed scroll offset the grid parks at (the
/// hidden pull-to-reveal header); scrubbing is mapped over the range below
/// it so the handle never scrolls back up into the header.
class GalleryFastScroll extends StatefulWidget {
  const GalleryFastScroll({
    super.key,
    required this.controller,
    this.topInset = 0,
    this.bottomInset = 0,
  });

  final ScrollController controller;
  final double topInset;
  final double bottomInset;

  @override
  State<GalleryFastScroll> createState() => _GalleryFastScrollState();
}

class _GalleryFastScrollState extends State<GalleryFastScroll> {
  static const double _thumbH = 52;
  static const double _trackTopPad = 8;
  static const double _trackBotPad = 12;
  // Below this much scrollable content the handle is more clutter than help.
  static const double _minScrollable = 1200;

  bool _visible = false;
  bool _dragging = false;
  Timer? _hideTimer;
  double _fraction = 0; // 0..1 of the scrubbable range

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(GalleryFastScroll old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  double get _scrubMin => widget.topInset;

  double? _scrubMax() {
    if (!widget.controller.hasClients) return null;
    final max = widget.controller.position.maxScrollExtent;
    if (max - _scrubMin < _minScrollable) return null; // too short to bother
    return max;
  }

  void _onScroll() {
    final max = _scrubMax();
    if (max == null) {
      if (_visible && !_dragging) setState(() => _visible = false);
      return;
    }
    if (_dragging) return; // the drag owns the position
    final off = widget.controller.offset.clamp(_scrubMin, max);
    final f = (off - _scrubMin) / (max - _scrubMin);
    setState(() {
      _fraction = f.clamp(0.0, 1.0);
      _visible = true;
    });
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted && !_dragging) setState(() => _visible = false);
    });
  }

  void _jumpToFraction(double f, double trackH) {
    final max = _scrubMax();
    if (max == null) return;
    final target = _scrubMin + f.clamp(0.0, 1.0) * (max - _scrubMin);
    widget.controller.jumpTo(target.clamp(_scrubMin, max));
  }

  @override
  Widget build(BuildContext context) {
    final max = _scrubMax();
    if (max == null && !_dragging) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    return Positioned(
      top: widget.topInset == 0 ? MediaQuery.paddingOf(context).top : 0,
      bottom: widget.bottomInset,
      right: 0,
      child: LayoutBuilder(
        builder: (context, _) {
          // The track height is the available column minus the handle and
          // its end pads; fraction 0 sits the handle at the top.
          return SizedBox(
            width: 40,
            child: _FastScrollColumn(
              visible: _visible || _dragging,
              dragging: _dragging,
              fraction: _fraction,
              thumbHeight: _thumbH,
              topPad: _trackTopPad,
              botPad: _trackBotPad,
              color: cs.surfaceContainerHighest,
              handleColor: cs.primary,
              radius: t.rPill,
              onDragStart: (localY, trackH) {
                _hideTimer?.cancel();
                setState(() {
                  _dragging = true;
                  _visible = true;
                });
                final f = _yToFraction(localY, trackH);
                setState(() => _fraction = f);
                _jumpToFraction(f, trackH);
              },
              onDragUpdate: (localY, trackH) {
                final f = _yToFraction(localY, trackH);
                setState(() => _fraction = f);
                _jumpToFraction(f, trackH);
              },
              onDragEnd: () {
                setState(() => _dragging = false);
                _scheduleHide();
              },
            ),
          );
        },
      ),
    );
  }

  double _yToFraction(double localY, double trackH) {
    final usable = trackH - _thumbH - _trackTopPad - _trackBotPad;
    if (usable <= 0) return 0;
    return ((localY - _trackTopPad - _thumbH / 2) / usable).clamp(0.0, 1.0);
  }
}

/// The visual column: an invisible full-height gesture lane on the right with
/// the handle positioned by [fraction]. Split out so it can measure its own
/// height via the parent constraints.
class _FastScrollColumn extends StatelessWidget {
  const _FastScrollColumn({
    required this.visible,
    required this.dragging,
    required this.fraction,
    required this.thumbHeight,
    required this.topPad,
    required this.botPad,
    required this.color,
    required this.handleColor,
    required this.radius,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool visible;
  final bool dragging;
  final double fraction;
  final double thumbHeight;
  final double topPad;
  final double botPad;
  final Color color;
  final Color handleColor;
  final double radius;
  final void Function(double localY, double trackH) onDragStart;
  final void Function(double localY, double trackH) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackH = constraints.maxHeight;
        final usable = trackH - thumbHeight - topPad - botPad;
        final top = topPad + fraction.clamp(0.0, 1.0) * (usable < 0 ? 0 : usable);
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: (d) =>
              onDragStart(d.localPosition.dy, trackH),
          onVerticalDragUpdate: (d) =>
              onDragUpdate(d.localPosition.dy, trackH),
          onVerticalDragEnd: (_) => onDragEnd(),
          onVerticalDragCancel: onDragEnd,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Stack(
              children: [
                Positioned(
                  top: top,
                  right: 6,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    width: dragging ? 18 : 8,
                    height: thumbHeight,
                    decoration: BoxDecoration(
                      color: dragging ? handleColor : color.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                        color: Colors.black.withValues(alpha: 0.12),
                      ),
                    ),
                    child: dragging
                        ? const Icon(Icons.drag_handle,
                            size: 14, color: Colors.white)
                        : null,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
