import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/theme_controller.dart';
import '../../models/album_model.dart';
import 'widgets/music_widgets.dart';

/// The Playlists grid with the SAME pinch-to-zoom morph as gallery Albums:
/// pinch to move continuously between list rows (progress 0), 3-across (1),
/// and 2-across (2). Release snaps to the nearest rung and persists it. The
/// cards MOVE and morph continuously — no fades, no threshold snap — exactly
/// like [AlbumsTab].
class PlaylistsMorphView extends StatefulWidget {
  const PlaylistsMorphView({
    super.key,
    required this.playlists,
    required this.onOpen,
    required this.onLongPress,
    this.onPinchActive,
    this.bottomPadding = 0,
  });

  final List<CnestAlbum> playlists;
  final void Function(CnestAlbum) onOpen;

  /// Null for smart playlists (which have no actions sheet).
  final void Function(CnestAlbum)? onLongPress;

  /// Fires true while a pinch-zoom is in progress, false on release — the
  /// parent freezes tab-swiping so a pinch never flips to another tab.
  final ValueChanged<bool>? onPinchActive;
  final double bottomPadding;

  @override
  State<PlaylistsMorphView> createState() => _PlaylistsMorphViewState();
}

class _PlaylistsMorphViewState extends State<PlaylistsMorphView>
    with SingleTickerProviderStateMixin {
  static const _kViewModePref = 'playlists_view_mode';

  /// 0 = list rows, 1 = 3-across, 2 = 2-across. Driven live by the pinch.
  double _viewProgress = 1.0;
  late final AnimationController _settleCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  double _settleFrom = 1.0;
  double _settleTo = 1.0;

  // Raw-pointer pinch (a scale recognizer loses the arena to the scroll).
  final Map<int, Offset> _pinchPointers = {};
  bool _pinchActive = false;
  double? _pinchBaseline;
  double _pinchStartProgress = 1.0;

  @override
  void initState() {
    super.initState();
    _settleCtrl.addListener(() {
      final v = Curves.easeOutCubic.transform(_settleCtrl.value);
      setState(() =>
          _viewProgress = _settleFrom + (_settleTo - _settleFrom) * v);
    });
    _loadViewMode();
  }

  @override
  void dispose() {
    _settleCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_kViewModePref);
    if (saved == null || !mounted) return;
    setState(() => _viewProgress = saved.clamp(0, 2).toDouble());
  }

  double _pinchSpan() {
    final pts = _pinchPointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pinchPointers[e.pointer] = e.position;
    if (_pinchPointers.length == 2) {
      _settleCtrl.stop();
      setState(() {
        _pinchActive = true;
        _pinchBaseline = _pinchSpan();
        _pinchStartProgress = _viewProgress;
      });
      widget.onPinchActive?.call(true);
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pinchPointers.containsKey(e.pointer)) return;
    _pinchPointers[e.pointer] = e.position;
    if (!_pinchActive || _pinchPointers.length < 2) return;
    final span = _pinchSpan();
    final baseline = _pinchBaseline;
    if (baseline == null || baseline <= 0) {
      _pinchBaseline = span;
      return;
    }
    // Continuous: one 1.7x span change walks one full view step.
    final delta = math.log(span / baseline) / math.log(1.7);
    final next = (_pinchStartProgress + delta).clamp(0.0, 2.0).toDouble();
    if ((next - _viewProgress).abs() > 0.001) {
      setState(() => _viewProgress = next);
    }
  }

  void _onPointerEnd(PointerEvent e) {
    _pinchPointers.remove(e.pointer);
    if (_pinchPointers.length < 2) {
      _pinchBaseline = null;
    } else {
      // A finger of three lifted: re-baseline so the layout doesn't leap.
      _pinchBaseline = _pinchSpan();
      _pinchStartProgress = _viewProgress;
    }
    if (_pinchPointers.isEmpty && _pinchActive) {
      setState(() => _pinchActive = false);
      widget.onPinchActive?.call(false);
      _settleToNearest();
    }
  }

  void _settleToNearest() {
    _settleFrom = _viewProgress;
    _settleTo = _viewProgress.round().clamp(0, 2).toDouble();
    if ((_settleTo - _settleFrom).abs() < 0.001) {
      setState(() => _viewProgress = _settleTo);
    } else {
      _settleCtrl.forward(from: 0);
    }
    SharedPreferences.getInstance()
        .then((p) => p.setInt(_kViewModePref, _settleTo.round()));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: ListView(
        physics: _pinchActive
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + widget.bottomPadding),
        children: [
          _PlaylistMorphGrid(
            progress: _viewProgress,
            playlists: widget.playlists,
            buildCard: (playlist, g, coverWidth) => _PlaylistMorphCard(
              key: ValueKey(playlist.id),
              playlist: playlist,
              gridness: g,
              coverWidth: coverWidth,
              onTap: () => widget.onOpen(playlist),
              onLongPress: widget.onLongPress == null
                  ? null
                  : () => widget.onLongPress!(playlist),
            ),
          ),
        ],
      ),
    );
  }
}

