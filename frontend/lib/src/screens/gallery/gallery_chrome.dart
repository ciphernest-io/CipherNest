import 'package:flutter/foundation.dart';

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

  void dispose() {
    scrolledUnder.dispose();
    chromeHidden.dispose();
    showBackToTop.dispose();
    selectionActive.dispose();
  }
}
