import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/file_model.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/gallery_prefs.dart';
import '../../../services/sync_service.dart';
import 'gallery_chrome.dart';
import 'image_viewer_screen.dart';

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
    _showFeatured = prefs.getBool('gallery_show_featured') ?? true;
    _showYearAgo = prefs.getBool('gallery_show_year_ago') ?? true;

    final db = DatabaseService();
    final stories = <_Story>[];

    // Date-memory surfaces are all gated by the "A Year Ago Memories" toggle.
    if (_showYearAgo) {
      final today = await db.getTodaysRecap();
      if (today.isNotEmpty) {
        stories.add(_Story('Today', today, subtitle: 'Recap'));
      }

      final onThisDay = await db.getMemoriesOnThisDay();
      if (onThisDay.isNotEmpty) {
        stories.add(_Story('On this day', onThisDay, subtitle: 'Past years'));
      }

      final lastMonth = await db.getLastMonth();
      if (lastMonth.isNotEmpty) {
        final now = DateTime.now();
        final lm = (now.month - 2 + 12) % 12;
        stories.add(_Story(_months[lm], lastMonth, subtitle: 'Last month'));
      }

      for (final y in const [1, 2, 3, 4]) {
        final files = await db.getFilesFromYearsAgo(y);
        if (files.isNotEmpty) {
          stories.add(_Story(y == 1 ? 'A year ago' : '$y years ago', files));
        }
      }

      final best = await db.getBestOfThisMonth();
      if (best.isNotEmpty) {
        stories.add(_Story('Best of ${_months[DateTime.now().month - 1]}',
            best,
            subtitle: 'Favorites'));
      }
    }

    if (_showFeatured) {
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
                itemBuilder: (context, i) => _storyCard(_stories[i]),
              ),
            ),
          SizedBox(height: _bottomFiller + 120),
        ],
      ),
    );
  }

  Widget _storyCard(_Story s) {
    final t = ThemeController().tokens;
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(files: s.files, initialIndex: 0),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(t.rCardLg),
        child: SizedBox(
          width: _cardW,
          height: _cardH,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _ThumbnailLoader(file: s.cover),
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

class _ThumbnailLoader extends StatefulWidget {
  final CnestFile file;
  const _ThumbnailLoader({required this.file});

  @override
  State<_ThumbnailLoader> createState() => _ThumbnailLoaderState();
}

class _ThumbnailLoaderState extends State<_ThumbnailLoader> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _isVideo {
    final ext = widget.file.filename.split('.').last.toLowerCase();
    return const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
  }

  /// Fire-and-forget: share the obtained frame through the standard
  /// thumb-cache path so the grid, filmstrip, and viewer reuse it.
  /// MediaStore-bound files are excluded (same assetId == null gate as the
  /// viewer/filmstrip persist helpers): Android re-serves their frame on
  /// demand, and this ungated write — running for every video story card
  /// the moment the gallery's IndexedStack builds this tab — was why the
  /// app-cache figure jumped on entering the gallery even though the grid
  /// itself writes nothing.
  void _persistFrame(Uint8List bytes) {
    if (widget.file.assetId != null) return;
    final cloudId = widget.file.cloudId;
    if (cloudId == null) return;
    getTemporaryDirectory().then((dir) async {
      try {
        await File('${dir.path}/thumb_$cloudId.jpg').writeAsBytes(bytes);
      } catch (_) {
        // Best-effort cache write.
      }
    });
  }

  Future<void> _load() async {
    // Videos first: their raw bytes are not decodable as an image, so they
    // need a real frame — same rungs as the gallery grid and filmstrip.
    if (_isVideo) {
      // Rung 0 — the shared disk thumb cache. MediaStore-bound files skip
      // it: Android serves their frame, and a disk thumb here can only be a
      // stale leftover from a window when the local original was missing
      // (gallery delete → restore). Serving it first kept the leftover
      // alive forever.
      if (widget.file.assetId == null && widget.file.cloudId != null) {
        final dir = await getTemporaryDirectory();
        final cached = File('${dir.path}/thumb_${widget.file.cloudId}.jpg');
        if (await cached.exists()) {
          final bytes = await cached.readAsBytes();
          if (mounted) setState(() => _bytes = bytes);
          return;
        }
      }
      // Rung 1 — MediaStore.
      if (widget.file.assetId != null) {
        try {
          final asset = await AssetEntity.fromId(widget.file.assetId!);
          final bytes = await asset?.thumbnailDataWithSize(
            const ThumbnailSize(600, 600),
          );
          if (bytes != null) {
            _persistFrame(bytes);
            // MediaStore verified as the source — reclaim any leftover
            // decrypted copies. Stories re-runs _load on every rebuild
            // (no memo), so this converges even when the grid tile's
            // session memo skips its own ladder.
            unawaited(CacheManagerService().reclaimForMediaStoreOriginal(
              fileId: widget.file.id,
              cloudId: widget.file.cloudId,
            ));
            if (mounted) setState(() => _bytes = bytes);
            return;
          }
        } catch (_) {
          // fall through
        }
      }
      // Rung 2 — extract a frame from the local original.
      if (widget.file.localPath != null &&
          File(widget.file.localPath!).existsSync()) {
        try {
          final bytes = await VideoThumbnail.thumbnailData(
            video: widget.file.localPath!,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 600,
            quality: 70,
          );
          if (bytes != null) {
            _persistFrame(bytes);
            if (mounted) setState(() => _bytes = bytes);
            return;
          }
        } catch (_) {
          // fall through to the cloud thumb
        }
      }
      // Rung 3 — the encrypted cloud thumbnail only. Never fall back to the
      // full video blob: it isn't an image, and it can be hundreds of MB.
      if (widget.file.thumbnailCloudId == null) return;
    }

    // LOCAL-FIRST: use device file if it exists (images only — a video
    // never reaches here with a local original).
    if (!_isVideo && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists()) {
        final bytes = await localFile.readAsBytes();
        if (mounted) setState(() => _bytes = bytes);
        return;
      }
    }

    // CLOUD FALLBACK
    final targetId = _isVideo
        ? widget.file.thumbnailCloudId
        : (widget.file.thumbnailCloudId ?? widget.file.cloudId);
    if (targetId == null) return;

    try {
      final cacheDir = await getTemporaryDirectory();
      final isThumbnail = widget.file.thumbnailCloudId != null;
      final fileName = isThumbnail
          ? 'thumb_${widget.file.cloudId}.jpg'
          : '${widget.file.cloudId}_decrypted.jpg';
      final cacheFile = File('${cacheDir.path}/$fileName');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() => _bytes = bytes);
        return;
      }

      final enc = await CloudService().downloadFile(targetId);
      final dec = await EncryptionService.decryptFile(enc);
      await cacheFile.writeAsBytes(dec);
      if (mounted) setState(() => _bytes = dec);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Image.memory(_bytes!, fit: BoxFit.cover);
    }
    return Container(color: Theme.of(context).colorScheme.surfaceContainerHighest);
  }
}
