import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../config/theme_controller.dart';
import '../../config/theme_packs.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/folder_picker_sheet.dart';
import '../../widgets/theme_icon.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/file_model.dart';
import '../../utils/date_grouper.dart';
import '../../../services/cache_manager_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/local_content_guard.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/activity_center.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/notify.dart';
import '../../utils/bulk_ops.dart';
import '../../../services/sync_service.dart';
import '../share/share_dialog.dart';
import 'image_viewer_screen.dart';

class PicturesTab extends StatefulWidget {
  const PicturesTab({super.key});

  @override
  State<PicturesTab> createState() => PicturesTabState();
}

/// One rung of the Samsung-style gallery zoom ladder. [columns] == 0 marks
/// the justified layout — variable-width rows where every photo keeps its
/// own aspect ratio.
class _ZoomLevel {
  final int columns;
  final _Grouping grouping;
  const _ZoomLevel(this.columns, this.grouping);

  bool get isJustified => columns == 0;
}

enum _Grouping { year, month, day }

class PicturesTabState extends State<PicturesTab> {
  static const String _zoomLevelPrefKey = 'gallery_zoom_level';
  static const String _legacyColumnPrefKey = 'gallery_column_count';

  /// Most zoomed OUT first: year overview → month grids → day grids →
  /// justified. Pinch-out walks down this list (bigger tiles), pinch-in
  /// walks up.
  static const List<_ZoomLevel> _zoomLevels = [
    _ZoomLevel(28, _Grouping.year),
    _ZoomLevel(12, _Grouping.month),
    _ZoomLevel(7, _Grouping.month),
    _ZoomLevel(4, _Grouping.day),
    _ZoomLevel(3, _Grouping.day),
    _ZoomLevel(0, _Grouping.day), // justified
  ];
  static const int _defaultZoomIndex = 4; // classic 3-column day grid

  late Future<List<CnestFile>> _filesFuture;
  bool _favoritesOnly = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  int _zoomIndex = _defaultZoomIndex;

  // Pinch detection runs on RAW pointer events, not a GestureDetector.
  // A scale recognizer has to win the gesture arena against the scroll
  // view's vertical drag — and the drag claims the gesture as soon as the
  // FIRST finger moves past touch slop, which usually happens before the
  // second finger lands. Raw Listeners never enter the arena, so the pinch
  // is seen every time; scrolling is frozen (physics swap) while two
  // fingers are down so the list doesn't fight the gesture.
  //
  // Stepping is BASELINE-relative: step when the finger span moves 25%/20%
  // away from the baseline, then re-baseline so the NEXT step needs another
  // 25%/20% of travel — a single pinch can walk multiple levels but never
  // jumps to the extremes.
  final Map<int, Offset> _pinchPointers = {};
  bool _pinchActive = false;
  double? _pinchSpanBaseline;

