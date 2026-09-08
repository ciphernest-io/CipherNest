import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/routes.dart';
import '../../utils/atomic_write.dart';
import '../../models/album_model.dart';
import '../../../services/backup_backfill_runner.dart';
import '../../../services/backup_selection_service.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/migration_service.dart';
import '../../../services/sync_service.dart';
import '../settings/backup_albums_screen.dart';
import 'gallery_chrome.dart';

class AlbumsTab extends StatefulWidget {
  const AlbumsTab({super.key, this.chrome});

  /// Scroll-driven chrome bridge to GalleryScreen's floating overlays.
  final GalleryChrome? chrome;

  @override
  State<AlbumsTab> createState() => AlbumsTabState();
}

class AlbumsTabState extends State<AlbumsTab>
    with SingleTickerProviderStateMixin {
  static const _kViewModePref = 'albums_view_mode';

  /// Continuous view position: 0 = list, 1 = 3-across, 2 = 2-across.
  /// Driven LIVE by the pinch — the layout follows the fingers — and
  /// settled to the nearest whole mode on release.
  double _viewProgress = 1.0;
  late final AnimationController _settleCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 260));
  double _settleFrom = 1.0;
  double _settleTo = 1.0;

  // Raw-pointer pinch (same reasons as the photo grid: a scale recognizer
  // loses the arena to the scroll drag).
  final Map<int, Offset> _pinchPointers = {};
  bool _pinchActive = false;
  double? _pinchBaseline;
  double _pinchStartProgress = 1.0;

  // Header-reveal gate. A pinch must NOT pull the hidden "Albums" title down.
  // The title reveals purely from scroll offset, so the fix is to stop the
  // scroll from ever revealing it while a pinch could be forming: the physics
  // stays LOCKED (parked at the collapsed offset) whenever a second finger is
  // down, or while a lone finger hasn't yet committed to a deliberate pull.
  // A single finger only unlocks the reveal after dragging past a small
  // threshold — long enough that the first finger of a pinch never leaks.
  Offset? _singleDragStart;
  bool _revealConfirmed = false;

  bool _isHeaderLocked() {
    if (_startedBelowFold) return true; // classic: a drag that began below fold
    if (_pinchActive || _pinchPointers.length >= 2) return true; // pinching
    if (_pinchPointers.length == 1 && !_revealConfirmed) return true; // ambiguous
    return false;
  }

  double _pinchSpan() {
    final pts = _pinchPointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pinchPointers[e.pointer] = e.position;
    if (_pinchPointers.length == 1) {
      // A lone finger starts ambiguous (reveal vs. first pinch finger): keep
      // the header locked until this finger commits to a deliberate pull.
      _singleDragStart = e.position;
      _revealConfirmed = false;
    }
    if (_pinchPointers.length == 2) {
      _settleCtrl.stop();
      setState(() {
        _pinchActive = true;
        _pinchBaseline = _pinchSpan();
        _pinchStartProgress = _viewProgress;
        _slackHeld = true; // hold tail slack across the whole gesture
      });
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pinchPointers.containsKey(e.pointer)) return;
    _pinchPointers[e.pointer] = e.position;
    if (!_pinchActive) {
      // Lone finger: only a deliberate downward pull (past a small threshold)
      // commits to a reveal and unlocks the header. A pinch's fingers land
      // together before this fires, so the header stays locked and can't leak.
      if (_pinchPointers.length == 1 && !_revealConfirmed) {
        final start = _singleDragStart;
        if (start != null && e.position.dy - start.dy > 16) {
          _revealConfirmed = true;
        }
      }
    }
    if (!_pinchActive || _pinchPointers.length < 2) return;
    final span = _pinchSpan();
    final baseline = _pinchBaseline;
    if (baseline == null || baseline <= 0) {
      _pinchBaseline = span;
      return;
    }
    // Continuous: the layout tracks the fingers directly — one 1.7x span
    // change walks one full view step; release snaps to the nearest mode.
    final delta = math.log(span / baseline) / math.log(1.7);
    final next =
        (_pinchStartProgress + delta).clamp(0.0, 2.0).toDouble();
    if ((next - _viewProgress).abs() > 0.001) {
      setState(() => _viewProgress = next);
    }
  }

  void _onPointerEnd(PointerEvent e) {
    _pinchPointers.remove(e.pointer);
    if (_pinchPointers.length < 2) {
      _pinchBaseline = null;
    } else {
      // The measured pair changed (a finger of three lifted): re-baseline
      // so the layout doesn't leap.
      _pinchBaseline = _pinchSpan();
      _pinchStartProgress = _viewProgress;
    }
    if (_pinchPointers.isEmpty) {
      _singleDragStart = null;
      _revealConfirmed = false;
    }
    if (_pinchPointers.isEmpty && _pinchActive) {
      setState(() => _pinchActive = false);
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

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_kViewModePref);
    if (saved == null || !mounted) return;
    setState(() => _viewProgress = saved.clamp(0, 2).toDouble());
  }

  Widget _entryCard(_AlbumEntry entry, double t) {
    final album = entry.album;
    if (album == null) return _buildCreateCard(t);
    return _AlbumCard(
      key: ValueKey(entry.id),
      album: album,
      gridness: t,
      onTap: () => _openAlbum(album),
    );
  }

  // OneUI header: same reveal pattern as PicturesTab.
  ScrollController? _scrollCtrl;
  double _headerH = 0;
  Timer? _motionTimer;
  bool _startedBelowFold = true;
  double _bottomFiller = 0;

  // A full viewport of tail slack, held from the pinch start through the
  // settle AND the frame the real filler lands, so the morph can shrink the
  // content (the 3-across middle rung is the shortest) without the scroll
  // clamping down and dragging the title into view. Dropped only once
  // _ensureHeaderReachable has set the correct _bottomFiller for the settled
  // layout, so removing the slack can't cause a clamp.
  bool _slackHeld = false;
  double _slackPx = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scrollCtrl == null) {
      _headerH = MediaQuery.sizeOf(context).height * 0.30;
      _scrollCtrl = ScrollController(initialScrollOffset: _headerH)
        ..addListener(_onScrollTick);
    }
  }

  void _onScrollTick() {
    final chrome = widget.chrome;
    final ctrl = _scrollCtrl;
    if (chrome == null || ctrl == null || !ctrl.hasClients) return;
    final under = ctrl.offset > _headerH + 8;
    if (chrome.scrolledUnder.value != under) {
      chrome.scrolledUnder.value = under;
    }
    chrome.headerReveal.value =
        (_headerH - ctrl.offset).clamp(0.0, _headerH).toDouble();
  }

  /// Re-publish scroll-derived chrome state (used after tab switches).
  void reportChrome() => _onScrollTick();

  /// Tail slack for this frame (a full viewport while a gesture is live or
  /// the settled filler hasn't landed), recording the amount so
  /// _ensureHeaderReachable can subtract it from the measured scroll extent.
  double _slackFor(BuildContext context) {
    final held = _pinchActive || _settleCtrl.isAnimating || _slackHeld;
    _slackPx = held ? MediaQuery.sizeOf(context).height : 0.0;
    return _slackPx;
  }

  /// Keeps offset == _headerH reachable when the morph (or a settled
  /// short layout) shrinks the content — otherwise the clamp pulls the
  /// scroll down and the title box gets dragged into view mid-pinch.
  void _ensureHeaderReachable() {
    if (!mounted) return;
    final ctrl = _scrollCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    // The content's own contribution to the scroll extent, with BOTH the
    // tail filler and the (possibly present) slack removed — otherwise the
    // slack makes the content look tall and we under-fill, so dropping the
    // slack later clamps the offset and reveals the title.
    final maxExtent = ctrl.position.maxScrollExtent;
    final contentExtent = maxExtent - _bottomFiller - _slackPx;
    final needed = (_headerH - contentExtent + 4)
        .clamp(0.0, _headerH + ctrl.position.viewportDimension)
        .toDouble();
    if ((needed - _bottomFiller).abs() > 1) {
      setState(() => _bottomFiller = needed);
      return;
    }
    // Filler is correct for the settled layout now. If the gesture is fully
    // over, drop the slack — with _bottomFiller already right, offset ==
    // _headerH stays reachable, so nothing clamps and the title stays put.
    if (_slackHeld && !_pinchActive && !_settleCtrl.isAnimating) {
      setState(() => _slackHeld = false);
    }
  }

  bool _onScrollNotification(ScrollNotification n) {
    final chrome = widget.chrome;
    if (chrome == null || n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _startedBelowFold = n.metrics.pixels > _headerH + 0.5;
    }
    if (n is ScrollUpdateNotification) {
      final delta = n.scrollDelta ?? 0;
      if (delta > 1) {
        chrome.chromeHidden.value = true;
      } else if (delta < -1) {
        chrome.chromeHidden.value = false;
      }
      _motionTimer?.cancel();
      _motionTimer = Timer(const Duration(milliseconds: 700), () {
        chrome.chromeHidden.value = false;
      });
    }
    return false;
  }

  /// Shell entry (the + button in the floating top bar).
  void createAlbum() => _createAlbum();

  Widget _bigHeader() {
    final ctrl = _scrollCtrl;
    if (ctrl == null) return const SizedBox.shrink();
    final count = _albums.length + _deviceAlbums.length;
    return SizedBox(
      height: _headerH,
      child: AnimatedBuilder(
        animation: ctrl,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final off = ctrl.hasClients ? ctrl.offset : _headerH;
          // While a pinch is active or settling, ignore the live offset (the
          // inline morph is shifting it) and hold the pre-pinch fraction.
          final frac = (1 - off / _headerH).clamp(0.0, 1.0);
          return Opacity(
            opacity: Curves.easeIn.transform(frac),
            child: Padding(
              padding: EdgeInsets.only(
                  top: MediaQuery.paddingOf(context).top + 12),
              child: Align(
                alignment: const Alignment(0, 0.45),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Albums',
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '$count album${count == 1 ? '' : 's'}',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.55),
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              ),
            ),
          );
        },
      ),
    );
  }

  List<CnestAlbum> _albums = [];
  List<CnestAlbum> _deviceAlbums = [];
  bool _loading = true;

  /// Reveal toggle: shows this phone's MediaStore buckets that are NOT
  /// enrolled for backup, dimmed, so what's unprotected is visible.
  bool _reveal = false;
  BackupMode _mode = BackupMode.all;
  List<AlbumInfo> _unbacked = [];

  @override
  void initState() {
    super.initState();
    _settleCtrl.addListener(() {
      final v = Curves.easeOutCubic.transform(_settleCtrl.value);
      setState(() =>
          _viewProgress = _settleFrom + (_settleTo - _settleFrom) * v);
    });
    _settleCtrl.addStatusListener((status) {
      // One more rebuild after the settle so the pinch spacer drops.
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
    SyncService().syncNotifier.addListener(_reload);
    // Rebuild album covers when files are added, deleted, or restored —
    // getAlbumCoverFile now filters is_deleted and falls back to the next
    // non-deleted file automatically.
    DatabaseService().addListener(_reload);
    _reload();
    _loadViewMode();
  }

  @override
  void dispose() {
    _motionTimer?.cancel();
    _scrollCtrl?.dispose();
    _settleCtrl.dispose();
    SyncService().syncNotifier.removeListener(_reload);
    DatabaseService().removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    () async {
      final albums = await DatabaseService().getAlbums();
      final device = await DatabaseService().getDeviceAlbums();
      if (!mounted) return;
      setState(() {
        _albums = albums;
        _deviceAlbums = device;
        _loading = false;
      });
      if (_reveal) await _loadUnbacked();
    }();
  }

  /// Buckets on THIS phone not covered by the backup selection. In `all`
  /// mode everything is covered, so the list is empty by construction.
  Future<void> _loadUnbacked() async {
    final selection = await BackupSelectionService().load();
    var unbacked = <AlbumInfo>[];
    if (selection.mode == BackupMode.selected) {
      final all = await MigrationService().getAlbums();
      unbacked = all
          .where((a) => !a.path.isAll && !selection.includes(a.name))
          .toList();
    }
    if (!mounted) return;
    setState(() {
      _mode = selection.mode;
      _unbacked = unbacked;
    });
  }

  Future<void> _toggleReveal(bool v) async {
    setState(() => _reveal = v);
    if (v) await _loadUnbacked();
  }

  Future<void> _enrollUnbacked(AlbumInfo album) async {
    final backfill = await showBackupEnrollSheet(context, album.name,
        existingCount: album.count);
    if (backfill == null) return;
    await BackupSelectionService().enroll(album.name, backfill: backfill);
    if (backfill) unawaited(BackupBackfillRunner().runPending());
    await _loadUnbacked();
  }

  Future<void> _createAlbum() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('New Album'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Album name'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('Create')),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    await DatabaseService().createAlbum(name);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());

    final cs = Theme.of(context).colorScheme;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _ensureHeaderReachable());

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerEnd,
      onPointerCancel: _onPointerEnd,
      child: NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView(
      controller: _scrollCtrl,
      physics: _pinchActive
          ? const NeverScrollableScrollPhysics()
          : HeaderSnapPhysics(
              collapsedOffset: _headerH,
              headerLocked: _isHeaderLocked,
              parent: const AlwaysScrollableScrollPhysics(),
            ),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 120),
      children: [
        _bigHeader(),
        // Collapsed state: content starts below the floating buttons.
        SizedBox(height: MediaQuery.paddingOf(context).top + 56),
        if (_deviceAlbums.isNotEmpty) ...[
          _sectionHeader('On this phone', cs),
          // Keys stay LOAD-BEARING: card state (the loaded cover) must
          // travel with its album across list shifts and mode morphs.
          _MorphAlbumGrid(
            progress: _viewProgress,
            entries: [
              for (final album in _deviceAlbums)
                _AlbumEntry(album.id, album),
            ],
            buildCard: _entryCard,
          ),
        ],
        _sectionHeader('My albums', cs,
            subtitle: 'Synced across your devices'),
        _MorphAlbumGrid(
          progress: _viewProgress,
          entries: [
            for (final album in _albums) _AlbumEntry(album.id, album),
            const _AlbumEntry('__create__', null),
          ],
          buildCard: _entryCard,
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          title: Text('Show albums not backed up',
              style: TextStyle(color: cs.onSurface, fontSize: 14)),
          value: _reveal,
          onChanged: _toggleReveal,
        ),
        if (_reveal) ...[
          if (_mode == BackupMode.all)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                'Every album on this phone is backed up.',
                style: TextStyle(
                    color: cs.onSurface.withAlpha(120), fontSize: 12),
              ),
            )
          else if (_unbacked.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                'All your albums are backed up.',
                style: TextStyle(
                    color: cs.onSurface.withAlpha(120), fontSize: 12),
              ),
            )
          else
            _grid([
              for (final album in _unbacked) _unbackedCard(album, cs),
            ]),
        ],
        // Header-reachability filler; while the gesture is live (and until
        // the settled filler lands) a full viewport of slack is added so the
        // morph's height changes can never clamp the scroll into the title
        // box. _slackPx records how much, so _ensureHeaderReachable can back
        // it out of its filler math.
        SizedBox(height: _bottomFiller + _slackFor(context)),
      ],
      ),
      ),
    );
  }

  Future<void> _openAlbum(CnestAlbum album) async {
    await Navigator.pushNamed(
      context,
      AppRoutes.albumDetail,
      arguments: album,
    );
    _reload();
  }

  Widget _sectionHeader(String title, ColorScheme cs, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle,
                style: TextStyle(
                    color: cs.onSurface.withAlpha(120), fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Widget _grid(List<Widget> cards) {
    // 210 is load-bearing: the ListView pads 12 each side, so 411 gives
    // (387-10)/2 = 188.5 wide tiles -> still exactly 2 columns (320 too);
    // 891 landscape gets 4 instead of two 428 px tiles.
    return GridView.extent(
      maxCrossAxisExtent: 210,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 0.85,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: cards,
    );
  }

  /// A local bucket that is NOT backed up: dimmed, tap to enroll.
  Widget _unbackedCard(AlbumInfo album, ColorScheme cs) {
    final t = ThemeController().tokens;
    return GestureDetector(
      onTap: () => _enrollUnbacked(album),
      child: Opacity(
        opacity: 0.5,
        child: Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(t.rCard),
            border: Border.all(color: cs.outline),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  color: cs.surfaceContainerHighest,
                  child: ThemeIcon('images',
                      color: cs.onSurface.withAlpha(60), size: 40),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(album.name,
                        style: TextStyle(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 14),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    Text('${album.count} · not backed up',
                        style: TextStyle(
                            color: cs.onSurface.withAlpha(120),
                            fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCreateCard(double g0) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final g = g0.clamp(0.0, 1.0).toDouble();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _createAlbum,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final boxRect = Rect.lerp(
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
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(t.rCard),
                  border: Border.all(color: cs.outline),
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ThemeIcon('plus',
                            color: cs.onSurface.withAlpha(140), size: 40),
                        // The label only claims vertical space as the card
                        // morphs toward the grid state; at g=0 (list view) it
                        // collapses to zero height so the plus sits at the
                        // card's true vertical centre rather than being
                        // shoved up by an invisible (opacity 0) label.
                        Align(
                          heightFactor: g,
                          child: Opacity(
                            opacity: g,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text('Create Album',
                                  style: TextStyle(
                                      color: cs.onSurface.withAlpha(140),
                                      fontSize: 13)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: size.height + 12,
              // Width-safe at every g (a left/right pair went negative
              // mid-morph), and staying mounted lets the 160ms fade-out
              // FINISH instead of popping out at the old g=0.5 unmount.
              width: math.max(0.0, size.width - size.height - 20),
              top: 0,
              bottom: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: g <= 0.001 ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 160),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Create album',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(140),
                              fontSize: 14,
                              fontWeight: FontWeight.w600)),
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

class _AlbumCard extends StatefulWidget {
  final CnestAlbum album;
  final VoidCallback onTap;

  /// 0 = list row (the box IS the square cover; text sits beside it),
  /// 1 = grid card (the cover fills the card; text overlaid at the
  /// bottom). The pinch drives values in between: the box rect and both
  /// text layers interpolate continuously.
  final double gridness;

  const _AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.gridness = 1.0,
  });

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
  Uint8List? _coverBytes;

  @override
  void initState() {
    super.initState();
    _loadCover();
  }

  @override
  void didUpdateWidget(covariant _AlbumCard old) {
    super.didUpdateWidget(old);
    // Re-run the cover load when the album's cover identity may have
    // changed. initState-only loading kept a DELETED or HIDDEN photo on
    // screen as the cover for the whole gallery session (the tab lives in
    // an IndexedStack, so this State can survive for hours) — in a privacy
    // vault that's not just staleness. fileCount is the cheap proxy for
    // "the auto-cover candidates changed" (delete/restore/hide all move it).
    if (old.album.id != widget.album.id ||
        old.album.coverFileId != widget.album.coverFileId ||
        old.album.fileCount != widget.album.fileCount) {
      setState(() => _coverBytes = null);
      _loadCover();
    }
  }

  Future<void> _loadCover() async {
    final coverFile =
        await DatabaseService().getAlbumCoverFile(widget.album);
    if (coverFile == null) return;

    // MediaStore path first: if the file was ingested with an assetId
    // (auto-sync + manual upload with the S19 resolver), we can pull the
    // OS-generated thumbnail bytes without writing anything to our own
    // cache directory. Zero new bytes on disk, instant paint. This is
    // what removes the "browsing Albums grows the cache" symptom.
    if (coverFile.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(coverFile.assetId!);
        if (asset != null) {
          final thumb =
              await asset.thumbnailDataWithSize(const ThumbnailSize(300, 300));
          if (thumb != null && mounted) {
            setState(() => _coverBytes = thumb);
            return;
          }
        }
      } catch (e) {
        // Fall through to the encrypted-cache path below. The MediaStore
        // entry may have been deleted or moved since we ingested it.
        debugPrint('Album cover MediaStore lookup failed: $e');
      }
    }

    final targetId = coverFile.thumbnailCloudId ?? coverFile.cloudId;
    if (targetId == null) return;

    try {
      final cacheDir = await getTemporaryDirectory();
      final isThumbnail = coverFile.thumbnailCloudId != null;
      final fileName = isThumbnail
          ? 'thumb_${coverFile.cloudId}.jpg'
          : '${coverFile.cloudId}_decrypted.jpg';
      final cacheFile = File('${cacheDir.path}/$fileName');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() => _coverBytes = bytes);
        return;
      }

      final enc = await CloudService().downloadFile(targetId);
      final dec = await EncryptionService.decryptFile(enc);
      await atomicWriteBytes(cacheFile, dec);
      if (mounted) setState(() => _coverBytes = dec);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final g = widget.gridness.clamp(0.0, 1.0).toDouble();
    Widget cover() => _coverBytes != null
        ? Image.memory(_coverBytes!, fit: BoxFit.cover)
        : Container(
            color: cs.surfaceContainerHighest,
            child: ThemeIcon(
              widget.album.isSmart
                  ? _smartAlbumIcon(widget.album.smartQuery)
                  : 'folderSimple',
              color: cs.onSurface.withAlpha(60),
              size: 32,
            ),
          );

    // The card's outer rect is interpolated by _MorphAlbumGrid; inside it
    // the visible BOX morphs between "the whole card" (grid) and "the
    // height-sized square on the left" (list). The overlay text fades out
    // with the morph; the beside-text fades in only once the morph lands
    // on the list — Samsung's exact order.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: LayoutBuilder(builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        final boxRect = Rect.lerp(
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
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(t.rCard),
                  border: Border.all(color: cs.outline),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    cover(),
                    if (g > 0.001)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Opacity(
                          opacity: g,
                          child: Container(
                            padding:
                                const EdgeInsets.fromLTRB(10, 18, 10, 8),
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
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(widget.album.name,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 1),
                                Text('${widget.album.fileCount}',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11)),
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
              // Width-safe at every g (a left/right pair went negative
              // mid-morph), and staying mounted lets the 160ms fade-out
              // FINISH instead of popping out at the old g=0.5 unmount.
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
                        Text(widget.album.name,
                            style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text('${widget.album.fileCount}',
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

  String _smartAlbumIcon(String? query) {
    if (query != null && query.startsWith('device:')) return 'smartphone';
    switch (query) {
      case 'all_images':
        return 'images';
      case 'camera':
        return 'camera';
      case 'screenshots':
        return 'screencast';
      case 'videos':
        return 'videoCamera';
      default:
        return 'folderSimple';
    }
  }
}


class _AlbumEntry {
  const _AlbumEntry(this.id, this.album);
  final String id;
  final CnestAlbum? album; // null = the "create album" card
}

/// Progress-driven album layout: 0 = list rows, 1 = 3-across, 2 =
/// 2-across. Every card rect is a lerp between the two neighboring
/// layouts, so the pinch MOVES the cards continuously — no fades, no
/// threshold snap — and each card's aspect morphs with its rect. Stable
/// keys keep card state (the loaded cover) riding along.
class _MorphAlbumGrid extends StatelessWidget {
  const _MorphAlbumGrid({
    required this.entries,
    required this.progress,
    required this.buildCard,
  });

  final List<_AlbumEntry> entries;
  final double progress;
  final Widget Function(_AlbumEntry, double) buildCard;

  Rect _rectFor(int i, int modeIdx, double w) {
    if (modeIdx == 0) return Rect.fromLTWH(0, i * 84.0, w, 76);
    final cols = modeIdx == 1 ? 3 : 2;
    final tw = (w - (cols - 1) * 10) / cols;
    final th = tw * 4 / 3;
    return Rect.fromLTWH(
        (i % cols) * (tw + 10), (i ~/ cols) * (th + 10), tw, th);
  }

  double _heightFor(int modeIdx, double w) {
    if (entries.isEmpty) return 0;
    if (modeIdx == 0) return entries.length * 84.0 - 8;
    final cols = modeIdx == 1 ? 3 : 2;
    final tw = (w - (cols - 1) * 10) / cols;
    final th = tw * 4 / 3;
    final rows = (entries.length / cols).ceil();
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
      final totalH = _heightFor(lo, w) +
          (_heightFor(hi, w) - _heightFor(lo, w)) * f;
      return SizedBox(
        height: totalH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < entries.length; i++)
              Positioned.fromRect(
                key: ValueKey('pos-${entries[i].id}'),
                rect: Rect.lerp(
                    _rectFor(i, lo, w), _rectFor(i, hi, w), f)!,
                child: buildCard(entries[i], gridness),
              ),
          ],
        ),
      );
    });
  }
}
