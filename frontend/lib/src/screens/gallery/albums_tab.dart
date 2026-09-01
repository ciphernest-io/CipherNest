import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/routes.dart';
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

class AlbumsTabState extends State<AlbumsTab> {
  static const _kViewModePref = 'albums_view_mode';
  _AlbumViewMode _viewMode = _AlbumViewMode.grid3;

  // Raw-pointer pinch (same reasons as the photo grid: a scale recognizer
  // loses the arena to the scroll drag).
  final Map<int, Offset> _pinchPointers = {};
  bool _pinchActive = false;
  double? _pinchBaseline;

  double _pinchSpan() {
    final pts = _pinchPointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pinchPointers[e.pointer] = e.position;
    if (_pinchPointers.length == 2) {
      setState(() {
        _pinchActive = true;
        _pinchBaseline = _pinchSpan();
      });
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
    final relative = span / baseline;
    final idx = _viewMode.index;
    if (relative > 1.25 && idx < _AlbumViewMode.values.length - 1) {
      setState(() => _viewMode = _AlbumViewMode.values[idx + 1]);
      _pinchBaseline = span;
    } else if (relative < 0.8 && idx > 0) {
      setState(() => _viewMode = _AlbumViewMode.values[idx - 1]);
      _pinchBaseline = span;
    }
  }

  void _onPointerEnd(PointerEvent e) {
    _pinchPointers.remove(e.pointer);
    if (_pinchPointers.length < 2) _pinchBaseline = null;
    if (_pinchPointers.isEmpty && _pinchActive) {
      setState(() => _pinchActive = false);
      SharedPreferences.getInstance()
          .then((p) => p.setInt(_kViewModePref, _viewMode.index));
    }
  }

  Future<void> _loadViewMode() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(_kViewModePref);
    if (saved == null || !mounted) return;
    setState(() => _viewMode = _AlbumViewMode
        .values[saved.clamp(0, _AlbumViewMode.values.length - 1)]);
  }

  Widget _entryCard(_AlbumEntry entry, _AlbumViewMode mode) {
    final album = entry.album;
    if (album == null) return _buildCreateCard();
    return _AlbumCard(
      key: ValueKey(entry.id),
      album: album,
      mode: mode,
      onTap: () => _openAlbum(album),
    );
  }

  // OneUI header: same reveal pattern as PicturesTab.
  ScrollController? _scrollCtrl;
  double _headerH = 0;
  Timer? _motionTimer;
  bool _headerLocked = true;

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

  bool _onScrollNotification(ScrollNotification n) {
    final chrome = widget.chrome;
    if (chrome == null || n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _headerLocked = n.metrics.pixels > _headerH + 0.5;
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
              headerLocked: () => _headerLocked,
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
          _AnimatedAlbumGrid(
            mode: _viewMode,
            entries: [
              for (final album in _deviceAlbums)
                _AlbumEntry(album.id, album),
            ],
            buildCard: _entryCard,
          ),
        ],
        _sectionHeader('My albums', cs,
            subtitle: 'Synced across your devices'),
        _AnimatedAlbumGrid(
          mode: _viewMode,
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

  Widget _buildCreateCard() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return GestureDetector(
      onTap: _createAlbum,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(t.rCard),
          border: Border.all(color: cs.outline),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ThemeIcon('plus', color: cs.onSurface.withAlpha(140), size: 40),
              const SizedBox(height: 8),
              Text('Create Album',
                  style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatefulWidget {
  final CnestAlbum album;
  final VoidCallback onTap;
  final _AlbumViewMode mode;

  const _AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.mode = _AlbumViewMode.grid3,
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
      await cacheFile.writeAsBytes(dec);
      if (mounted) setState(() => _coverBytes = dec);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final grid = widget.mode != _AlbumViewMode.list;
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

    // The outer rect (and with it the cover's aspect) is animated by the
    // grid; only the internal arrangement swaps between overlay and row.
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(t.rCard),
          border: Border.all(color: cs.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: grid
            ? Stack(
                fit: StackFit.expand,
                children: [
                  cover(),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 18, 10, 8),
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xB3000000), Color(0x00000000)],
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                                  color: Colors.white70, fontSize: 11)),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  SizedBox(
                    width: 76,
                    height: double.infinity,
                    child: cover(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
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
                  const SizedBox(width: 8),
                ],
              ),
      ),
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


/// The three album layouts, in pinch order: pinch-in walks toward the
/// list, pinch-out toward the 2-wide cards.
enum _AlbumViewMode { list, grid3, grid2 }

class _AlbumEntry {
  const _AlbumEntry(this.id, this.album);
  final String id;
  final CnestAlbum? album; // null = the "create album" card
}

/// Mode changes MOVE every card to its new rect (AnimatedPositioned per
/// album, stable keys) — no fades: going 2-wide -> 3-wide you can follow
/// each album travel, and the 3:4 <-> square aspect morphs with the rect.
class _AnimatedAlbumGrid extends StatelessWidget {
  const _AnimatedAlbumGrid({
    required this.entries,
    required this.mode,
    required this.buildCard,
  });

  static const _moveDuration = Duration(milliseconds: 340);
  final List<_AlbumEntry> entries;
  final _AlbumViewMode mode;
  final Widget Function(_AlbumEntry, _AlbumViewMode) buildCard;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      late final double totalH;
      Rect rectFor(int i) {
        switch (mode) {
          case _AlbumViewMode.list:
            return Rect.fromLTWH(0, i * 84.0, w, 76);
          case _AlbumViewMode.grid3:
          case _AlbumViewMode.grid2:
            final cols = mode == _AlbumViewMode.grid3 ? 3 : 2;
            final tw = (w - (cols - 1) * 10) / cols;
            final th = tw * 4 / 3;
            final row = i ~/ cols;
            final col = i % cols;
            return Rect.fromLTWH(
                col * (tw + 10), row * (th + 10), tw, th);
        }
      }

      if (mode == _AlbumViewMode.list) {
        totalH = entries.isEmpty ? 0 : entries.length * 84.0 - 8;
      } else {
        final cols = mode == _AlbumViewMode.grid3 ? 3 : 2;
        final tw = (w - (cols - 1) * 10) / cols;
        final th = tw * 4 / 3;
        final rows = (entries.length / cols).ceil();
        totalH = rows == 0 ? 0 : rows * th + (rows - 1) * 10;
      }

      return AnimatedContainer(
        duration: _moveDuration,
        curve: Curves.easeInOutCubic,
        height: totalH,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < entries.length; i++)
              AnimatedPositioned.fromRect(
                key: ValueKey('pos-${entries[i].id}'),
                duration: _moveDuration,
                curve: Curves.easeInOutCubic,
                rect: rectFor(i),
                child: buildCard(entries[i], mode),
              ),
          ],
        ),
      );
    });
  }
}
