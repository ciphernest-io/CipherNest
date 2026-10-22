import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

import '../../../services/activity_center.dart';
import '../../../services/audio_player_service.dart';
import '../../../services/database_service.dart';
import '../../../services/notify.dart';
import '../../../services/recycle_bin_service.dart';
import '../../utils/bulk_ops.dart';
import '../../utils/byte_format.dart';
import '../../utils/file_visuals.dart';
import '../../widgets/activity_pill.dart';
import '../../widgets/doc_thumbnail.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/photo_hero.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;
import '../music/widgets/music_widgets.dart' show TrackArt;
import 'folder_bin_detail_screen.dart';

const Duration kBinTtl = Duration(days: 30);

/// Whole days remaining before an entry deleted at [deletedAtMs] is
/// auto-purged.
int binDaysLeft(int? deletedAtMs) {
  if (deletedAtMs == null) return kBinTtl.inDays;
  final expiresAt =
      DateTime.fromMillisecondsSinceEpoch(deletedAtMs).add(kBinTtl);
  final diff = expiresAt.difference(DateTime.now()).inHours;
  if (diff <= 0) return 0;
  return (diff / 24).ceil();
}

/// The Model A folder-restore confirmation. Copy is deliberate and
/// user-mandated: the semantics must be predictable from the dialog alone.
Future<bool> confirmRestoreFolder(
    BuildContext context, CnestFolder folder) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Restore "${folder.name}"?'),
      content: const Text(
          'Restores this folder and the items removed with it. '
          'Items you deleted individually stay deleted.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore')),
      ],
    ),
  );
  return ok == true;
}

Future<bool> confirmPurgeFolder(
    BuildContext context, CnestFolder folder, int itemCount) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Delete "${folder.name}" forever?'),
      content: Text(
          'The folder and its $itemCount item${itemCount == 1 ? '' : 's'} '
          'are permanently deleted everywhere. This cannot be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('Delete forever',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Root-level "Restored" folder id, created on first use. Files whose
/// original folder no longer exists land here instead of loose at the root.
Future<String?> _ensureRestoredFolder() async {
  const name = 'Restored';
  final roots = await DatabaseService().getFolders();
  for (final f in roots) {
    if (f.name.trim().toLowerCase() == name.toLowerCase()) return f.id;
  }
  return DatabaseService().createFolder(name);
}

/// Restores [file], then — when the folder it lived in is gone (deleted or
/// purged) — tucks it into the "Restored" folder instead of leaving it loose
/// at the vault root. A file that lived at the root stays at the root.
Future<void> restoreFileToSafePlace(CnestFile file) async {
  await DatabaseService().restoreFile(file.id);
  final parentId = file.folderId;
  if (parentId == null) return; // lived at root — belongs at root
  final parent = await DatabaseService().getFolderById(parentId);
  if (parent != null && !parent.isDeleted) return; // original folder is live
  final restoredId = await _ensureRestoredFolder();
  if (restoredId != null) {
    await DatabaseService().moveFileToFolder(file.id, restoredId);
  }
}

/// Original-location breadcrumb, Windows-style. Segments that are
/// themselves deleted render greyed (decided: grey, no "(deleted)" suffix —
/// drill-in disambiguates). Pass the folder id the item LIVED in.
class FolderPathText extends StatelessWidget {
  final String? folderId;
  final double fontSize;
  const FolderPathText({super.key, required this.folderId, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (folderId == null) {
      return Text('My Vault',
          style: TextStyle(
              color: cs.onSurface.withAlpha(140), fontSize: fontSize));
    }
    return FutureBuilder<List<CnestFolder>>(
      future: DatabaseService().getFolderPathSegments(folderId!),
      builder: (context, snap) {
        final segments = snap.data ?? const <CnestFolder>[];
        if (segments.isEmpty) return const SizedBox.shrink();
        final normal = cs.onSurface.withAlpha(140);
        final greyed = cs.onSurface.withAlpha(70);
        return Text.rich(
          TextSpan(children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0)
                TextSpan(
                    text: ' / ', style: TextStyle(color: normal)),
              TextSpan(
                text: segments[i].name,
                style: TextStyle(
                    color: segments[i].isDeleted ? greyed : normal),
              ),
            ],
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: fontSize),
        );
      },
    );
  }
}

