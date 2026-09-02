import 'dart:io';

import 'package:flutter/painting.dart';

/// Device-tiered memory budgets for the image pipeline.
///
/// Flutter's default ImageCache (100 MiB) is smaller than ONE viewer page
/// decoded at 4096 px — opening a photo evicted every grid-thumbnail
/// decode, which is exactly the "grid goes black when I close a photo"
/// symptom. The budget is a ceiling, not a working set: entries are
/// evicted LRU and the whole cache is dropped on OS memory pressure.
class MediaBudget {
  MediaBudget._();

  /// Canonical thumbnail decode width shared by the grid (columns < 12),
  /// the justified layout, the viewer placeholder, the hero shuttle, and
  /// the filmstrip — ONE ImageCache entry per photo across all surfaces.
  static const int thumbDecodeWidth = 300;

  /// Dense rungs (12+ columns) decode small; tiles are ~13-33 dp.
  static const int denseThumbDecodeWidth = 120;

  static int imageCacheBytes = 384 << 20;
  static int viewerDecodeWidth = 2560;

  static Future<void> init() async {
    var highTier = true;
    try {
      // Plain procfs read — no plugin, ~0 ms. Unreadable (tests, desktop)
      // falls back to the high tier.
      final meminfo = await File('/proc/meminfo').readAsString();
      final m = RegExp(r'MemTotal:\s+(\d+) kB').firstMatch(meminfo);
      if (m != null) {
        highTier = int.parse(m.group(1)!) >= 6 * 1024 * 1024; // >= 6 GB
      }
    } catch (_) {}
    imageCacheBytes = (highTier ? 384 : 192) << 20;
    viewerDecodeWidth = highTier ? 2560 : 2048;
    PaintingBinding.instance.imageCache
      ..maximumSizeBytes = imageCacheBytes
      ..maximumSize = 2000; // the 28-col year rung holds ~1700 live tiles
  }
}