/// Progress-driven playlist layout: 0 = list rows, 1 = 3-across, 2 =
/// 2-across. Every card rect is a lerp between the two neighboring layouts,
/// so the pinch MOVES the cards continuously. Stable keys keep each card's
/// resolved cover riding along.
class _PlaylistMorphGrid extends StatelessWidget {
  const _PlaylistMorphGrid({
    required this.playlists,
    required this.progress,
    required this.buildCard,
  });

  final List<CnestAlbum> playlists;
  final double progress;

  /// (playlist, gridness, coverWidth): coverWidth is the cover box width
  /// while morphing toward the list rung, null to fill the card.
  final Widget Function(CnestAlbum, double, double?) buildCard;

  Rect _rectFor(int i, int modeIdx, double w) {
    if (modeIdx == 0) return Rect.fromLTWH(0, i * 84.0, w, 76);
    final cols = modeIdx == 1 ? 3 : 2;
    final tw = (w - (cols - 1) * 10) / cols;
    // Square tiles (playlists are album-art squares, not portrait album cards).
    final th = tw;
    return Rect.fromLTWH(
        (i % cols) * (tw + 10), (i ~/ cols) * (th + 10), tw, th);
  }

  double _heightFor(int modeIdx, double w) {
    if (playlists.isEmpty) return 0;
    if (modeIdx == 0) return playlists.length * 84.0 - 8;
    final cols = modeIdx == 1 ? 3 : 2;
    final tw = (w - (cols - 1) * 10) / cols;
    // Square tiles (playlists are album-art squares, not portrait album cards).
    final th = tw;
    final rows = (playlists.length / cols).ceil();
    return rows * th + (rows - 1) * 10;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final p = progress.clamp(0.0, 2.0).toDouble();
      final lo = p.floor().clamp(0, 2);
      final hi = p.ceil().clamp(0, 2);
      final f = (p - lo).clamp(0.0, 1.0).toDouble();
      final gridness = p.clamp(0.0, 1.0).toDouble();
      final totalH =
          _heightFor(lo, w) + (_heightFor(hi, w) - _heightFor(lo, w)) * f;
      return SizedBox(
        height: totalH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < playlists.length; i++)
              Positioned.fromRect(
                key: ValueKey('pos-${playlists[i].id}'),
                rect: Rect.lerp(_rectFor(i, lo, w), _rectFor(i, hi, w), f)!,
                // Same rule as the gallery albums: toward the list rung the
                // cover shrinks from the 3-across tile straight to the 76 px
                // square, never through the widening card.
                child: buildCard(
                  playlists[i],
                  gridness,
                  p < 1.0
                      ? 76.0 + (_rectFor(i, 1, w).width - 76.0) * p
                      : null,
                ),
              ),
          ],
        ),
      );
    });
  }
}

/// One playlist card that morphs between a list row (0 = the box IS the
/// square cover, text beside it) and a grid tile (1 = the cover fills the
/// card, text overlaid at the bottom). Mirrors gallery's `_AlbumCard`.
class _PlaylistMorphCard extends StatelessWidget {
  const _PlaylistMorphCard({
    super.key,
    required this.playlist,
    required this.gridness,
    required this.onTap,
    this.onLongPress,
    this.coverWidth,
  });

  final CnestAlbum playlist;
  final double gridness;
  final double? coverWidth;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final g = gridness.clamp(0.0, 1.0).toDouble();

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final cw = coverWidth;
        final boxRect = cw != null
            ? Rect.fromLTWH(
                0, 0, cw.clamp(0.0, size.width).toDouble(), size.height)
            : Rect.lerp(
                Rect.fromLTWH(0, 0, size.height, size.height),
                Rect.fromLTWH(0, 0, size.width, size.height),
                g,
              )!;
        return Stack(
          children: [
            Positioned.fromRect(
              rect: boxRect,
              child: Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(t.rCard),
                  border: Border.all(color: cs.outline.withAlpha(90)),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PlaylistCover(coverFileId: playlist.coverFileId),
                    if (g > 0.001)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Opacity(
                          opacity: g,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                            decoration: const BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Color(0xB3000000),
                                  Color(0x00000000),
                                ],
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(playlist.name,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 1),
                                Text('${playlist.fileCount} tracks',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: size.height + 12,
              width: math.max(0.0, size.width - size.height - 20),
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: g <= 0.001 ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 160),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(playlist.name,
                          style: TextStyle(
                              color: cs.onSurface,
                              fontWeight: FontWeight.w600,
                              fontSize: 14),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text('${playlist.fileCount} tracks',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(120),
                              fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}
