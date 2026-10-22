import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/gallery_prefs.dart';
import '../../../services/sync_service.dart';
import 'gallery_chrome.dart';
import 'image_viewer_screen.dart';
import 'photo_hero.dart';
import 'pictures_tab.dart' show GalleryGridItem;

class StoriesTab extends StatefulWidget {
  const StoriesTab({super.key, this.chrome});

  /// Scroll-driven chrome bridge to GalleryScreen's floating overlays —
  /// identical wiring to Pictures/Albums so the search button rides the
  /// header reveal and the pill fades with scrolled-under.
  final GalleryChrome? chrome;

  @override
  State<StoriesTab> createState() => StoriesTabState();
}

/// One memory card in the Stories carousel: a titled 3:4 tile backed by a
/// set of files (opened as a filtered viewer on tap).
class _Story {
  final String title;
  final String? subtitle;
  final List<CnestFile> files;
  final bool video;
  const _Story(this.title, this.files, {this.subtitle, this.video = false});
  CnestFile get cover => files.first;
}

class StoriesTabState extends State<StoriesTab> {
  List<_Story> _stories = [];
  bool _loading = true;
  bool _showFeatured = true;
  bool _showYearAgo = true;

  static const _cardW = 165.0;
  static const _cardH = 220.0; // 3:4
  // A card is wider than a grid tile; decode its cover a step larger.
  static const _coverDecodeWidth = 400;

