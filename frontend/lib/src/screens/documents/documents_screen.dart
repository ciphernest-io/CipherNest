import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart'; // Launches native PDF reader
import 'package:path_provider/path_provider.dart'; // For temp storage
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/byte_format.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';
import '../../models/file_model.dart';
import '../../../services/activity_center.dart';
import '../../../services/database_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/encryption_service.dart';
import '../../../services/notify.dart';
import '../../../services/sync_service.dart';
import '../../utils/bulk_ops.dart';
import '../../widgets/doc_thumbnail.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../share/share_dialog.dart';
import 'document_viewer_screen.dart';
import '../../utils/safe_filename.dart';
import '../../widgets/menu_items.dart';

/// The two Adobe-Scan-style zoom states: a dense list of small-thumbnail rows,
/// and roomy cards with a large page preview. Persisted device-wide.
enum _DocView { compact, expanded }

/// Content ordering, persisted device-wide.
enum _DocSort { nameAsc, nameDesc, dateNewest, dateOldest }

const String _kDocViewPrefKey = 'documents_view_mode';
const String _kDocSortPrefKey = 'documents_sort_mode';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<CnestFile> _files = [];
  bool _loading = true;
  String? _openingFileId; // which file is currently being decrypted

  _DocView _view = _DocView.compact;
  _DocSort _sort = _DocSort.dateNewest;

  bool _searching = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  // Drag-to-select over the (single-column) list — long-press anchors a row,
  // dragging sweeps the range, edges auto-scroll. Rows tag themselves with
  // MetaData(index) so a raw hit-test finds them mid-scroll.
  final GlobalKey _listKey = GlobalKey();
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
    SyncService().syncNotifier.addListener(_onSyncComplete);
    DatabaseService().addListener(_onSyncComplete);
    _loadPrefs();
    _reload();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onSyncComplete);
    DatabaseService().removeListener(_onSyncComplete);
    _autoScrollTimer?.cancel();
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSyncComplete() {
    if (mounted) _reload();
  }

  Future<void> _reload() async {
    // Heal any .md/.markdown (etc.) that predate their document classification.
    await DatabaseService().reclassifyMisfiledDocuments();
    final files = await DatabaseService().getFilesByType(CnestFileType.document);
    if (!mounted) return;
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt(_kDocViewPrefKey);
    final s = prefs.getInt(_kDocSortPrefKey);
    if (!mounted) return;
    setState(() {
      if (v != null && v >= 0 && v < _DocView.values.length) {
        _view = _DocView.values[v];
      }
      if (s != null && s >= 0 && s < _DocSort.values.length) {
        _sort = _DocSort.values[s];
      }
    });
  }

  Future<void> _setView(_DocView v) async {
    setState(() => _view = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDocViewPrefKey, v.index);
  }

  Future<void> _setSort(_DocSort s) async {
    setState(() => _sort = s);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDocSortPrefKey, s.index);
  }

  Future<void> _handleSync() => SyncService().syncNow(force: true);

  /// The current level's files after search + sort.
  List<CnestFile> get _visible {
    final q = _query.trim().toLowerCase();
    final list = q.isEmpty
        ? List<CnestFile>.from(_files)
        : _files
            .where((f) => f.filename.toLowerCase().contains(q))
            .toList();
    int byName(CnestFile a, CnestFile b) =>
        a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
    int byDate(CnestFile a, CnestFile b) => a.createdAt.compareTo(b.createdAt);
    switch (_sort) {
      case _DocSort.nameAsc:
        list.sort(byName);
      case _DocSort.nameDesc:
        list.sort((a, b) => byName(b, a));
      case _DocSort.dateNewest:
        list.sort((a, b) => byDate(b, a));
      case _DocSort.dateOldest:
        list.sort(byDate);
    }
    return list;
  }

  // --- Open: PDFs, text/Markdown, and images render in-app (in-memory, no
  // disk); everything else (docx/xlsx/…) still decrypts to app-private temp
  // and hands off to the OS viewer.
  Future<void> _handleOpen(CnestFile file) async {
    if (_openingFileId != null) return;
    if (canViewInApp(file.filename)) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DocumentViewerScreen(file: file)));
      return;
    }
    setState(() => _openingFileId = file.id);
    try {
      if (await DatabaseService().isPriorKeyFile(file.id)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
        return;
      }
      final dir = await getTemporaryDirectory();
      final tempFile = File('${dir.path}/${safeFilename(file.filename)}');
      if (await tempFile.exists()) {
        await OpenFile.open(tempFile.path);
        return;
      }
      if (file.cloudId == null) throw Exception('File not synced');
      final encryptedBytes = await CloudService().downloadFile(file.cloudId!);
      final decryptedBytes =
          await EncryptionService.decryptFile(encryptedBytes);
      await tempFile.writeAsBytes(decryptedBytes);
      final result = await OpenFile.open(tempFile.path);
      if (result.type != ResultType.done) throw Exception(result.message);
    } catch (e) {
      if (isCryptoAuthFailure(e)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
      } else {
        Notify.error('Could not open file: $e');
      }
    } finally {
      if (mounted) setState(() => _openingFileId = null);
    }
  }

  Future<void> _handleDelete(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Move to Recycle Bin?'),
        content: Text(
          '"${file.filename}" will be hidden here. You can restore it from '
          'Recycle Bin for the next 30 days.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: TextStyle(color: ThemeController().tokens.danger)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await DatabaseService().deleteFile(file.id);
    AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
    DatabaseBackupService().scheduleBackup();
  }

  // ---- Selection --------------------------------------------------------

  void _toggle(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    _endDragSelect();
  }

  void _closeSearch() {
    _searchCtrl.clear();
    // Drop keyboard focus explicitly: when the field unmounts, focus used to
    // jump to the next focusable widget, the view-toggle button, which then
    // drew its focus highlight as if it had been tapped.
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  Future<void> _deleteSelected() async {
    final picked = _files.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${picked.length} '
            'document${picked.length == 1 ? '' : 's'}?'),
        content: const Text(
            'They move to the Recycle Bin. You can restore for 30 days.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
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
      onEach: (d) => task?.update(d, label: 'Deleting $d/${picked.length}…'),
    );
    DatabaseBackupService().scheduleBackup();
    final failed = picked.length - ok;
    final msg = 'Moved $ok to Recycle Bin'
        '${failed > 0 ? ' · $failed failed' : ''}';
    if (task != null) {
      failed > 0 ? task.fail(msg) : task.complete(msg);
    } else {
      failed > 0 ? Notify.error(msg) : Notify.info(msg);
    }
    if (mounted) _exitSelection();
  }

  void _sendSelected() {
    final picked = _files.where((f) => _selectedIds.contains(f.id)).toList();
    if (picked.isEmpty) return;
    sendFilesPlain(context, picked);
    _exitSelection();
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      // Back clears the selection / closes search before it leaves the page.
      canPop: !_selectionMode && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          _exitSelection();
        } else if (_searching) {
          _closeSearch();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(cs),
        body: RefreshIndicator(
          onRefresh: _handleSync,
          child: _buildBody(cs),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ColorScheme cs) {
    if (_selectionMode) {
      return AppBar(
        leading: IconButton(
            icon: const ThemeIcon('x'), onPressed: _exitSelection),
        title: Text('${_selectedIds.length} selected'),
        actions: [
          IconButton(
              tooltip: 'Send',
              icon: const ThemeIcon('shareFat'),
              onPressed: _selectedIds.isEmpty ? null : _sendSelected),
          IconButton(
              tooltip: 'Delete',
              icon: ThemeIcon('trash', color: cs.error),
              onPressed: _selectedIds.isEmpty ? null : _deleteSelected),
        ],
      );
    }

    if (_searching) {
      return AppBar(
        leading: IconButton(
            icon: const ThemeIcon('arrowLeft'), onPressed: _closeSearch),
        titleSpacing: 0,
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search documents',
            border: InputBorder.none,
            hintStyle: TextStyle(color: cs.onSurface.withAlpha(120)),
          ),
          onChanged: (v) => setState(() => _query = v),
        ),
        actions: [
          IconButton(
            tooltip: _query.isEmpty ? 'Close search' : 'Clear',
            icon: const ThemeIcon('x'),
            onPressed: () {
              // Clear the text; if it was already empty, close the search bar.
              if (_query.isEmpty) {
                _closeSearch();
              } else {
                _searchCtrl.clear();
                setState(() => _query = '');
              }
            },
          ),
        ],
      );
    }

    return AppBar(
      title: const Text('Documents'),
      actions: [
        IconButton(
          tooltip:
              _view == _DocView.compact ? 'Large previews' : 'Compact list',
          icon: ThemeIcon(_view == _DocView.compact ? 'squaresFour' : 'list'),
          onPressed: () => _setView(
              _view == _DocView.compact ? _DocView.expanded : _DocView.compact),
        ),
        _buildSortButton(),
        IconButton(
          tooltip: 'Search',
          icon: const ThemeIcon('magnifyingGlass'),
          onPressed: () => setState(() => _searching = true),
        ),
      ],

    );
  }

  Widget _buildSortButton() {
    String labelFor(_DocSort m) => switch (m) {
          _DocSort.nameAsc => 'Name (A–Z)',
          _DocSort.nameDesc => 'Name (Z–A)',
          _DocSort.dateNewest => 'Date (newest)',
          _DocSort.dateOldest => 'Date (oldest)',
        };
    return PopupMenuButton<_DocSort>(
      tooltip: 'Sort',
      icon: const ThemeIcon('sortAscending'),
      initialValue: _sort,
      onSelected: _setSort,
      itemBuilder: (_) => [
        for (final m in _DocSort.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Opacity(
                    opacity: m == _sort ? 1 : 0,
                    child: const ThemeIcon('check', size: 16)),
                const SizedBox(width: 8),
                Text(labelFor(m)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final files = _visible;
    if (files.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 180),
          Center(
            child: Column(
              children: [
                ThemeIcon('folderOpen',
                    size: 64, color: cs.onSurface.withAlpha(120)),
                const SizedBox(height: 16),
                Text(
                    _query.isNotEmpty
                        ? 'No matches for "$_query"'
                        : 'No documents found',
                    style: TextStyle(color: cs.onSurface.withAlpha(120))),
              ],
            ),
          ),
        ],
      );
    }

    // Raw Listener drives drag-select (one finger, after long-press). Zoom
    // state is switched by the app-bar button, not a gesture.
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
      child: _view == _DocView.compact
          ? _buildCompactList(cs, files)
          : _buildExpandedList(cs, files),
    );
  }

  Widget _buildCompactList(ColorScheme cs, List<CnestFile> files) {
    final t = ThemeController().tokens;
    return ListView.separated(
      key: _listKey,
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: files.length,
      separatorBuilder: (_, _) =>
          Divider(height: 1, color: cs.outline.withAlpha(90)),
      itemBuilder: (context, index) {
        final file = files[index];
        final isSelected = _selectedIds.contains(file.id);
        final isOpening = _openingFileId == file.id;
        return MetaData(
          metaData: index,
          child: InkWell(
            onTap: () =>
                _selectionMode ? _toggle(file.id) : _handleOpen(file),
            onLongPress: () => _beginDragSelect(file.id, index),
            child: Container(
              color: isSelected ? cs.primary.withAlpha(28) : null,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  _thumb(file, 52, t, iconSize: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(file.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 15)),
                        const SizedBox(height: 4),
                        Text(
                            '${DateFormat.yMMMd().format(file.createdAt)}  ·  '
                            '${formatBytes(file.sizeBytes)}',
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(140),
                                fontSize: 12)),
                      ],
                    ),
                  ),
                  _trailing(cs, file, isSelected, isOpening),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildExpandedList(ColorScheme cs, List<CnestFile> files) {
    final t = ThemeController().tokens;
    return ListView.separated(
      key: _listKey,
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: files.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final file = files[index];
        final isSelected = _selectedIds.contains(file.id);
        final isOpening = _openingFileId == file.id;
        return MetaData(
          metaData: index,
          child: GestureDetector(
            onTap: () =>
                _selectionMode ? _toggle(file.id) : _handleOpen(file),
            onLongPress: () => _beginDragSelect(file.id, index),
            child: Container(
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(t.rCard),
                border: Border.all(
                    color: isSelected ? cs.primary : cs.outline,
                    width: isSelected ? 1.5 : 1),
              ),
              clipBehavior: Clip.antiAlias,
              // Bounded height: a Row with crossAxisAlignment.stretch needs a
              // tight vertical constraint, which a ListView item does NOT give
              // (unbounded height) — without this the card collapsed to
              // nothing in release (blank expanded view).
              child: SizedBox(
                height: 160,
                child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Big page preview, Adobe-Scan style, on the left.
                  SizedBox(
                    width: 150,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _thumb(file, null, t, iconSize: 44),
                        if (_selectionMode)
                          Container(
                            color: isSelected
                                ? cs.primary.withAlpha(40)
                                : Colors.black.withAlpha(20),
                            alignment: Alignment.topLeft,
                            padding: const EdgeInsets.all(6),
                            child: ThemeIcon(
                                isSelected
                                    ? 'checkCircle'
                                    : 'radio_button_unchecked',
                                selected: isSelected,
                                color: isSelected ? cs.primary : Colors.white,
                                size: 22),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 6, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(file.filename,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16)),
                          const SizedBox(height: 4),
                          Text(
                              '${DateFormat.yMMMd().format(file.createdAt)}  ·  '
                              '${formatBytes(file.sizeBytes)}',
                              style: TextStyle(
                                  color: cs.onSurface.withAlpha(140),
                                  fontSize: 12)),
                          const Spacer(),
                          // Action row — hidden while selecting.
                          if (!_selectionMode)
                            Row(
                              children: [
                                IconButton(
                                  tooltip: 'Send',
                                  visualDensity: VisualDensity.compact,
                                  icon: ThemeIcon('shareFat',
                                      color: cs.onSurface.withAlpha(180),
                                      size: 20),
                                  onPressed: () =>
                                      sendFilesPlain(context, [file]),
                                ),
                                IconButton(
                                  tooltip: 'Save to device',
                                  visualDensity: VisualDensity.compact,
                                  icon: ThemeIcon('downloadSimple',
                                      color: cs.onSurface.withAlpha(180),
                                      size: 20),
                                  onPressed: () =>
                                      saveFileToDevice(context, file),
                                ),
                                const Spacer(),
                                isOpening
                                    ? Padding(
                                        padding:
                                            const EdgeInsets.only(right: 12),
                                        child: SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: cs.onSurface)),
                                      )
                                    : _menu(cs, file, inExpanded: true),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Thumbnail; [side] null = fill the parent (expanded card).
  Widget _thumb(CnestFile file, double? side, dynamic t, {double iconSize = 30}) {
    final radius = side == null
        ? BorderRadius.zero
        : BorderRadius.circular(6);
    final thumb = DocThumbnail(
      key: ValueKey('doc_${file.id}'),
      file: file,
      borderRadius: radius,
      iconSize: iconSize,
    );
    if (side == null) return thumb;
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(width: side, height: side, child: thumb),
    );
  }

  Widget _trailing(
      ColorScheme cs, CnestFile file, bool isSelected, bool isOpening) {
    if (_selectionMode) {
      return Padding(
        padding: const EdgeInsets.only(left: 6),
        child: ThemeIcon(
            isSelected ? 'checkCircle' : 'radio_button_unchecked',
            selected: isSelected,
            color: isSelected ? cs.primary : cs.onSurface.withAlpha(120),
            size: 22),
      );
    }
    if (isOpening) {
      return const Padding(
        padding: EdgeInsets.only(left: 6, right: 12),
        child: SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return _menu(cs, file);
  }

  /// [inExpanded]: the large card already shows Send and Save buttons, so
  /// the menu does not repeat them there.
  Widget _menu(ColorScheme cs, CnestFile file, {bool inExpanded = false}) {
    return PopupMenuButton<String>(
      icon: ThemeIcon('dotsThreeVertical', color: cs.onSurface.withAlpha(140)),
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        if (!inExpanded)
          iconMenuItem(cs, 'send', 'shareFat', 'Send file'),
        iconMenuItem(
            cs, 'share', 'linkSimple', 'Share secure link'),
        if (!inExpanded)
          iconMenuItem(
              cs, 'save', 'downloadSimple', 'Save to device'),
        iconMenuItem(cs, 'rename', 'pencilSimple', 'Rename'),
        iconMenuItem(cs, 'delete', 'trash', 'Delete',
            danger: true),
      ],
      onSelected: (v) {
        switch (v) {
          case 'send':
            sendFilesPlain(context, [file]);
          case 'share':
            ShareDialog.show(context, file);
          case 'save':
            saveFileToDevice(context, file);
          case 'rename':
            promptRenameFile(context, file);
          case 'delete':
            _handleDelete(file);
        }
      },
    );
  }

  // ---- drag-to-select ---------------------------------------------------

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
    final hit = _hitRowIndex(globalPos);
    if (hit == null) return;
    final files = _visible;
    final lo = math.min(anchor, hit);
    final hi = math.max(anchor, hit);
    final next = Set.of(base);
    for (var i = lo; i <= hi && i < files.length; i++) {
      next.add(files[i].id);
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

  int? _hitRowIndex(Offset globalPos) {
    final obj = _listKey.currentContext?.findRenderObject();
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
    final obj = _listKey.currentContext?.findRenderObject();
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