  // Aspect ratios (w/h) for the justified layout, resolved lazily off the
  // MediaStore entry / local file / cached thumb. Static so ratios survive
  // tab remounts. Files we couldn't measure get a neutral fallback cached
  // too — retrying every build would hammer the disk.
  static final Map<String, double> _ratioCache = {};
  bool _resolvingRatios = false;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onSyncComplete);
    // DatabaseService fires notifyListeners on delete/restore/addFile so the
    // grid rebuilds without a pull-to-refresh after any mutation, including
    // ones initiated from other screens (album detail, image viewer).
    DatabaseService().addListener(_onDatabaseChanged);
    _refresh();
    _loadZoomLevel();
  }

  Future<void> _loadZoomLevel() async {
    final prefs = await SharedPreferences.getInstance();
    var saved = prefs.getInt(_zoomLevelPrefKey);
    // Migrate the pre-ladder column pref to the nearest new level.
    if (saved == null) {
      final legacy = prefs.getInt(_legacyColumnPrefKey);
      saved = switch (legacy) {
        2 => 5, // biggest tiles → justified
        3 => 4,
        4 => 3,
        5 => 3, // nearest new day-grid (4 columns)
        _ => _defaultZoomIndex,
      };
    }
    if (!mounted) return;
    setState(() {
      _zoomIndex = saved!.clamp(0, _zoomLevels.length - 1);
    });
  }

  Future<void> _persistZoomLevel() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_zoomLevelPrefKey, _zoomIndex);
  }

  double _pinchSpan() {
    final pts = _pinchPointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.position;
    if (_pinchPointers.length == 2) {
      // Second finger down: this is a pinch. The physics swap cancels any
      // scroll drag the first finger already started.
      setState(() {
        _pinchActive = true;
        _pinchSpanBaseline = _pinchSpan();
      });
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.position;
    if (!_pinchActive || _pinchPointers.length < 2) return;

    final span = _pinchSpan();
    final baseline = _pinchSpanBaseline;
    if (baseline == null || baseline <= 0) {
      _pinchSpanBaseline = span;
      return;
    }
    final relative = span / baseline;
    if (relative > 1.25 && _zoomIndex < _zoomLevels.length - 1) {
      setState(() => _zoomIndex += 1); // spread → zoom in, bigger tiles
      _pinchSpanBaseline = span;
      return;
    }
    if (relative < 0.8 && _zoomIndex > 0) {
      setState(() => _zoomIndex -= 1); // pinch → zoom out, denser grid
      _pinchSpanBaseline = span;
    }
  }

  void _onPointerEnd(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) _pinchSpanBaseline = null;
    // Keep scrolling frozen until ALL fingers lift — the finger that
    // remains after a pinch shouldn't fling the list.
    if (_pinchPointers.isEmpty && _pinchActive) {
      setState(() => _pinchActive = false);
      _persistZoomLevel();
    }
  }

  /// Resolves missing aspect ratios for the justified layout, cheapest
  /// source first, one batch per frame so the UI reflows progressively.
  Future<void> _resolveRatios(List<CnestFile> files) async {
    if (_resolvingRatios) return;
    final missing =
        files.where((f) => !_ratioCache.containsKey(f.id)).toList();
    if (missing.isEmpty) return;
    _resolvingRatios = true;
    try {
      var resolvedAny = false;
      for (final file in missing.take(32)) {
        _ratioCache[file.id] = await _measureRatio(file);
        resolvedAny = true;
      }
      if (resolvedAny && mounted) setState(() {});
    } finally {
      _resolvingRatios = false;
    }
    // More to do? Chain the next batch after this frame's reflow.
    if (mounted && files.any((f) => !_ratioCache.containsKey(f.id))) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _resolveRatios(files));
    }
  }

  Future<double> _measureRatio(CnestFile file) async {
    final ext = file.filename.split('.').last.toLowerCase();
    final isVideo = const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext);
    final fallback = isVideo ? 16 / 9 : 1.0;

    // Vault row first — dimensions captured at upload time (v12) cost
    // nothing and work for files with no gallery counterpart.
    final w = file.width;
    final h = file.height;
    if (w != null && h != null && w > 0 && h > 0) return w / h;

    // MediaStore knows dimensions without touching pixel data.
    if (file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(file.assetId!);
        if (asset != null &&
            asset.orientatedWidth > 0 &&
            asset.orientatedHeight > 0) {
          return asset.orientatedWidth / asset.orientatedHeight;
        }
      } catch (_) {}
    }

    // Cached decrypted thumb (small read) beats the full local original.
    try {
      final tempDir = await getTemporaryDirectory();
      final thumb = File('${tempDir.path}/thumb_${file.cloudId}.jpg');
      if (file.cloudId != null && await thumb.exists()) {
        return await _ratioFromBytes(await thumb.readAsBytes()) ?? fallback;
      }
      if (!isVideo && file.localPath != null) {
        final local = File(file.localPath!);
        if (await local.exists()) {
          return await _ratioFromBytes(await local.readAsBytes()) ?? fallback;
        }
      }
    } catch (_) {}
    return fallback;
  }

  /// Header-only decode — dimensions without rasterizing the image.
  Future<double?> _ratioFromBytes(Uint8List bytes) async {
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final ratio = descriptor.width > 0 && descriptor.height > 0
          ? descriptor.width / descriptor.height
          : null;
      descriptor.dispose();
      buffer.dispose();
      return ratio;
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onSyncComplete);
    DatabaseService().removeListener(_onDatabaseChanged);
    super.dispose();
  }

  void _onSyncComplete() {
    if (mounted) _refresh();
  }

  void _onDatabaseChanged() {
    if (mounted) _refresh();
  }

  void refresh() => _refresh();

  void _refresh() {
    setState(() {
      _filesFuture = _loadFiles();
    });
  }

  Future<List<CnestFile>> _loadFiles() async {
    final images =
        await DatabaseService().getFilesByType(CnestFileType.image);
    if (_favoritesOnly) {
      return images.where((f) => f.isFavorite).toList();
    }
    return images;
  }

  void _enterSelection(String id) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _deleteSelected(List<CnestFile> all) async {
    final picked = all.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${picked.length} photos to Recycle Bin?'),
        content: const Text(
          'They will be hidden from your gallery and permanently deleted '
          'after 30 days. Restore from Settings > Recycle Bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: TextStyle(color: ThemeController().tokens.danger),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    // Soft-delete only — encrypted blobs stay in cloud until the sweep runs
    // so users can restore offline. Honest count: a partial failure must
    // never read as full success.
    final task = picked.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Deleting 0/${picked.length}…',
            total: picked.length)
        : null;
    final ok = await honestCount<CnestFile>(
      picked,
      (f) async {
        await DatabaseService().deleteFile(f.id);
        AutoSyncService.trackDeletion(f.filename, f.sizeBytes);
      },
      onEach: (d) =>
          task?.update(d, label: 'Deleting $d/${picked.length}…'),
    );
    DatabaseBackupService().scheduleBackup();
    final failed = picked.length - ok;
    final msg = '$ok photo${ok == 1 ? '' : 's'} moved to Recycle Bin'
        '${failed > 0 ? ' · $failed failed' : ''}';
    if (task != null) {
      failed > 0 ? task.fail(msg) : task.complete(msg);
    } else {
      failed > 0 ? Notify.error(msg) : Notify.info(msg);
    }
    _exitSelection();
    _refresh();
  }

  /// Moves the selection into a picked folder (or back to root). Pure
  /// metadata — the encrypted blobs never move; the op-log carries the
  /// placement to every device.
  Future<void> _moveSelectedToFolder() async {
    final pick = await showFolderPicker(context);
    if (pick == null) return;
    final ids = List<String>.from(_selectedIds);
    final task = ids.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Moving 0/${ids.length}…',
            total: ids.length)
        : null;
    final ok = await honestCount<String>(
      ids,
      (id) => DatabaseService().moveFileToFolder(id, pick.folderId),
      onEach: (d) => task?.update(d, label: 'Moving $d/${ids.length}…'),
    );
    final failed = ids.length - ok;
    final msg = '$ok moved to "${pick.label}"'
        '${failed > 0 ? ' · $failed failed' : ''}';
    if (task != null) {
      failed > 0 ? task.fail(msg) : task.complete(msg);
    } else {
      failed > 0 ? Notify.error(msg) : Notify.info(msg);
    }
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _shareSelected(List<CnestFile> all) async {
    final picked = all.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    if (picked.length == 1) {
      // Single file: choose between sending the file and the magic link.
      await showShareChoiceSheet(context, picked.first,
          onSecureLink: () => ShareDialog.show(context, picked.first));
    } else {
      // Multi-file: the magic link is per-file, so bulk share = send the
      // actual files through the system sheet.
      await sendFilesPlain(context, picked);
    }
    if (mounted) _exitSelection();
  }

  Future<void> handleSync() async {
    await SyncService().syncNow(force: true);
    // Honest outcome: an offline cycle or failed uploads must never read
    // as "Sync complete".
    final String msg;
    if (SyncService().lastCycleOffline) {
      msg = "You're offline — sync will pick up when you're back";
    } else {
      final r = SyncService().lastAutoSyncResult;
      if (r != null && r.failed > 0) {
        final base = '${r.synced} backed up · ${r.failed} failed';
        msg = r.allFailuresOffline ? "$base — you appear to be offline" : base;
      } else if (r != null && r.synced > 0) {
        msg = '${r.synced} photo${r.synced == 1 ? '' : 's'} secured';
      } else {
        msg = 'Sync complete';
      }
    }
    final bool syncFailed = !SyncService().lastCycleOffline &&
        (SyncService().lastAutoSyncResult?.failed ?? 0) > 0;
    syncFailed ? Notify.error(msg) : Notify.info(msg);
  }


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return FutureBuilder<List<CnestFile>>(
      future: _filesFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snapshot.data!;

        if (files.isEmpty) {
          return RefreshIndicator(
            onRefresh: handleSync,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 300),
                Center(
                    child: Text('No encrypted photos yet.\nPull to sync.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withAlpha(120)))),
              ],
            ),
          );
        }

        final level = _zoomLevels[_zoomIndex];
        final sections = switch (level.grouping) {
          _Grouping.year => groupByYear(files),
          _Grouping.month => groupByMonth(files),
          _Grouping.day => groupByDate(files),
        };

        // Build a flat list for ImageViewerScreen navigation. Sections are
        // contiguous runs of this list, so a running offset per section
        // yields each file's viewer index.
        final flatFiles = files;
        final sectionOffsets = List<int>.filled(sections.length, 0);
        for (int s = 1; s < sections.length; s++) {
          sectionOffsets[s] =
              sectionOffsets[s - 1] + sections[s - 1].files.length;
        }

        if (level.isJustified) {
          unawaited(_resolveRatios(files));
        }

        // Landscape gets ~1.5x the columns so the grid stays dense across
        // the wider canvas.
        final orientation = MediaQuery.of(context).orientation;
        final columns = orientation == Orientation.landscape
            ? (level.columns * 1.5).round().clamp(2, 42)
            : level.columns;
        // Tiny tiles decode tiny — a 28-column grid must not hold hundreds
        // of 300px bitmaps. Badges vanish at dense levels (they'd be larger
        // than the tiles).
        final decodeWidth = columns >= 12 ? 120 : (columns >= 6 ? 160 : 300);
        final compact = columns >= 6;

        return RefreshIndicator(
          onRefresh: handleSync,
          child: Column(
            children: [
              _buildToolbar(files),
              Expanded(
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerEnd,
                  onPointerCancel: _onPointerEnd,
                  child: CustomScrollView(
                    physics: _pinchActive
                        ? const NeverScrollableScrollPhysics()
                        : const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      for (int s = 0; s < sections.length; s++) ...[
                        SliverPersistentHeader(
                          pinned: false,
                          floating: false,
                          delegate: _DateHeaderDelegate(sections[s].label),
                        ),
                        if (level.isJustified)
                          _justifiedSliver(
                            sections[s].files,
                            sectionOffsets[s],
                            flatFiles,
                            cs,
                            t,
                          )
                        else
                          SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              crossAxisSpacing: 1.5,
                              mainAxisSpacing: 1.5,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _tile(
                                sections[s].files[index],
                                sectionOffsets[s] + index,
                                flatFiles,
                                cs,
                                t,
                                decodeWidth: decodeWidth,
                                compact: compact,
                              ),
                              childCount: sections[s].files.length,
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// One gallery tile: thumbnail + selection/favorite chrome + tap/long-press
  /// wiring. Shared by every zoom level.
  Widget _tile(
    CnestFile file,
    int globalIndex,
    List<CnestFile> flatFiles,
    ColorScheme cs,
    ThemePackTokens t, {
    int decodeWidth = 300,
    bool compact = false,
  }) {
    final isSelected = _selectedIds.contains(file.id);
    return GestureDetector(
      onTap: () async {
        if (_selectionMode) {
          _toggleSelected(file.id);
          return;
        }
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              files: flatFiles,
              initialIndex: globalIndex,
            ),
          ),
        );
        if (result == true) _refresh();
      },
      onLongPress: () => _enterSelection(file.id),
      child: Stack(
        fit: StackFit.expand,
        children: [
          GalleryGridItem(
            key: ValueKey(file.id),
            file: file,
            decodeWidth: decodeWidth,
            compact: compact,
          ),
          if (_selectionMode)
            Container(
              color: isSelected ? t.scrim : Colors.transparent,
              child: compact
                  ? null
                  : Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: ThemeIcon(
                          isSelected
                              ? 'checkCircle'
                              : 'radio_button_unchecked',
                          selected: isSelected,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ),
            ),
          if (!_selectionMode && !compact && file.isFavorite)
            Positioned(
              top: 4,
              left: 4,
              child: ThemeIcon(
                'heart',
                selected: true,
                size: 14,
                color: cs.error,
              ),
            ),
        ],
      ),
    );
  }

  /// Justified layout — Samsung's most zoomed-in view. Greedy row packing:
  /// photos keep their own aspect ratio, each row is scaled so its widths
  /// exactly fill the viewport, so row heights vary around [targetH].
  Widget _justifiedSliver(
    List<CnestFile> sectionFiles,
    int sectionOffset,
    List<CnestFile> flatFiles,
    ColorScheme cs,
    ThemePackTokens t,
  ) {
    const spacing = 1.5;
    const targetH = 220.0;
    final width = MediaQuery.sizeOf(context).width;

    double ratioOf(CnestFile f) {
      final cached = _ratioCache[f.id];
      if (cached != null) return cached;
      final ext = f.filename.split('.').last.toLowerCase();
      return const {'mp4', 'mov', 'avi', 'mkv'}.contains(ext) ? 16 / 9 : 1.0;
    }

    // Partition into rows: fill until the row would render below targetH.
    final rows = <List<CnestFile>>[];
    var row = <CnestFile>[];
    var ratioSum = 0.0;
    for (final file in sectionFiles) {
      row.add(file);
      ratioSum += ratioOf(file);
      if (ratioSum * targetH >= width - spacing * (row.length - 1)) {
        rows.add(row);
        row = [];
        ratioSum = 0.0;
      }
    }
    if (row.isNotEmpty) rows.add(row);

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, rowIndex) {
          final rowFiles = rows[rowIndex];
          final innerWidth = width - spacing * (rowFiles.length - 1);
          final sum = rowFiles.fold(0.0, (a, f) => a + ratioOf(f));
          // A full row scales to exactly fill the width; a trailing
          // underfull row keeps targetH and leaves the remainder empty.
          final exactH = innerWidth / sum;
          final isUnderfull = exactH > targetH * 1.6;
          final rowH = isUnderfull ? targetH : exactH;

          var globalIndex = sectionOffset;
          for (var r = 0; r < rowIndex; r++) {
            globalIndex += rows[r].length;
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: spacing),
            child: SizedBox(
              height: rowH,
              child: Row(
                children: [
                  for (var i = 0; i < rowFiles.length; i++) ...[
                    if (i > 0) const SizedBox(width: spacing),
                    // Full rows use integer flex so widths always sum to
                    // EXACTLY the viewport — fixed widths would overflow
                    // the Row by sub-pixel rounding.
                    if (isUnderfull)
                      SizedBox(
                        width: ratioOf(rowFiles[i]) * rowH,
                        child: _tile(
                          rowFiles[i],
                          globalIndex + i,
                          flatFiles,
                          cs,
                          t,
                        ),
                      )
                    else
                      Expanded(
                        flex: (ratioOf(rowFiles[i]) * 1000).round(),
                        child: _tile(
                          rowFiles[i],
                          globalIndex + i,
                          flatFiles,
                          cs,
                          t,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
        childCount: rows.length,
      ),
    );
  }

  Widget _buildToolbar(List<CnestFile> all) {
    final cs = Theme.of(context).colorScheme;
    if (_selectionMode) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: cs.surfaceContainerHighest,
        child: Row(
          children: [
            IconButton(
              icon: ThemeIcon('x'),
              onPressed: _exitSelection,
            ),
            const SizedBox(width: 4),
            Text(
              '${_selectedIds.length} selected',
              style: TextStyle(
                color: cs.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Move to folder',
              icon: ThemeIcon('folder'),
              onPressed: () => _moveSelectedToFolder(),
            ),
            IconButton(
              icon: ThemeIcon('shareFat'),
              onPressed: () => _shareSelected(all),
            ),
            IconButton(
              icon: ThemeIcon(
                'trash',
                color: cs.error,
              ),
              onPressed: () => _deleteSelected(all),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          FilterChip(
            label: const Text('Favorites'),
            avatar: ThemeIcon(
              'heart',
              selected: _favoritesOnly,
              size: 14,
              color: _favoritesOnly ? cs.error : cs.onSurface,
            ),
            selected: _favoritesOnly,
            onSelected: (v) {
              setState(() => _favoritesOnly = v);
              _refresh();
            },
          ),
          const Spacer(),
          Text(
            '${all.length} photo${all.length == 1 ? '' : 's'}',
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateHeaderDelegate extends SliverPersistentHeaderDelegate {
  final String label;
  _DateHeaderDelegate(this.label);

  @override
  double get minExtent => 36;
  @override
  double get maxExtent => 36;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text(
        label,
        style: TextStyle(
          color: cs.onSurface.withAlpha(180),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          fontFamily: t.fontFamily,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DateHeaderDelegate oldDelegate) =>
      label != oldDelegate.label;
}

/// Shared thumbnail grid item — used by Pictures tab, Albums detail, etc.
///
/// [decodeWidth] caps the decoded bitmap width so dense zoom levels don't
/// hold hundreds of full-size decodes; [compact] drops the video badge at
/// tile sizes where it would cover the whole thumbnail.
class GalleryGridItem extends StatefulWidget {
  final CnestFile file;
  final int decodeWidth;
  final bool compact;
  const GalleryGridItem({
    super.key,
    required this.file,
    this.decodeWidth = 300,
    this.compact = false,
  });

  @override
  State<GalleryGridItem> createState() => _GalleryGridItemState();
}

/// Resolved display source of a tile, memoized for the session so a
/// remounted grid paints synchronously. Exactly one field is set.
class _ThumbMemo {
  final Uint8List? assetBytes;
  final String? diskPath;
  final bool localVerified;
  const _ThumbMemo({this.assetBytes, this.diskPath, this.localVerified = false});
}

class _GalleryGridItemState extends State<GalleryGridItem> {
  // Session memo of each tile's resolved source. Navigating home → gallery
  // REMOUNTS every tile; without this the ladder re-runs asynchronously and
  // every thumbnail flashes the grey placeholder for a frame ("flicker").
  // Keyed by file id; evicted oldest-first and on identity change.
  static final Map<String, _ThumbMemo> _memo = {};
  static const int _memoCap = 300;

  static void _memoize(String id, _ThumbMemo entry) {
    _memo.remove(id);
    if (_memo.length >= _memoCap) _memo.remove(_memo.keys.first);
    _memo[id] = entry;
  }

  // Rung 1: MediaStore thumbnail bytes, held in state so Flutter's image
  // cache hits across rebuilds (MemoryImage equality is by reference).
  Uint8List? _assetThumbBytes;
  // Rung 3: path to a decrypted thumbnail file we wrote into the temp cache.
  String? _diskThumbPath;
  bool _loading = true;
  bool _isVideo = false;
  bool _wipedCorruptThumb = false;
  // Set only when the local original passed LocalContentGuard (content, not
  // just presence). build() renders Image.file only when this is true, so a
  // stale/mismatched local file never masquerades as the vault entry.
  bool _localVerified = false;
  // A just-synced file whose blob isn't downloadable yet (cloud eventual
  // consistency, or size/hash not joined). Drives a calm "Syncing…" tile
  // that auto-retries on the next sync — never a broken/error tile.
  bool _syncing = false;

  /// A corrupt cached thumb (partial write, interrupted decrypt) would
  /// otherwise error-paint forever. Delete it once and re-fetch; if the
  /// re-fetch is corrupt too, we settle for the plain placeholder.
  void _handleCorruptDiskThumb() {
    if (_wipedCorruptThumb || _diskThumbPath == null) return;
    _wipedCorruptThumb = true;
    _memo.remove(widget.file.id);
    final path = _diskThumbPath!;
    Future.microtask(() async {
      try {
        await File(path).delete();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _diskThumbPath = null;
          _loading = true;
        });
        _loadThumbnail();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    final ext = widget.file.filename.split('.').last.toLowerCase();
    _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
    // Memo hit: paint synchronously, no ladder, no flicker.
    final memo = _memo[widget.file.id];
    if (memo != null) {
      _assetThumbBytes = memo.assetBytes;
      _diskThumbPath = memo.diskPath;
      _localVerified = memo.localVerified;
      _loading = false;
      return;
    }
    _loadThumbnail();
  }

  @override
  void didUpdateWidget(GalleryGridItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The tile keeps its State across refreshes (ValueKey(file.id)), so a
    // row whose identity fields changed — upload finished (cloudId set),
    // local copy restored (assetId/localPath back), file edited
    // (contentHash) — must re-climb the ladder or it renders stale rungs
    // forever and the opportunistic cache reclaim never fires. Strict
    // field comparison: the grid rebuilds on every sync tick, and an
    // unconditional reload here would hammer MediaStore/disk.
    final o = oldWidget.file;
    final n = widget.file;
    if (o.assetId == n.assetId &&
        o.localPath == n.localPath &&
        o.cloudId == n.cloudId &&
        o.thumbnailCloudId == n.thumbnailCloudId &&
        o.contentHash == n.contentHash) {
      return;
    }
    _memo.remove(n.id);
    setState(() {
      _assetThumbBytes = null;
      _diskThumbPath = null;
      _localVerified = false;
      _syncing = false;
      _wipedCorruptThumb = false;
      _loading = true;
      final ext = n.filename.split('.').last.toLowerCase();
      _isVideo = ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
    });
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (!mounted) return;

    // RUNG 1: Android's MediaStore — same drawer Samsung Gallery reads from.
    if (widget.file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(widget.file.assetId!);
        if (asset != null &&
            await LocalContentGuard.matches(widget.file, asset: asset)) {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(300, 300),
          );
          if (bytes != null) {
            // Opportunistic reclaim now that MediaStore is verifiably
            // serving this file: large plaintext AND the decrypted thumbs.
            // Safe from the historic delete/re-download tug-of-war because
            // every thumb persist site is gated `assetId == null` — nothing
            // re-creates these for MediaStore-bound files. This is what
            // clears the thumb downloaded while a local original was
            // temporarily missing (gallery delete → restore).
            unawaited(CacheManagerService().reclaimForMediaStoreOriginal(
              fileId: widget.file.id,
              cloudId: widget.file.cloudId,
            ));
            _memoize(widget.file.id, _ThumbMemo(assetBytes: bytes));
            if (mounted) {
              setState(() {
                _assetThumbBytes = bytes;
                _loading = false;
              });
            }
            return;
          }
        }
      } catch (_) {
        // Asset gone / permission revoked — fall through.
      }
    }

    // RUNG 2: local original via Flutter's image decoder (downsamples at
    // decode time on the IO thread). No state needed — build() returns
    // Image.file directly when localPath is set.
    if (!_isVideo && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (await localFile.exists() &&
          await LocalContentGuard.matches(widget.file, localFile: localFile)) {
        // Same large-plaintext reclaim as rung 1 — local file is
        // authoritative now; thumbs stay for the viewer/filmstrip.
        unawaited(CacheManagerService().invalidateLargePlaintext(
          fileId: widget.file.id,
          cloudId: widget.file.cloudId,
        ));
        _memoize(widget.file.id, const _ThumbMemo(localVerified: true));
        if (mounted) {
          setState(() {
            _localVerified = true;
            _loading = false;
          });
        }
        return;
      }
    }

    // RUNG 2.5 (videos): the thumbnail generated at upload time, cached
    // locally under the ROW id. This is what renders DURING a manual
    // upload — the row has no cloudId yet and picker-cache videos have no
    // assetId, so every other rung is structurally unavailable.
    if (_isVideo) {
      try {
        final cacheDir = await getTemporaryDirectory();
        final localThumb =
            File('${cacheDir.path}/thumb_local_${widget.file.id}.jpg');
        if (await localThumb.exists()) {
          // NOT memoized: this rung only bridges an in-flight upload; the
          // identity change at markAsUploaded re-runs the ladder anyway.
          if (mounted) {
            setState(() {
              _diskThumbPath = localThumb.path;
              _loading = false;
            });
          }
          return;
        }
      } catch (_) {}
    }

    // RUNG 3: encrypted thumb from cloud, decrypted once into the temp cache.
    if (_isVideo && widget.file.thumbnailCloudId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    try {
      final cacheDir = await getTemporaryDirectory();
      final targetCloudId =
          widget.file.thumbnailCloudId ?? widget.file.cloudId;
      // No blob joined yet. If the row carries op identity (content hash /
      // known size), a peer's createFile op arrived but the blob is still
      // propagating (normal on the receiving device) → calm "Syncing…",
      // auto-retried next sync. Otherwise it's a true phantom → broken tile.
      if (targetCloudId == null) {
        final stillPropagating =
            widget.file.contentHash != null || widget.file.sizeBytes > 0;
        if (mounted) {
          setState(() {
            _syncing = stillPropagating;
            _loading = false;
          });
        }
        return;
      }

      final isThumbnail = widget.file.thumbnailCloudId != null;
      final fileName = isThumbnail
          ? 'thumb_${widget.file.cloudId}.jpg'
          : '${widget.file.cloudId}_decrypted.jpg';
      final cacheFile = File('${cacheDir.path}/$fileName');

      if (!await cacheFile.exists()) {
        final encryptedBytes =
            await CloudService().downloadFile(targetCloudId);
        final decryptedBytes =
            await EncryptionService.decryptFile(encryptedBytes);
        // Never cache an empty/implausible result — a momentarily-absent
        // blob would otherwise stick as a permanent 0-byte tile. Leaving the
        // cache unwritten means the next sync re-fetches.
        if (decryptedBytes.isEmpty) {
          if (mounted) {
            setState(() {
              _syncing = true;
              _loading = false;
            });
          }
          return;
        }
        await cacheFile.writeAsBytes(decryptedBytes, flush: true);
      }

      _memoize(widget.file.id, _ThumbMemo(diskPath: cacheFile.path));
      if (mounted) {
        setState(() {
          _diskThumbPath = cacheFile.path;
          _syncing = false;
          _loading = false;
        });
      }
    } catch (e) {
      // Download/decrypt failed (often eventual-consistency on a just-synced
      // blob). Calm "Syncing…", retried next sync — nothing was cached.
      if (mounted) {
        setState(() {
          _syncing = true;
          _loading = false;
        });
      }
    }
  }

  Widget _videoOverlay(ColorScheme cs) {
    // Small corner badge. A big centered play glyph reads as a tappable
    // control and covers the thumbnail — this just *labels* it as a video.
    return Positioned(
      left: 5,
      bottom: 5,
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: ThemeController().tokens.scrim,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: ThemeIcon(
            'play',
            selected: true,
            size: 13,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    Widget errorTile(_, _, _) =>
        Container(color: cs.surfaceContainerHighest);

    // Rung 1 — MediaStore bytes.
    if (_assetThumbBytes != null) {
      return Stack(fit: StackFit.expand, children: [
        Image.memory(
          _assetThumbBytes!,
          fit: BoxFit.cover,
          cacheWidth: widget.decodeWidth,
          errorBuilder: errorTile,
        ),
        if (_isVideo && !widget.compact) _videoOverlay(cs),
      ]);
    }

    // Rung 2 — local original, Flutter decodes at cacheWidth. Only when the
    // content guard verified it (set in _loadThumbnail); a bare localPath is
    // not enough — it might point at stale/different bytes.
    if (!_isVideo && _localVerified && widget.file.localPath != null) {
      final localFile = File(widget.file.localPath!);
      if (localFile.existsSync()) {
        return Stack(fit: StackFit.expand, children: [
          Image.file(
            localFile,
            fit: BoxFit.cover,
            cacheWidth: widget.decodeWidth,
            gaplessPlayback: true,
            errorBuilder: errorTile,
          ),
          if (_isVideo && !widget.compact) _videoOverlay(cs),
        ]);
      }
    }

    // Rung 3 — decrypted thumb on disk.
    if (_diskThumbPath != null) {
      return Stack(fit: StackFit.expand, children: [
        Image.file(
          File(_diskThumbPath!),
          fit: BoxFit.cover,
          cacheWidth: widget.decodeWidth,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            _handleCorruptDiskThumb();
            return errorTile(context, error, stackTrace);
          },
        ),
        if (_isVideo && !widget.compact) _videoOverlay(cs),
      ]);
    }

    // Still loading or no thumbnail available — solid placeholder.
    if (_loading) return Container(color: cs.surfaceContainerHighest);

    // Just-synced file whose blob isn't downloadable yet — a CALM
    // auto-resolving "Syncing…" tile, never a broken-image error. It fills in
    // on the next sync once the blob is available; on the receiving device a
    // briefly-absent blob is the normal case, not corruption.
    if (_syncing) {
      // Dense zoom levels: the icon+label would overflow a tiny tile.
      if (widget.compact) {
        return Container(color: cs.surfaceContainerHighest);
      }
      return Container(
        color: cs.surfaceContainerHighest,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemeIcon('arrowsClockwise',
                  color: cs.onSurface.withAlpha(120), size: 26),
              const SizedBox(height: 6),
              Text('Syncing…',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(120), fontSize: 11)),
            ],
          ),
        ),
      );
    }

    if (widget.compact) {
      return Container(color: cs.surfaceContainerHighest);
    }
    return Container(
      color: cs.surfaceContainerHighest,
      child: Center(
        child: ThemeIcon(
          _isVideo ? 'playCircle' : 'imageBroken',
          color: cs.onSurface.withAlpha(140),
          size: 40,
        ),
      ),
    );
  }
}