  // Hidden pull-to-reveal title, mirroring Pictures/Albums: the big "Stories"
  // heading lives inside the scroll view above the content and is revealed
  // by dragging down at the top.
  ScrollController? _scrollCtrl;
  double _headerH = 0;
  bool _headerLocked = true;
  double _bottomFiller = 0;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_reload);
    DatabaseService().addListener(_reload);
    // Settings toggles for "show featured" / "show a year ago" write through
    // GalleryPrefs; without this listener the toggle takes effect only on
    // the next sync or DB mutation.
    GalleryPrefs().changed.addListener(_reload);
    _reload();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_scrollCtrl == null) {
      _headerH = MediaQuery.sizeOf(context).height * 0.30;
      // Seed the tail filler generously so the FIRST layout already has
      // enough scroll extent for initialScrollOffset (_headerH) to stick —
      // otherwise a short page (one carousel row) clamps to the top with the
      // title showing, pushing content down below where Albums/Pictures sit.
      // _ensureHeaderReachable trims it to the minimum after the first frame.
      _bottomFiller = MediaQuery.sizeOf(context).height;
      _scrollCtrl = ScrollController(initialScrollOffset: _headerH)
        ..addListener(_onScrollTick);
    }
  }

  /// Publishes the same scroll-derived chrome state Pictures/Albums do, so
  /// the floating search button rides the header reveal (instead of sitting
  /// fixed and being crossed by the revealing title) and its pill only
  /// appears once content scrolls under it.
  void _onScrollTick() {
    final chrome = widget.chrome;
    final ctrl = _scrollCtrl;
    if (chrome == null || ctrl == null || !ctrl.hasClients) return;
    final under = ctrl.offset > _headerH + 8;
    if (chrome.scrolledUnder.value != under) chrome.scrolledUnder.value = under;
    chrome.headerReveal.value =
        (_headerH - ctrl.offset).clamp(0.0, _headerH).toDouble();
  }

  /// Re-publish scroll-derived chrome state (used after tab switches).
  void reportChrome() => _onScrollTick();

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_reload);
    DatabaseService().removeListener(_reload);
    GalleryPrefs().changed.removeListener(_reload);
    _scrollCtrl?.dispose();
    super.dispose();
  }

  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _headerLocked = n.metrics.pixels > _headerH + 0.5;
    }
    return false;
  }

  /// Grows tail padding so offset == _headerH (title fully collapsed) is
  /// always reachable even when the content is a single short row.
  void _ensureHeaderReachable() {
    if (!mounted) return;
    final ctrl = _scrollCtrl;
    if (ctrl == null || !ctrl.hasClients) return;
    final withoutFiller = ctrl.position.maxScrollExtent - _bottomFiller;
    final needed = (_headerH - withoutFiller)
        .clamp(0.0, _headerH + ctrl.position.viewportDimension)
        .toDouble();
    if ((needed - _bottomFiller).abs() > 1) {
      setState(() => _bottomFiller = needed);
    }
  }

  Widget _bigHeader() {
    final ctrl = _scrollCtrl!;
    return SizedBox(
      height: _headerH,
      child: AnimatedBuilder(
        animation: ctrl,
        builder: (context, _) {
          final cs = Theme.of(context).colorScheme;
          final off = ctrl.hasClients ? ctrl.offset : _headerH;
          final frac = (1 - off / _headerH).clamp(0.0, 1.0);
          final count = _stories.length;
          return Opacity(
            opacity: Curves.easeIn.transform(frac),
            child: Padding(
              padding:
                  EdgeInsets.only(top: MediaQuery.paddingOf(context).top + 12),
              child: Align(
                // Same two-line column + alignment as Albums/Pictures so the
                // "Stories" word lands at the identical vertical level (a
                // single centred line used to settle a touch lower).
                alignment: const Alignment(0, 0.45),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Stories',
                        style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 30,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text(
                      count == 0
                          ? 'No memories yet'
                          : '$count memor${count == 1 ? 'y' : 'ies'}',
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

  static const _months = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];

  Future<void> _reload() async {
    final prefs = await SharedPreferences.getInstance();
    bool on(String key) => prefs.getBool(key) ?? true;
    // "Show featured content" is the master switch; each story kind under
    // it has its own toggle in Settings > Gallery.
    _showFeatured = on(GalleryPrefs.kShowFeatured);
    _showYearAgo = _showFeatured && on(GalleryPrefs.kShowYearAgo);
    final showToday = _showFeatured && on(GalleryPrefs.kShowToday);
    final showOnThisDay = _showFeatured && on(GalleryPrefs.kShowOnThisDay);
    final showLastMonth = _showFeatured && on(GalleryPrefs.kShowLastMonth);
    final showBestOf = _showFeatured && on(GalleryPrefs.kShowBestOf);
    final showVideo = _showFeatured && on(GalleryPrefs.kShowFeaturedVideo);

    final db = DatabaseService();
    final stories = <_Story>[];

    if (showToday) {
      final today = await db.getTodaysRecap();
      if (today.isNotEmpty) {
        stories.add(_Story('Today', today, subtitle: 'Recap'));
      }
    }

    if (showOnThisDay) {
      final onThisDay = await db.getMemoriesOnThisDay();
      if (onThisDay.isNotEmpty) {
        stories.add(_Story('On this day', onThisDay, subtitle: 'Past years'));
      }
    }

    if (showLastMonth) {
      final lastMonth = await db.getLastMonth();
      if (lastMonth.isNotEmpty) {
        final now = DateTime.now();
        final lm = (now.month - 2 + 12) % 12;
        stories.add(_Story(_months[lm], lastMonth, subtitle: 'Last month'));
      }
    }

    if (_showYearAgo) {
      for (final y in const [1, 2, 3, 4]) {
        final files = await db.getFilesFromYearsAgo(y);
        if (files.isNotEmpty) {
          stories.add(_Story(y == 1 ? 'A year ago' : '$y years ago', files));
        }
      }
    }

    if (showBestOf) {
      final best = await db.getBestOfThisMonth();
      if (best.isNotEmpty) {
        stories.add(_Story('Best of ${_months[DateTime.now().month - 1]}',
            best,
            subtitle: 'Favorites'));
      }
    }

    if (showVideo) {
      final allImages = await db.getFilesByType(CnestFileType.image);
      final videos = allImages.where((f) {
        final ext = f.filename.split('.').last.toLowerCase();
        return const ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
      }).toList();
      if (videos.isNotEmpty) {
        final v = videos[Random().nextInt(videos.length)];
        stories.add(_Story('Featured video', [v], video: true));
      }
    }

    // Fallback so the page is never empty when the user clearly has photos:
    // the date-window cards above only fire on matching capture dates, so a
    // vault of recent uploads would otherwise show nothing. A "Recent" card
    // from the latest items always gives them something to open.
    if (stories.isEmpty && (_showFeatured || _showYearAgo)) {
      final recent = await db.getFilesByType(CnestFileType.image);
      if (recent.isNotEmpty) {
        stories.add(
            _Story('Recent', recent.take(60).toList(), subtitle: 'Latest'));
      }
    }

    if (mounted) {
      setState(() {
        _stories = stories;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final cs = Theme.of(context).colorScheme;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _ensureHeaderReachable());

    return NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: ListView(
        controller: _scrollCtrl,
        // Explicit zero padding: a null-padding vertical ListView auto-adds
        // MediaQuery top/bottom insets, which stacked a second safe-area gap
        // on top of the header's own inset and pushed the whole page ~45px
        // lower than Albums/Pictures. The header manages its own top inset.
        padding: EdgeInsets.zero,
        physics: HeaderSnapPhysics(
          collapsedOffset: _headerH,
          headerLocked: () => _headerLocked,
          parent: const AlwaysScrollableScrollPhysics(),
        ),
        children: [
          _bigHeader(),
          // Content starts below the floating search chrome.
          SizedBox(height: MediaQuery.paddingOf(context).top + 56),
          if (_stories.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
              child: Column(
                children: [
                  ThemeIcon('sparkle',
                      size: 64, color: cs.onSurface.withAlpha(120)),
                  const SizedBox(height: 16),
                  Text('No stories yet',
                      style: TextStyle(
                          color: cs.onSurface.withAlpha(120), fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Memories will appear here over time',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: cs.onSurface.withAlpha(120), fontSize: 13)),
                ],
              ),
            )
          else
            SizedBox(
              height: _cardH,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _stories.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(width: 12),
                itemBuilder: (context, i) => _storyCard(_stories[i], i),
              ),
            ),
          SizedBox(height: _bottomFiller + 120),
        ],
      ),
    );
  }

  /// Hero tags must be unique on a page. Two stories can share a cover, so
  /// only the first card for a given cover carries the hero.
  int _heroOwner(String coverId) {
    for (var i = 0; i < _stories.length; i++) {
      if (_stories[i].cover.id == coverId) return i;
    }
    return -1;
  }

  Widget _storyCard(_Story s, int index) {
    final t = ThemeController().tokens;
    // The cover is the gallery's own tile (shared ThumbStore entry), so the
    // hero flight paints the same decoded image the card shows.
    final cover = GalleryGridItem(
      key: ValueKey('story-${s.cover.id}-$index'),
      file: s.cover,
      decodeWidth: _coverDecodeWidth,
      compact: true,
    );
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        photoViewerRoute(ImageViewerScreen(
          files: s.files,
          initialIndex: 0,
          placeholderDecodeWidth: _coverDecodeWidth,
        )),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.rCardLg),
        child: SizedBox(
          width: _cardW,
          height: _cardH,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_heroOwner(s.cover.id) == index)
                Hero(
                  tag: 'photo-${s.cover.id}',
                  flightShuttleBuilder: photoHeroShuttle,
                  child: cover,
                )
              else
                cover,
              // Bottom scrim so the white title always reads.
              Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x00000000),
                      Color(0x00000000),
                      Color(0xB3000000),
                    ],
                    stops: [0.0, 0.5, 1.0],
                  ),
                ),
              ),
              if (s.video)
                const Center(
                  child: ThemeIcon('playCircle',
                      selected: true, color: Colors.white, size: 52),
                ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.subtitle != null)
                      Text(s.subtitle!.toUpperCase(),
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.8)),
                    Text(s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            height: 1.1)),
                    if (!s.video && s.files.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text('${s.files.length} photos',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