/// Recycle Bin — five tabs mirroring the home grid. Folders first: a
/// deleted folder is ONE entry with an item count; its cascade contents
/// never flood the type tabs. Type tabs show individually-deleted files
/// (plus orphans whose cause folder is gone).
class RecycleBinScreen extends StatefulWidget {
  const RecycleBinScreen({super.key, this.initialTab = 0});

  /// Which tab to open on. 0 = Folders, 1 = Photos & Videos, 2 = Documents,
  /// 3 = Music, 4 = Other. The gallery Menu opens straight to Photos & Videos.
  final int initialTab;

  @override
  State<RecycleBinScreen> createState() => _RecycleBinScreenState();
}

class _RecycleBinScreenState extends State<RecycleBinScreen> {
  // AppBar carries a TabBar — the top-anchored activity pill drops below.
  late final InsetClaim _pillInset;

  // Touch born in the system back-gesture zone: freeze the TabBarView so the
  // edge-swipe-to-go-back isn't swallowed as a tab change (same guard the
  // image viewer uses for its pager). Zero on button-nav phones, so their
  // swipes are untouched.
  bool _edgeBackGuard = false;

  @override
  void initState() {
    super.initState();
    _pillInset = ActivityPillInset.claim(kTextTabBarHeight);
  }

  @override
  void dispose() {
    _pillInset.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          centerTitle: false,
          title: const Text('Recycle Bin'),
          actions: [
            IconButton(
              tooltip: 'Search the bin',
              icon: const ThemeIcon('magnifyingGlass'),
              onPressed: () =>
                  showSearch(context: context, delegate: _BinSearchDelegate()),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Folders'),
              Tab(text: 'Photos & Videos'),
              Tab(text: 'Documents'),
              Tab(text: 'Music'),
              Tab(text: 'Other'),
            ],
          ),
        ),
        body: Listener(
          onPointerDown: (event) {
            final gz = MediaQuery.systemGestureInsetsOf(context);
            if (gz.left <= 0 && gz.right <= 0) return; // button-nav: no-op
            final x = event.position.dx;
            final w = MediaQuery.sizeOf(context).width;
            final atEdge = x <= gz.left || x >= w - gz.right;
            if (atEdge != _edgeBackGuard) {
              setState(() => _edgeBackGuard = atEdge);
            }
          },
          onPointerUp: (_) {
            if (_edgeBackGuard) setState(() => _edgeBackGuard = false);
          },
          onPointerCancel: (_) {
            if (_edgeBackGuard) setState(() => _edgeBackGuard = false);
          },
          child: TabBarView(
            // Frozen for an edge-born touch so the OS back-swipe wins.
            physics: _edgeBackGuard
                ? const NeverScrollableScrollPhysics()
                : null,
            children: const [
              _FoldersBinTab(),
              _FilesBinTab(type: CnestFileType.image, noun: 'photo'),
              _FilesBinTab(type: CnestFileType.document, noun: 'document'),
              _FilesBinTab(type: CnestFileType.audio, noun: 'track'),
              _FilesBinTab(type: CnestFileType.other, noun: 'file'),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Folders tab
// ---------------------------------------------------------------------------

class _FoldersBinTab extends StatefulWidget {
  const _FoldersBinTab();

  @override
  State<_FoldersBinTab> createState() => _FoldersBinTabState();
}

class _FoldersBinTabState extends State<_FoldersBinTab> {
  List<CnestFolder> _folders = [];
  Map<String, int> _counts = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    DatabaseService().addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    DatabaseService().removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final folders = await DatabaseService().getDeletedFolders();
    final counts = await DatabaseService().getCascadeBinnedCounts();
    if (!mounted) return;
    setState(() {
      _folders = folders;
      _counts = counts;
      _loading = false;
    });
  }

  Future<void> _restore(CnestFolder folder) async {
    if (!await confirmRestoreFolder(context, folder)) return;
    await DatabaseService().restoreFolder(folder.id);
    Notify.info('"${folder.name}" restored');
  }

  Future<void> _purge(CnestFolder folder) async {
    final count = _counts[folder.id] ?? 0;
    if (!await confirmPurgeFolder(context, folder, count)) return;
    final purged =
        await RecycleBinService().purgeFolderPermanently(folder.id);
    Notify.info('"${folder.name}" and $purged item'
        '${purged == 1 ? '' : 's'} permanently deleted');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_folders.isEmpty) {
      return _emptyState(context, 'folder', 'No deleted folders');
    }
    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, i) {
        final folder = _folders[i];
        final n = _counts[folder.id] ?? 0;
        final days =
            binDaysLeft(folder.deletedAt?.millisecondsSinceEpoch);
        return ListTile(
          leading: ThemeIcon('folder', color: cs.primary, size: 28),
          title: Text(folder.name,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FolderPathText(folderId: folder.parentId),
              Text('$n item${n == 1 ? '' : 's'} · ${days}d left',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 12)),
            ],
          ),
          isThreeLine: true,
          trailing: PopupMenuButton<String>(
            icon: const ThemeIcon('dotsThreeVertical'),
            onSelected: (v) => switch (v) {
              'restore' => _restore(folder),
              'purge' => _purge(folder),
              _ => null,
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'restore', child: Text('Restore')),
              PopupMenuItem(value: 'purge', child: Text('Delete forever')),
            ],
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => FolderBinDetailScreen(folder: folder))),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// File tabs
// ---------------------------------------------------------------------------

class _FilesBinTab extends StatefulWidget {
  final CnestFileType type;
  final String noun;
  const _FilesBinTab({required this.type, required this.noun});

