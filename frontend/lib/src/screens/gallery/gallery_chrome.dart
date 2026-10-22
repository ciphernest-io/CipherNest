import 'package:flutter/widgets.dart';

/// Scroll-driven state for the OneUI-style gallery chrome. PicturesTab
/// (which owns the scroll view) writes; GalleryScreen's floating overlays
/// (top buttons pill, bottom nav pill, back-to-top) listen. Kept as plain
/// ValueNotifiers so each overlay rebuilds only on the bit it cares about.
class GalleryChrome {
  /// Content is scrolled under the top buttons: their translucent pill
  /// background fades in. False while the big header is revealed.
  final ValueNotifier<bool> scrolledUnder = ValueNotifier(false);

  /// Actively scrolling downward: both pills hide until motion stops.
  final ValueNotifier<bool> chromeHidden = ValueNotifier(false);

  /// In motion and far from the top: the back-to-top button shows, and
  /// fades shortly after motion stops.
  final ValueNotifier<bool> showBackToTop = ValueNotifier(false);

  /// Selection mode is active (its own bar owns the top edge).
  final ValueNotifier<bool> selectionActive = ValueNotifier(false);

  /// How many px of the big header are currently revealed (0..headerH).
  /// The floating top buttons ride down by this amount so they never sit
  /// inside the title box.
  final ValueNotifier<double> headerReveal = ValueNotifier(0);

  /// Selected-photo count (drives the floating selection bar's label).
  final ValueNotifier<int> selectionCount = ValueNotifier(0);

  /// A tab has a pinch in progress: the shell must not read the fingers as
  /// a swipe to the next tab.
  final ValueNotifier<bool> swipeLocked = ValueNotifier(false);

  void dispose() {
    scrolledUnder.dispose();
    chromeHidden.dispose();
    showBackToTop.dispose();
    selectionActive.dispose();
    headerReveal.dispose();
    selectionCount.dispose();
    swipeLocked.dispose();
  }
}

/// ClampingScrollPhysics with a hard stop at [collapsedOffset] while
/// [headerLocked] returns true: scrolling up from below the fold parks at
/// the collapsed grid top; only a NEW swipe (which starts AT the stop and
/// therefore unlocks) reveals the title box. This is the OneUI "friction"
/// before the header.
class HeaderSnapPhysics extends ClampingScrollPhysics {
  const HeaderSnapPhysics({
    required this.collapsedOffset,
    required this.headerLocked,
    super.parent,
  });

  final double collapsedOffset;
  final bool Function() headerLocked;

  @override
  HeaderSnapPhysics applyTo(ScrollPhysics? ancestor) => HeaderSnapPhysics(
        collapsedOffset: collapsedOffset,
        headerLocked: headerLocked,
        parent: buildParent(ancestor),
      );

  double get _minAllowed => headerLocked() ? collapsedOffset : 0.0;

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    final min = _minAllowed;
    if (min > 0 && value < min && position.pixels >= min) {
      return value - min; // absorb the part that would reveal the header
    }
    return super.applyBoundaryConditions(position, value);
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    final min = _minAllowed;
    if (min > 0 && velocity < 0 && position.pixels > min) {
      return super.createBallisticSimulation(
        position.copyWith(minScrollExtent: min),
        velocity,
      );
    }
    return super.createBallisticSimulation(position, velocity);
  }
}
