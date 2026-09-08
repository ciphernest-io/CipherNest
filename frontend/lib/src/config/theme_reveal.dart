import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Flutter answer to the web View-Transitions "circle reveal" on theme change.
///
/// The browser trick snapshots the old theme, swaps to the new one underneath,
/// then grows a circular clip that reveals the new theme from a point. There is
/// no platform API for that here, so we do it by hand:
///   1. raster the whole screen (old theme) off a [RepaintBoundary],
///   2. drop that snapshot into an overlay ABOVE the live UI,
///   3. flip the theme underneath (the live tree re-themes),
///   4. animate a growing circular HOLE punched out of the snapshot, so the
///      new theme shows through the hole and spreads from the tap point.
///
/// One-shot, self-cleaning, and a no-op fallback (just applies the theme) if a
/// snapshot can't be taken.
class ThemeReveal {
  ThemeReveal._();

  /// Wraps the app content in [App]'s builder so the whole screen can be
  /// captured in the current theme.
  static final GlobalKey boundaryKey = GlobalKey();

  static bool _running = false;

  static Future<void> run({
    required BuildContext context,
    required Offset center,
    required VoidCallback apply,
    Duration duration = const Duration(milliseconds: 480),
  }) async {
    // Overlapping reveals would fight over the snapshot; just apply.
    if (_running) {
      apply();
      return;
    }
    final boundary =
        boundaryKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (boundary == null || overlay == null) {
      apply();
      return;
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    ui.Image image;
    try {
      // Synchronous capture: no dropped frame between snapshot and swap.
      image = boundary.toImageSync(pixelRatio: dpr);
    } catch (_) {
      apply();
      return;
    }

    _running = true;
    final size = boundary.size;
    final maxRadius = _maxRadius(center, size);
    final provider = _RevealTickerProvider();
    final controller = AnimationController(vsync: provider, duration: duration);
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOut);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _RevealOverlay(
        image: image,
        center: center,
        maxRadius: maxRadius,
        animation: curved,
      ),
    );
    overlay.insert(entry);

    // Swap the theme UNDER the frozen old-theme snapshot.
    apply();

    try {
      await controller.forward();
    } finally {
      entry.remove();
      curved.dispose();
      controller.dispose();
      image.dispose();
      _running = false;
    }
  }

  /// Distance from [c] to the farthest screen corner — the radius at which the
  /// circle fully covers the viewport.
  static double _maxRadius(Offset c, Size s) {
    final dx = math.max(c.dx, s.width - c.dx);
    final dy = math.max(c.dy, s.height - c.dy);
    return math.sqrt(dx * dx + dy * dy);
  }
}

/// A [TickerProvider] not tied to a [State] — the reveal outlives the widget
/// that triggered it (the toggle can rebuild mid-animation), so the animation
/// is driven from a standalone ticker.
class _RevealTickerProvider extends TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

class _RevealOverlay extends StatelessWidget {
  const _RevealOverlay({
    required this.image,
    required this.center,
    required this.maxRadius,
    required this.animation,
  });

  final ui.Image image;
  final Offset center;
  final double maxRadius;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: animation,
          builder: (_, _) => CustomPaint(
            painter: _RevealPainter(
              image: image,
              center: center,
              radius: maxRadius * animation.value,
            ),
          ),
        ),
      ),
    );
  }
}

class _RevealPainter extends CustomPainter {
  _RevealPainter({
    required this.image,
    required this.center,
    required this.radius,
  });

  final ui.Image image;
  final Offset center;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    // Full screen minus a growing circle = the old snapshot everywhere except
    // where the new theme should show through.
    final full = Path()..addRect(Offset.zero & size);
    final hole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    canvas.clipPath(Path.combine(PathOperation.difference, full, hole));
    paintImage(
      canvas: canvas,
      rect: Offset.zero & size,
      image: image,
      fit: BoxFit.fill,
      filterQuality: FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_RevealPainter old) => old.radius != radius;
}