  @override
  State<_FilesBinTab> createState() => _FilesBinTabState();
}

class _FilesBinTabState extends State<_FilesBinTab> {
  List<CnestFile> _files = [];
  Map<String, int> _deletedAtById = {};
  bool _loading = true;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  /// Photos & Videos get the gallery-style thumbnail grid; music gets the
  /// Music-view track rows; every other type gets the documents-style row
  /// list. Nothing opens/plays from the bin.
  bool get _isImageTab => widget.type == CnestFileType.image;
  bool get _isMusicTab => widget.type == CnestFileType.audio;

  // Drag-to-select over the photo grid — mirrors the gallery: long-press
  // anchors a tile, dragging sweeps a range, edges auto-scroll. Tiles tag
  // themselves with MetaData(index) so a raw hit-test finds them mid-scroll.
  final GlobalKey _gridKey = GlobalKey();
  final ScrollController _scrollCtrl = ScrollController();
  int? _dragAnchorIndex;
  Set<String>? _dragBaseSelection;
  bool _dragSelecting = false;
  Timer? _autoScrollTimer;
  double _autoScrollVel = 0;
  Offset? _lastDragGlobal;

  @override
  void initState() {
    super.initState();
    DatabaseService().addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    DatabaseService().removeListener(_reload);
    _autoScrollTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final files = await DatabaseService().getDeletedFiles(type: widget.type);
    // Photos read like the gallery (capture order), not by deletion time,
    // so the viewer's strip runs the same way it does everywhere else. The
    // TTL badge on each tile still says when it leaves.
    if (_isImageTab) {
      files.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    final deletedAt = <String, int>{};
    for (final f in files) {
      final ts = await DatabaseService().getDeletedAt(f.id);
      if (ts != null) deletedAt[f.id] = ts;
    }
    if (!mounted) return;
    setState(() {
      _files = files;
      _deletedAtById = deletedAt;
      _loading = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  Future<void> _restoreSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = List<String>.from(_selectedIds);
    // Pure-SQLite op: pill task only for real batches (>= 5), toast below.
    final task = ids.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Restoring 0/${ids.length}…',
            total: ids.length)
        : null;
    final byId = {for (final f in _files) f.id: f};
    final ok = await honestCount<String>(
      ids,
      (id) async {
        final f = byId[id];
        if (f != null) await restoreFileToSafePlace(f);
      },
      onEach: (d) => task?.update(d, label: 'Restoring $d/${ids.length}…'),
    );
    final failed = ids.length - ok;
    final msg = '$ok ${widget.noun}${ok == 1 ? '' : 's'} restored'
        '${failed > 0 ? ' · $failed failed' : ''}';
    if (task != null) {
      failed > 0 ? task.fail(msg) : task.complete(msg);
    } else {
      failed > 0 ? Notify.error(msg) : Notify.info(msg);
    }
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _selectAll() {
    return Future.sync(() => setState(() {
          _selectionMode = true;
          _selectedIds
            ..clear()
            ..addAll(_files.map((f) => f.id));
        }));
  }

  Future<void> _deleteForeverSelected() async {
    final picked =
        _files.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${picked.length} ${widget.noun}'
            '${picked.length == 1 ? '' : 's'} forever?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete forever',
                style:
                    TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    // Cloud + DB purge + cache wipe, one shared path with the bin viewer
    // (RecycleBinService). A failed cloud delete never blocks the purge:
    // the purge tombstone condemns the blob and the condemned-blob sweep
    // retries until it lands. A failed ROW purge is counted and reported —
    // never claimed as deleted. Network-bound → always a pill task.
    final task = ActivityCenter().start(
        kind: ActivityKind.binOp,
        label: 'Deleting 0/${picked.length}…',
        total: picked.length);
    var ok = 0;
    var done = 0;
    for (final f in picked) {
      if (await RecycleBinService().purgeFilePermanently(f)) ok++;
      done++;
      task.update(done, label: 'Deleting $done/${picked.length}…');
    }
    final failed = picked.length - ok;
    final msg = '$ok ${widget.noun}${ok == 1 ? '' : 's'} permanently '
        'deleted${failed > 0 ? ' · $failed failed' : ''}';
    failed > 0 ? task.fail(msg) : task.complete(msg);
    if (!mounted) return;
    _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_files.isEmpty) {
      return _emptyState(context, 'trash', 'Nothing here');
    }
    return PopScope(
      // Back button clears the selection first instead of leaving the bin.
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitSelection();
      },
      child: Column(
        children: [
          if (_selectionMode) _buildSelectionBar(),
          Expanded(
              child: _isImageTab
                  ? _buildGrid()
                  : _isMusicTab
                      ? _buildTrackList()
                      : _buildList()),
        ],
      ),
    );
  }

  Widget _buildSelectionBar() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        color: cs.surfaceContainerHighest,
        child: Row(
          children: [
            IconButton(
                icon: const ThemeIcon('x'), onPressed: _exitSelection),
            const SizedBox(width: 4),
            // Expanded stands in for the old Text + Spacer pair: same left
            // alignment and right-edge buttons, but the count now ellipsises
            // instead of overflowing on narrow phones.
            Expanded(
              child: Text('${_selectedIds.length} selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: cs.onSurface, fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: _selectAll,
              child: const Text('All'),
            ),
            IconButton(
              tooltip: 'Restore',
              icon: const ThemeIcon('arrowCounterClockwise'),
              onPressed: _restoreSelected,
            ),
            IconButton(
              tooltip: 'Delete forever',
              icon: ThemeIcon('trashSimple', color: cs.error),
              onPressed: _deleteForeverSelected,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid() {
    final t = ThemeController().tokens;
    // Raw Listener drives drag-select; the GridView keeps its own scrolling.
    return _wrapDragSelect(
      GridView.builder(
        key: _gridKey,
        controller: _scrollCtrl,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 1.5,
          mainAxisSpacing: 1.5,
        ),
        itemCount: _files.length,
        itemBuilder: (context, index) {
          final file = _files[index];
          final isSelected = _selectedIds.contains(file.id);
          final daysLeft = binDaysLeft(_deletedAtById[file.id]);
          // MetaData tags the tile with its index for the drag hit-test.
          return MetaData(
            metaData: index,
            child: GestureDetector(
              onTap: () {
                if (_selectionMode) {
                  _toggle(file.id);
                  return;
                }
                Navigator.of(context).push(photoViewerRoute(
                    ImageViewerScreen(
                        files: _files,
                        initialIndex: index,
                        fromRecycleBin: true)));
              },
              onLongPress: () => _beginDragSelect(file.id, index),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: 'photo-${file.id}',
                    flightShuttleBuilder: photoHeroShuttle,
                    child: GalleryGridItem(key: ValueKey(file.id), file: file),
                  ),
                  // TTL sits opposite the tick (top-right); the selection
                  // tick matches the gallery's top-left corner.
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: t.scrim,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${daysLeft}d left',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  if (_selectionMode)
                    Container(
                      color: isSelected ? t.scrim : Colors.transparent,
                      child: Align(
                        alignment: Alignment.topLeft,
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
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---- Row list (documents / music / other) ----------------------------

  Widget _buildList() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return _wrapDragSelect(ListView.separated(
      key: _gridKey,
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _files.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final file = _files[index];
        final isSelected = _selectedIds.contains(file.id);
        final daysLeft = binDaysLeft(_deletedAtById[file.id]);
        final ext = file.filename.contains('.')
            ? file.filename.split('.').last.toUpperCase()
            : '';
        Widget thumb;
        if (file.thumbnailCloudId != null) {
          // PDFs and audio with embedded art carry a real encrypted thumb.
          thumb = DocThumbnail(
            key: ValueKey(file.id),
            file: file,
            borderRadius: BorderRadius.horizontal(left: Radius.circular(t.rInput)),
            iconSize: 34,
          );
        } else {
          final v = fileVisual(file.filename, t);
          thumb = Center(
              child: ThemeIcon(v.icon, color: v.color.withAlpha(204), size: 34));
        }
        return MetaData(
          metaData: index,
          child: Opacity(
            opacity: isSelected ? 0.75 : 1,
            child: Container(
            height: 84,
            decoration: BoxDecoration(
              color: cs.surface,
              borderRadius: BorderRadius.circular(t.rInput),
              border: Border.all(
                  color: isSelected ? cs.primary : cs.outline,
                  width: isSelected ? 1.5 : 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              // No open/playback from the bin — tap only toggles selection.
              onTap: _selectionMode ? () => _toggle(file.id) : null,
              onLongPress: () => _beginDragSelect(file.id, index),
              child: Row(
                children: [
                  SizedBox(width: 74, height: double.infinity, child: thumb),
                  Expanded(
                    child: Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(file.filename,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              if (ext.isNotEmpty) ...[
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: cs.onSurface.withAlpha(25),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(ext,
                                      style: TextStyle(
                                          color: cs.onSurface.withAlpha(180),
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold)),
                                ),
                                const SizedBox(width: 8),
                              ],
                              Text('${formatBytes(file.sizeBytes)} · ${daysLeft}d left',
                                  style: TextStyle(
                                      color: cs.onSurface.withAlpha(140),
                                      fontSize: 12)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _selectionMode
                        ? ThemeIcon(
                            isSelected
                                ? 'checkCircle'
                                : 'radio_button_unchecked',
                            selected: isSelected,
                            color: isSelected
                                ? cs.primary
                                : cs.onSurface.withAlpha(120),
                            size: 22)
                        : PopupMenuButton<String>(
                            icon: ThemeIcon('dotsThreeVertical',
                                color: cs.onSurface.withAlpha(120), size: 20),
                            onSelected: (v) => switch (v) {
                              'restore' => _restoreOne(file),
                              'purge' => _purgeOne(file),
                              _ => null,
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'restore', child: Text('Restore')),
                              PopupMenuItem(
                                  value: 'purge',
                                  child: Text('Delete forever')),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        ));
      },
    ));
  }

  // ---- Track list (music) — mirrors the Music view's track rows ---------

  Widget _buildTrackList() {
    final cs = Theme.of(context).colorScheme;
    return _wrapDragSelect(ListView.builder(
      key: _gridKey,
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _files.length,
      itemBuilder: (context, index) {
        final file = _files[index];
        final isSelected = _selectedIds.contains(file.id);
        final daysLeft = binDaysLeft(_deletedAtById[file.id]);
        return MetaData(
          metaData: index,
          child: InkWell(
            // No playback from the bin — tap only toggles selection.
            onTap: _selectionMode ? () => _toggle(file.id) : null,
            onLongPress: () => _beginDragSelect(file.id, index),
            child: Container(
            color: isSelected ? cs.primary.withAlpha(30) : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                TrackArt(file: file),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AudioPlayerService.displayTitle(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 15,
                            fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 2),
                      Text('${daysLeft}d left',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(120),
                              fontSize: 12)),
                    ],
                  ),
                ),
                _selectionMode
                    ? Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: ThemeIcon(
                            isSelected
                                ? 'checkCircle'
                                : 'radio_button_unchecked',
                            selected: isSelected,
                            color: isSelected
                                ? cs.primary
                                : cs.onSurface.withAlpha(120),
                            size: 22),
                      )
                    : PopupMenuButton<String>(
                        icon: ThemeIcon('dotsThreeVertical',
                            color: cs.onSurface.withAlpha(120), size: 20),
                        onSelected: (v) => switch (v) {
                          'restore' => _restoreOne(file),
                          'purge' => _purgeOne(file),
                          _ => null,
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'restore', child: Text('Restore')),
                          PopupMenuItem(
                              value: 'purge', child: Text('Delete forever')),
                        ],
                      ),
              ],
            ),
          ),
        ));
      },
    ));
  }

  void _toggle(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  Future<void> _restoreOne(CnestFile file) async {
    await restoreFileToSafePlace(file);
    if (mounted) Notify.info('Restored');
  }

  Future<void> _purgeOne(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete forever?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete forever',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await RecycleBinService().purgeFilePermanently(file);
    if (mounted) Notify.info('Permanently deleted');
  }

  // ---- drag-to-select (all tabs) ---------------------------------------

  /// Wraps a scrollable (grid or list) so a pointer that started a
  /// long-press selection sweeps across rows/tiles and auto-scrolls at the
  /// edges. The scrollable itself must carry [_gridKey] + [_scrollCtrl] and
  /// tag its children with MetaData(index) so the hit-test can find them.
  Widget _wrapDragSelect(Widget scrollable) {
    return Listener(
      onPointerMove: (e) {
        if (_dragSelecting) _updateDragSelect(e.position);
      },
      onPointerUp: (_) {
        if (_dragSelecting) _endDragSelect();
      },
      onPointerCancel: (_) {
        if (_dragSelecting) _endDragSelect();
      },
      child: scrollable,
    );
  }

  void _beginDragSelect(String id, int index) {
    setState(() {
      _selectionMode = true;
      _selectedIds.add(id);
    });
    _dragSelecting = true;
    _dragAnchorIndex = index;
    _dragBaseSelection = Set.of(_selectedIds);
  }

  void _updateDragSelect(Offset globalPos) {
    _lastDragGlobal = globalPos;
    _maybeAutoScroll(globalPos);
    _sweepSelect(globalPos);
  }

  void _sweepSelect(Offset globalPos) {
    final anchor = _dragAnchorIndex;
    final base = _dragBaseSelection;
    if (anchor == null || base == null) return;
    final hit = _hitTileIndex(globalPos);
    if (hit == null) return;
    final lo = math.min(anchor, hit);
    final hi = math.max(anchor, hit);
    final next = Set.of(base);
    for (var i = lo; i <= hi && i < _files.length; i++) {
      next.add(_files[i].id);
    }
    if (next.length != _selectedIds.length ||
        !next.containsAll(_selectedIds)) {
      setState(() {
        _selectedIds
          ..clear()
          ..addAll(next);
      });
    }
  }

  void _endDragSelect() {
    _dragSelecting = false;
    _dragAnchorIndex = null;
    _dragBaseSelection = null;
    _lastDragGlobal = null;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  int? _hitTileIndex(Offset globalPos) {
    final obj = _gridKey.currentContext?.findRenderObject();
    if (obj is! RenderBox) return null;
    final result = BoxHitTestResult();
    obj.hitTest(result, position: obj.globalToLocal(globalPos));
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is int) {
        return target.metaData as int;
      }
    }
    return null;
  }

  void _refreshAutoScrollVel(Offset globalPos) {
    final obj = _gridKey.currentContext?.findRenderObject();
    if (obj is! RenderBox) {
      _autoScrollVel = 0;
      return;
    }
    final local = obj.globalToLocal(globalPos);
    const zone = 96.0;
    double v = 0;
    if (local.dy < zone) {
      v = -(zone - local.dy) / zone;
    } else if (local.dy > obj.size.height - zone) {
      v = (local.dy - (obj.size.height - zone)) / zone;
    }
    _autoScrollVel = v * 16;
  }

  void _maybeAutoScroll(Offset globalPos) {
    _refreshAutoScrollVel(globalPos);
    if (_autoScrollVel == 0) {
      _autoScrollTimer?.cancel();
      _autoScrollTimer = null;
      return;
    }
    _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final at = _lastDragGlobal;
      if (at != null) _refreshAutoScrollVel(at);
      if (_autoScrollVel == 0) {
        _autoScrollTimer?.cancel();
        _autoScrollTimer = null;
        return;
      }
      if (!_scrollCtrl.hasClients) return;
      final target = (_scrollCtrl.offset + _autoScrollVel)
          .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
      _scrollCtrl.jumpTo(target);
      final at2 = _lastDragGlobal;
      if (at2 != null) _sweepSelect(at2);
    });
  }
}

Widget _emptyState(BuildContext context, String icon, String message) {
  final cs = Theme.of(context).colorScheme;
  return Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ThemeIcon(icon, size: 64, color: cs.onSurface.withAlpha(120)),
        const SizedBox(height: 12),
        Text(message,
            style: TextStyle(color: cs.onSurface.withAlpha(140))),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Bin search — finds cascade-binned files too and offers the folder restore
// ---------------------------------------------------------------------------

class _BinSearchDelegate extends SearchDelegate<void> {
  @override
  String get searchFieldLabel => 'Search deleted files';

  @override
  List<Widget> buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
              icon: const ThemeIcon('x'), onPressed: () => query = ''),
      ];

  @override
  Widget buildLeading(BuildContext context) => IconButton(
      icon: const ThemeIcon('arrowLeft'),
      onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => _results(context);

  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    if (query.trim().isEmpty) return const SizedBox.shrink();
    return FutureBuilder<List<CnestFile>>(
      future: DatabaseService().searchDeletedFiles(query),
      builder: (context, snap) {
        final files = snap.data;
        if (files == null) {
          return const Center(child: CircularProgressIndicator());
        }
        if (files.isEmpty) {
          return _emptyState(context, 'trash', 'No deleted files match');
        }
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, i) => _BinSearchResultTile(file: files[i]),
        );
      },
    );
  }
}

class _BinSearchResultTile extends StatelessWidget {
  final CnestFile file;
  const _BinSearchResultTile({required this.file});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cause = _causeFolderId();
    return ListTile(
      leading: SizedBox(
        width: 44,
        height: 44,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: GalleryGridItem(key: ValueKey(file.id), file: file),
        ),
      ),
      title: Text(file.filename,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: FolderPathText(folderId: file.folderId),
      trailing: cause != null
          // trailing gets loose constraints, so without a cap the button
          // takes its natural width and the ellipsis never engages.
          ? ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: _RestoreFolderCta(file: file, causeFolderId: cause),
            )
          : TextButton(
              onPressed: () async {
                await DatabaseService().restoreFile(file.id);
                Notify.info('"${file.filename}" restored');
              },
              child: const Text('Restore'),
            ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
              files: [file], initialIndex: 0, fromRecycleBin: true))),
      textColor: cs.onSurface,
    );
  }

  /// A cascade-binned search hit belongs to a deleted folder — surface
  /// `Restore '<folder>'` as the primary action (the file's context comes
  /// back with it). Individually-deleted hits get a plain Restore.
  String? _causeFolderId() => file.deletedByFolderId;
}

/// Loads the cause folder (if any) for a binned file and renders the
/// primary `Restore '<folder>'` CTA with single-file restore secondary.
class _RestoreFolderCta extends StatelessWidget {
  final CnestFile file;
  final String causeFolderId;
  const _RestoreFolderCta(
      {required this.file, required this.causeFolderId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<CnestFolder>>(
      future: DatabaseService().getFolderPathSegments(causeFolderId),
      builder: (context, snap) {
        final folder =
            (snap.data?.isNotEmpty ?? false) ? snap.data!.last : null;
        if (folder == null) return const SizedBox.shrink();
        return TextButton(
          onPressed: () async {
            if (!await confirmRestoreFolder(context, folder)) return;
            await DatabaseService().restoreFolder(folder.id);
            Notify.info('"${folder.name}" restored');
          },
          child: Text('Restore "${folder.name}"',
              maxLines: 1, overflow: TextOverflow.ellipsis),
        );
      },
    );
  }
}
