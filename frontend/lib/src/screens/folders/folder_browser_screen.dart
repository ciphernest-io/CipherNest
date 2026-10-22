import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../services/activity_center.dart';
import '../../../services/audio_player_service.dart';
import '../../../services/cnest_errors.dart';
import '../../config/routes.dart';
import '../../../services/notify.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/saf_folder_import.dart';
import '../../../services/subscription_service.dart';
import '../../../services/upload_foreground_guard.dart';
import '../../../services/upload_pipeline.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../../config/theme_controller.dart';
import '../../utils/bulk_ops.dart';
import '../../utils/byte_format.dart';
import '../../utils/file_visuals.dart';
import '../../widgets/activity_pill.dart';
import '../../widgets/doc_thumbnail.dart';
import '../capture/capture_screen.dart';
import '../documents/document_viewer_screen.dart';
import 'upload_picker_session.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/folder_picker_sheet.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/menu_items.dart';
import '../../widgets/theme_icon.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/photo_hero.dart';
import '../../utils/safe_filename.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;

/// How folder contents are ordered. Persisted device-wide (one preference
/// across every folder) under [_kSortPrefKey].
enum _FolderSort { nameAsc, nameDesc, dateNewest, dateOldest }

const String _kSortPrefKey = 'folder_sort_mode';

/// The virtual folder tree, browsed one level at a time: subfolder rows on
/// top, files as Drive-style rows below (thumbnail left, name/size/date
/// right). This tab is the FILE SYSTEM view of the one vault tree — media
/// here renders as rows and opens as an in-place single-file preview; the
/// swipeable grid/timeline presentation of the same files stays exclusive
/// to the Photos & Videos tab. Navigating into a folder pushes another
/// instance of this screen.
///
/// All mutations route through DatabaseService's folder choke points —
/// every action becomes an op, and the visible state is applyMergedState's
/// materialization of the log (there is no second writer to disagree with).
class FolderBrowserScreen extends StatefulWidget {
  /// null = root ("Folders").
  final CnestFolder? folder;

  /// Non-null = PICKER MODE (pick-then-place upload): the browser becomes a
  /// destination chooser — file rows render inert/dimmed, folder rows
  /// navigate (carrying the same session), the New-folder button stays (a
  /// mid-flow create is the point), and a Cancel / "Upload here" footer
  /// completes the session. All mutating affordances are suppressed.
  final UploadPickerSession? pickerSession;

  const FolderBrowserScreen({super.key, this.folder, this.pickerSession});

  @override
  State<FolderBrowserScreen> createState() => _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends State<FolderBrowserScreen> {
  List<CnestFolder> _folders = [];
  List<CnestFile> _files = [];
  Map<String, int> _counts = {};
  bool _loading = true;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};
  bool _isUploading = false;
  String? _openingFileId;

  /// True when a Free vault is at the cap: the Upload button dims and opens
  /// the limit sheet instead of a picker. Seeded from the last known answer
  /// so the button does not flash enabled for one frame on every push.
  bool _atLimit = FreeTierGuard.lastKnown?.atLimit ?? false;

  // Sort + search over the current level's contents (both suppressed in
  // picker mode, where the browser is a destination chooser).
  _FolderSort _sort = _FolderSort.dateNewest;
  bool _searching = false;
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// Fresh row for the folder being viewed (widget.folder goes stale the
  /// moment a rename/hide lands elsewhere). Null at root.
  CnestFolder? _self;

  String? get _folderId => widget.folder?.id;
  bool get _isPicker => widget.pickerSession != null;

  @override
  void initState() {
    super.initState();
    DatabaseService().addListener(_reload);
    SubscriptionService().addListener(_reload);
    _loadSort();
    _reload();
  }

  @override
  void dispose() {
    DatabaseService().removeListener(_reload);
    SubscriptionService().removeListener(_reload);
    _selectionClaim?.release();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSort() async {
    final prefs = await SharedPreferences.getInstance();
    final idx = prefs.getInt(_kSortPrefKey);
    if (idx == null || idx < 0 || idx >= _FolderSort.values.length) return;
    if (!mounted) return;
    setState(() => _sort = _FolderSort.values[idx]);
  }

  Future<void> _setSort(_FolderSort mode) async {
    setState(() => _sort = mode);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSortPrefKey, mode.index);
  }

  /// Case-insensitive substring match on name; empty query matches all.
  bool _matchesQuery(String name) =>
      _query.isEmpty || name.toLowerCase().contains(_query.toLowerCase());

  /// Applies the active sort to a copy of [items]. Folders and files share
  /// the comparators — [nameOf]/[dateOf] adapt each type.
  List<T> _sorted<T>(
      List<T> items, String Function(T) nameOf, DateTime? Function(T) dateOf) {
    final out = List<T>.from(items);
    int byName(T a, T b) =>
        nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
    int byDate(T a, T b) {
      final da = dateOf(a), db = dateOf(b);
      if (da == null && db == null) return byName(a, b);
      if (da == null) return 1; // undated sinks to the bottom
      if (db == null) return -1;
      return da.compareTo(db);
    }

    switch (_sort) {
      case _FolderSort.nameAsc:
        out.sort(byName);
      case _FolderSort.nameDesc:
        out.sort((a, b) => byName(b, a));
      case _FolderSort.dateNewest:
        out.sort((a, b) => byDate(b, a));
      case _FolderSort.dateOldest:
        out.sort(byDate);
    }
    return out;
  }

  Future<void> _reload() async {
    final folders = await DatabaseService().getFolders(parentId: _folderId);
    final files = await DatabaseService().getFilesInFolder(_folderId);
    final counts = await DatabaseService().getFolderItemCounts();
    final tier = await FreeTierGuard.status();
    if (!mounted) return;
    // The folder itself may have been deleted/restored elsewhere mid-view
    // (a sync can bin the very folder being browsed) — pop rather than
    // showing a ghost. The fresh self row also keeps the hide toggle's
    // label live (widget.folder is a stale snapshot).
    CnestFolder? self;
    if (_folderId != null) {
      final segments =
          await DatabaseService().getFolderPathSegments(_folderId!);
      if (!mounted) return;
      if (segments.isEmpty || segments.last.isDeleted) {
        Navigator.of(context).pop();
        return;
      }
      self = segments.last;
    }
    setState(() {
      _folders = folders;
      _files = files;
      _counts = counts;
      _self = self;
      _atLimit = tier.atLimit;
      _loading = false;
    });
  }

  /// The Free-limit sheet, with the only purchase entry point a user who
  /// finished onboarding can reach.
  Future<void> _showLimitSheet({int notStored = 0}) async {
    final err = await FreeTierGuard.limitError(notStored: notStored);
    if (!mounted) return;
    await showCnestError(
      context,
      err,
      onPrimaryAction: () =>
          Navigator.pushNamed(context, AppRoutes.subscription),
    );
  }

  // ---- Folder actions ---------------------------------------------------

  Future<void> _createFolder() async {
    final name = await _promptForName(title: 'New folder');
    if (name == null || name.isEmpty) return;
    if (await _siblingNameTaken(name)) return;
    await DatabaseService().createFolder(name, parentId: _folderId);
  }

  Future<bool> _siblingNameTaken(String name) async {
    final siblings = _folders.map((f) => f.name.toLowerCase()).toSet();
    if (widget.folder != null &&
        widget.folder!.name.toLowerCase() == name.toLowerCase()) {
      return false;
    }
    if (siblings.contains(name.toLowerCase())) {
      Notify.error('A folder named "$name" already exists here');
      return true;
    }
    return false;
  }

  Future<String?> _promptForName({required String title, String? initial}) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _renameFolder(CnestFolder folder) async {
    final name =
        await _promptForName(title: 'Rename folder', initial: folder.name);
    if (name == null || name.isEmpty || name == folder.name) return;
    if (await _siblingNameTaken(name)) return;
    await DatabaseService().renameFolder(folder.id, name);
  }

  Future<void> _moveFolder(CnestFolder folder) async {
    final pick = await showFolderPicker(context,
        title: 'Move "${folder.name}" to', excludeSubtreeOf: folder.id);
    if (pick == null) return;
    final moved = await DatabaseService().moveFolder(folder.id, pick.folderId);
    if (!moved) {
      Notify.error('A folder can\'t be moved into itself');
    }
  }

  /// [popAfter] pops this screen once the delete lands — true when the folder
  /// being deleted is the one currently open (the app-bar menu), false when
  /// it is a row in the list (the parent stays put).
  Future<void> _deleteFolder(CnestFolder folder, {bool popAfter = false}) async {
    // Subtree totals, not the direct-children chip — the dialog must state
    // what the cascade will ACTUALLY bin.
    final sub = await DatabaseService().getFolderSubtreeCounts(folder.id);
    if (!mounted) return;
    final contains = <String>[
      if (sub.folders > 0) '${sub.folders} folder${sub.folders == 1 ? '' : 's'}',
      if (sub.files > 0) '${sub.files} file${sub.files == 1 ? '' : 's'}',
    ].join(' and ');
    // Op-less stragglers (still-syncing or previous-phrase files) are
    // outside the cascade's reach — say so instead of implying they bin.
    final strandedNote = sub.unsyncedFiles > 0
        ? '\n\n${sub.unsyncedFiles} file'
            '${sub.unsyncedFiles == 1 ? " isn't" : "s aren't"} synced yet '
            'and will stay in your vault, outside this folder.'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: Text(
            '${contains.isEmpty ? 'The folder moves' : 'The folder, with '
                '$contains inside, moves'} to the Recycle Bin '
            'as one entry. You can restore it for 30 days.$strandedNote'),
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
    if (confirmed != true) return;
    await DatabaseService().deleteFolder(folder.id);
    if (popAfter && mounted) Navigator.of(context).pop();
  }

  // ---- File selection ---------------------------------------------------

  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
    _updateSelectionClaim();
  }

  /// Bulk hide from the specialized views — always HIDES; unhide is
  /// per-row (this browser keeps showing hidden files).
  Future<void> _hideSelectedFiles() async {
    final ids = List<String>.from(_selectedIds);
    if (ids.isEmpty) return;
    final task = ids.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Hiding 0/${ids.length}…',
            total: ids.length)
        : null;
    final ok = await honestCount<String>(
      ids,
      (id) => DatabaseService().setFileHidden(id, true),
      onEach: (d) => task?.update(d, label: 'Hiding $d/${ids.length}…'),
    );
    final failed = ids.length - ok;
    final msg =
        'Hidden from views · $ok${failed > 0 ? ' · $failed failed' : ''}';
    if (task != null) {
      failed > 0 ? task.fail(msg) : task.complete(msg);
    } else {
      failed > 0 ? Notify.error(msg) : Notify.info(msg);
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    _updateSelectionClaim();
  }

  /// Confirms, then soft-deletes ONE file to the Recycle Bin (30-day
  /// restore, same as folder delete).
  Future<void> _deleteOneFile(CnestFile file) async {
    final ok = await _confirmDeleteFiles(1);
    if (ok != true) return;
    await DatabaseService().deleteFile(file.id);
    if (mounted) Notify.info('Moved to Recycle Bin');
  }

  Future<void> _deleteSelectedFiles() async {
    final ids = List<String>.from(_selectedIds);
    if (ids.isEmpty) return;
    final ok = await _confirmDeleteFiles(ids.length);
    if (ok != true) return;
    final task = ids.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Deleting 0/${ids.length}…',
            total: ids.length)
        : null;
    final done = await honestCount<String>(
      ids,
      (id) => DatabaseService().deleteFile(id),
      onEach: (d) => task?.update(d, label: 'Deleting $d/${ids.length}…'),
    );
    final failed = ids.length - done;
    final msg = 'Moved $done to Recycle Bin'
        '${failed > 0 ? ' · $failed failed' : ''}';
    if (task != null) {
      failed > 0 ? task.fail(msg) : task.complete(msg);
    } else {
      failed > 0 ? Notify.error(msg) : Notify.info(msg);
    }
    if (!mounted) return;
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    _updateSelectionClaim();
  }

  Future<bool?> _confirmDeleteFiles(int n) {
    final noun = n == 1 ? 'this file' : 'these $n files';
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(n == 1 ? 'Delete file?' : 'Delete $n files?'),
        content: Text(
            'Move $noun to the Recycle Bin? You can restore for 30 days.'),
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
  }

  // The in-body selection bar sits right under the AppBar — exactly where
  // the top-anchored activity pill floats. Claim clearance while it shows.
  InsetClaim? _selectionClaim;
  void _updateSelectionClaim() {
    if (_selectionMode && _selectionClaim == null) {
      _selectionClaim = ActivityPillInset.claim(60);
    } else if (!_selectionMode) {
      _selectionClaim?.release();
      _selectionClaim = null;
    }
  }

  Future<void> _moveOneFile(CnestFile file) async {
    final pick = await showFolderPicker(context);
    if (pick == null) return;
    final moved =
        await DatabaseService().moveFileToFolder(file.id, pick.folderId);
    // A refusal (still-syncing file) already toasted its own explanation.
    if (moved) Notify.info('Moved to "${pick.label}"');
  }

  Future<void> _moveSelectedFiles() async {
    final pick = await showFolderPicker(context);
    if (pick == null) return;
    final ids = List<String>.from(_selectedIds);
    // Per-item try/catch (one bad row must not abort the batch) + honest
    // count — never report the requested count as the success count.
    final task = ids.length >= 5
        ? ActivityCenter().start(
            kind: ActivityKind.binOp,
            label: 'Moving 0/${ids.length}…',
            total: ids.length)
        : null;
    final ok = await honestCount<String>(
      ids,
      (id) async {
        // A refused move (still-syncing file) must count as a failure, not
        // a success — replay can't materialize it (see moveFileToFolder).
        if (!await DatabaseService().moveFileToFolder(id, pick.folderId)) {
          throw StateError('file not op-backed yet');
        }
      },
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
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
    _updateSelectionClaim();
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return PopScope(
      // Back button DESELECTS / closes search before it pops the page.
      canPop: !_selectionMode && !_searching,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_selectionMode) {
          setState(() {
            _selectionMode = false;
            _selectedIds.clear();
          });
          _updateSelectionClaim();
        } else if (_searching) {
          _closeSearch();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(cs),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_selectionMode && !_isPicker) _buildSelectionBar(),
                  Expanded(child: _buildBody(cs)),
                ],
              ),
        bottomNavigationBar: _isPicker ? _buildPickerFooter(cs) : null,
        floatingActionButton: _selectionMode || _isPicker
            ? null
            : FloatingActionButton.extended(
                onPressed: _isUploading
                    ? null
                    : _atLimit
                        ? _showLimitSheet
                        : _showBrowserUploadSheet,
                backgroundColor:
                    _atLimit ? cs.primary.withAlpha(110) : cs.primary,
                icon: _isUploading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: cs.onPrimary, strokeWidth: 2))
                    : ThemeIcon(_atLimit ? 'lockKey' : 'uploadSimple',
                        color: cs.onPrimary),
                // Counted progress lives in the activity pill; the FAB just
                // shows busy + disabled. At the Free cap it dims and opens
                // the limit sheet: nothing can be stored, nothing to pick.
                label: Text(_isUploading
                    ? 'Encrypting...'
                    : _atLimit
                        ? 'Vault full'
                        : 'Upload'),
              ),
      ),
    );
  }

  void _closeSearch() {
    _searchCtrl.clear();
    setState(() {
      _searching = false;
      _query = '';
    });
  }

  PreferredSizeWidget _buildAppBar(ColorScheme cs) {
    final title =
        _isPicker ? 'Choose a folder' : (widget.folder?.name ?? 'Folders');

    if (_searching) {
      return AppBar(
        leading: IconButton(
            icon: const ThemeIcon('arrowLeft'), onPressed: _closeSearch),
        titleSpacing: 0,
        title: TextField(
          controller: _searchCtrl,
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search this folder',
            border: InputBorder.none,
            hintStyle: TextStyle(color: cs.onSurface.withAlpha(120)),
          ),
          onChanged: (v) => setState(() => _query = v.trim()),
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
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: 'New folder',
          icon: const ThemeIcon('plus'),
          onPressed: _createFolder,
        ),
        if (widget.folder != null && !_isPicker)
          PopupMenuButton<String>(
            icon: const ThemeIcon('dotsThreeVertical'),
            onSelected: (v) => switch (v) {
              'rename' => _renameFolder(widget.folder!),
              'move' => _moveFolder(widget.folder!),
              'hide' => DatabaseService().setFolderHidden(
                  _folderId!, !((_self ?? widget.folder!).isHidden)),
              'delete' => _deleteFolder(widget.folder!, popAfter: true),
              _ => null,
            },
            itemBuilder: (_) => [
              iconMenuItem(cs, 'rename', 'pencilSimple', 'Rename'),
              iconMenuItem(cs, 'move', 'folderSimple', 'Move'),
              iconMenuItem(
                  cs,
                  'hide',
                  (_self ?? widget.folder!).isHidden
                      ? 'visibility'
                      : 'visibility_off',
                  (_self ?? widget.folder!).isHidden
                      ? 'Unhide'
                      : 'Hide from views'),
              iconMenuItem(cs, 'delete', 'trash', 'Delete', danger: true),
            ],
          ),
        if (!_isPicker) _buildSortButton(),
        if (!_isPicker)
          IconButton(
            tooltip: 'Search',
            icon: const ThemeIcon('magnifyingGlass'),
            onPressed: () => setState(() => _searching = true),
          ),
      ],
    );
  }

  Widget _buildSortButton() {
    String labelFor(_FolderSort m) => switch (m) {
          _FolderSort.nameAsc => 'Name (A–Z)',
          _FolderSort.nameDesc => 'Name (Z–A)',
          _FolderSort.dateNewest => 'Date (newest)',
          _FolderSort.dateOldest => 'Date (oldest)',
        };
    return PopupMenuButton<_FolderSort>(
      tooltip: 'Sort',
      icon: const ThemeIcon('sortAscending'),
      initialValue: _sort,
      onSelected: _setSort,
      itemBuilder: (_) => [
        for (final m in _FolderSort.values)
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

  // ---- Picker mode (pick-then-place upload) -----------------------------

  Widget _buildPickerFooter(ColorScheme cs) {
    final session = widget.pickerSession!;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          border: Border(top: BorderSide(color: cs.outline.withAlpha(90))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${session.label} → ${_self?.name ?? 'My Vault'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: cs.onSurface.withAlpha(160), fontSize: 12),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                TextButton(
                  onPressed: () => _finishPicker(null),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => _finishPicker(FolderPickResult(
                      folderId: _folderId,
                      label: _self?.name ?? 'My Vault')),
                  child: const Text('Upload here'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Completes the session (once) and pops the WHOLE picker stack in one
  /// motion — every picker route carries [kUploadPickerRouteName]. A user
  /// backing out level-by-level instead resolves via the caller's
  /// complete(null) fallback.
  void _finishPicker(FolderPickResult? result) {
    final session = widget.pickerSession!;
    if (!session.destination.isCompleted) {
      session.destination.complete(result);
    }
    Navigator.of(context)
        .popUntil((r) => r.settings.name != kUploadPickerRouteName);
  }

  void _showBrowserUploadSheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      // Four tiles (320dp) exceed the default 9/16 cap in landscape.
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThemeIcon('camera', color: cs.primary),
              title: Text('Take photo',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text('Into "${widget.folder?.name ?? 'My Vault'}"',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _captureHere(video: false);
              },
            ),
            ListTile(
              leading: ThemeIcon('videoCamera', color: cs.primary),
              title: Text('Record video',
                  style: TextStyle(color: cs.onSurface)),
              onTap: () {
                Navigator.pop(ctx);
                _captureHere(video: true);
              },
            ),
            ListTile(
              leading: ThemeIcon('uploadSimple', color: cs.primary),
              title: Text('Upload files',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text('Into "${widget.folder?.name ?? 'My Vault'}"',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _uploadHere();
              },
            ),
            ListTile(
              leading: ThemeIcon('folderOpen', color: cs.primary),
              title: Text('Import a folder',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text('Keeps its subfolder structure',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                _importFolder();
              },
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }

  /// SAF folder import: mirrors the picked tree as CipherNest folders under
  /// the current one, then uploads file-by-file (one plaintext cache copy
  /// on disk at a time; the pipeline deletes it per file). Windows-copy
  /// semantics: the imported folder arrives INTACT — a file whose bytes
  /// already exist elsewhere in the vault still becomes a real copy here
  /// (skipDuplicates: false). A silently incomplete import is a worse
  /// surprise than a duplicated photo.
  Future<void> _importFolder() async {
    SafTree? tree;
    // The tree walk runs before any file moves; on a thousand-entry folder
    // that is seconds of silence. Show it as work in progress.
    final reading = ActivityCenter()
        .start(kind: ActivityKind.folderImport, label: 'Reading folder…');
    try {
      tree = await SafFolderImport.pickTree();
    } on PlatformException {
      reading.discard();
      Notify.error('Couldn\'t read that folder. Try "Upload files" instead.');
      return;
    } catch (_) {
      reading.discard();
      rethrow;
    }
    reading.discard();
    if (tree == null || !mounted) return; // cancelled
    final picked = tree;
    if (picked.entries.isEmpty) {
      Notify.error('That folder has no files.');
      return;
    }

    setState(() => _isUploading = true);
    // One foreground pin across the whole import — the per-batch pins nest
    // inside it (ref-counted), so the notification doesn't flap between
    // files.
    final guard = UploadForegroundGuard();
    await guard.begin();
    var secured = 0, failed = 0, overLimit = 0;
    String rootName = picked.name;
    final task = ActivityCenter().start(
        kind: ActivityKind.folderImport,
        label: 'Importing "${picked.name}"',
        total: picked.entries.length);
    try {
      // Import root, sibling-name deduped ("Trip" -> "Trip (1)").
      final siblings = _folders.map((f) => f.name.toLowerCase()).toSet();
      var n = 1;
      while (siblings.contains(rootName.toLowerCase())) {
        rootName = '${picked.name} (${n++})';
      }
      final rootId =
          await DatabaseService().createFolder(rootName, parentId: _folderId);
      if (rootId == null) throw Exception('No active account.');

      // Folder chain per unique relative dir (only dirs that contain files
      // are materialized).
      final dirToId = <String, String>{'': rootId};
      Future<String> ensureDir(String rel) async {
        final existing = dirToId[rel];
        if (existing != null) return existing;
        final slash = rel.lastIndexOf('/');
        final parentRel = slash < 0 ? '' : rel.substring(0, slash);
        final leaf = slash < 0 ? rel : rel.substring(slash + 1);
        final parentId = await ensureDir(parentRel);
        final id =
            await DatabaseService().createFolder(leaf, parentId: parentId);
        if (id == null) throw Exception('No active account.');
        dirToId[rel] = id;
        return id;
      }

      for (var i = 0; i < picked.entries.length; i++) {
        final e = picked.entries[i];
        final targetId = await ensureDir(e.dir);
        final path = await SafFolderImport.copyToCache(e);
        if (path == null) {
          failed++;
        } else {
          final res = await UploadPipeline.uploadBatch(
            [PlatformFile(name: e.name, size: e.size, path: path)],
            category: UploadCategory.other,
            folderId: targetId,
            skipDuplicates: false,
            trackActivity: false, // the outer import task counts instead
          );
          // The Free cap stops the import here: every remaining entry
          // would fail the same way, so neither copy nor hash them.
          if (res.any((o) => o.error is FreeLimitReachedError)) {
            overLimit = picked.entries.length - i;
            task.update(picked.entries.length,
                label: 'Import stopped at the Free limit');
            break;
          }
          for (final o in res) {
            if (o.ok) {
              secured++;
            } else {
              failed++;
            }
          }
        }
        task.update(i + 1,
            label: 'Importing ${i + 1}/${picked.entries.length}',
            detail: e.name);
      }

      final parts = <String>[];
      if (secured > 0) parts.add('$secured file${secured == 1 ? '' : 's'}');
      if (overLimit > 0) parts.add('$overLimit over the Free limit');
      if (failed > 0) parts.add('$failed failed');
      // No silent caps: a truncated walk is said out loud.
      if (picked.truncated) parts.add('first 2000 files only');
      final summary = 'Imported "$rootName": ${parts.join(' · ')}';
      (failed > 0 || overLimit > 0) ? task.fail(summary) : task.complete(summary);
      if (overLimit > 0 && mounted) {
        await _showLimitSheet(notStored: overLimit);
      }
    } catch (e) {
      task.fail('Import of "$rootName" failed');
      if (mounted) {
        await showCnestError(context, UploadPipeline.mapUploadError(e));
      }
    } finally {
      await guard.end();
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// In-app capture straight into the folder being viewed — the browser's
  /// context IS the destination, so no place flow.
  Future<void> _captureHere({required bool video}) async {
    final statuses = await [
      Permission.camera,
      if (video) Permission.microphone,
    ].request();
    if (statuses.values.any((s) => !s.isGranted)) {
      Notify.error('Camera permission is required to capture');
      return;
    }
    if (!mounted) return;
    final pick = await Navigator.of(context).push<PlatformFile>(
      MaterialPageRoute(
          builder: (_) => CaptureScreen(startInVideoMode: video)),
    );
    if (pick == null) return;
    if (!mounted) {
      // ZK hygiene: no upload will run, so the plaintext capture in temp
      // must die here (the pipeline's finally only covers attempted
      // uploads).
      final path = pick.path;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      return;
    }

    setState(() => _isUploading = true);
    try {
      final outcomes = await UploadPipeline.uploadBatch(
        [pick],
        category: UploadCategory.media,
        folderId: _folderId,
      );
      if (mounted) await _reportUploadOutcomes(outcomes);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Uploads into the folder currently being viewed (root = unfiled).
  /// Unrestricted picker, extension-classified — exactly Drive's "+".
  Future<void> _uploadHere() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: false,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;

    setState(() => _isUploading = true);
    try {
      // Progress + summary ride the activity pill (uploadBatch registers
      // the task).
      final outcomes = await UploadPipeline.uploadBatch(
        result.files,
        category: UploadCategory.other,
        folderId: _folderId,
      );
      if (mounted) await _reportUploadOutcomes(outcomes);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  /// Only a failure's DETAIL still needs this screen (the actionable error
  /// sheet); everything else rides the pill.
  Future<void> _reportUploadOutcomes(List<UploadOutcome> outcomes) async {
    final failures = outcomes.where((o) => !o.ok).toList();
    if (failures.isNotEmpty && mounted) {
      // A cap hit outranks any other failure in the batch: it is the one
      // the user can act on from the sheet.
      final first = failures.firstWhere(
          (o) => o.error is FreeLimitReachedError,
          orElse: () => failures.first);
      final err = UploadPipeline.mapUploadError(first.error!);
      await showCnestError(
        context,
        err,
        // The free-limit sheet's primary action is the only purchase entry
        // point a user who finished onboarding can reach. Without this the
        // button exists and does nothing.
        onPrimaryAction: err is FreeLimitReachedError
            ? () => Navigator.pushNamed(context, AppRoutes.subscription)
            : null,
      );
    }
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
              icon: const ThemeIcon('x'),
              onPressed: () {
                setState(() {
                  _selectionMode = false;
                  _selectedIds.clear();
                });
                _updateSelectionClaim();
              },
            ),
            Text('${_selectedIds.length} selected',
                style: TextStyle(
                    color: cs.onSurface, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              tooltip: 'Move to folder',
              icon: const ThemeIcon('folder'),
              onPressed: _selectedIds.isEmpty ? null : _moveSelectedFiles,
            ),
            IconButton(
              tooltip: 'Hide from views',
              icon: const ThemeIcon('visibility_off'),
              onPressed: _selectedIds.isEmpty ? null : _hideSelectedFiles,
            ),
            IconButton(
              tooltip: 'Delete',
              icon: ThemeIcon('trash', color: cs.error),
              onPressed: _selectedIds.isEmpty ? null : _deleteSelectedFiles,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_folders.isEmpty && _files.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeIcon('folderOpen',
                size: 64, color: cs.onSurface.withAlpha(120)),
            const SizedBox(height: 12),
            Text(
              widget.folder == null
                  ? 'No folders yet.\nTap + to create one, or Upload to '
                      'add files.'
                  : 'This folder is empty.\nUpload here, or move files in '
                      'from any tab\'s selection mode.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurface.withAlpha(140)),
            ),
          ],
        ),
      );
    }

    // Filter by the live search query, then order by the active sort.
    // System folders ("Phone Backup" tree) sit BELOW user folders as one
    // unobtrusive row each — the auto-sync machinery must not clutter the
    // root's user-created organization.
    final folders =
        _folders.where((f) => _matchesQuery(f.name)).toList();
    final files = _sorted(
      _files.where((f) => _matchesQuery(f.filename)).toList(),
      (f) => f.filename,
      (f) => f.createdAt,
    );
    final userFolders = _sorted(
      folders.where((f) => !f.isSystem).toList(),
      (f) => f.name,
      (f) => f.createdAt,
    );
    final systemFolders = _sorted(
      folders.where((f) => f.isSystem).toList(),
      (f) => f.name,
      (f) => f.createdAt,
    );

    if (_query.isNotEmpty && folders.isEmpty && files.isEmpty) {
      return Center(
        child: Text('No matches for "$_query"',
            style: TextStyle(color: cs.onSurface.withAlpha(140))),
      );
    }

    return CustomScrollView(
      slivers: [
        if (userFolders.isNotEmpty)
          SliverList.builder(
            itemCount: userFolders.length,
            itemBuilder: (context, i) => _folderRow(cs, userFolders[i]),
          ),
        if (systemFolders.isNotEmpty)
          SliverList.builder(
            itemCount: systemFolders.length,
            itemBuilder: (context, i) => _folderRow(cs, systemFolders[i]),
          ),
        if (folders.isNotEmpty && files.isNotEmpty)
          const SliverToBoxAdapter(child: Divider(height: 1)),
        if (files.isNotEmpty)
          SliverList.builder(
            itemCount: files.length,
            itemBuilder: (context, i) => _fileRow(cs, files[i]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _folderRow(ColorScheme cs, CnestFolder f) {
    final n = _counts[f.id] ?? 0;
    final countLabel = '$n item${n == 1 ? '' : 's'}';
    final hidden = f.isHidden || f.hiddenEffective;
    var subtitle = f.isSystem ? 'Auto-synced media · $countLabel' : countLabel;
    if (hidden) subtitle = '$subtitle · Hidden from views';
    return ListTile(
      leading: ThemeIcon(f.isSystem ? 'smartphone' : 'folder',
          color: f.isSystem || hidden ? cs.onSurface.withAlpha(160) : cs.primary,
          size: 28),
      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle,
          style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12)),
      trailing: _isPicker
          ? const ThemeIcon('caretRight', size: 16)
          : PopupMenuButton<String>(
              icon: ThemeIcon('dotsThreeVertical',
                  color: cs.onSurface.withAlpha(120), size: 20),
              // System ("Phone Backup") folders keep the conservative menu:
              // renaming/deleting the auto-sync tree has special semantics,
              // so only Hide is offered there.
              itemBuilder: (_) => [
                if (!f.isSystem) ...[
                  iconMenuItem(cs, 'rename', 'pencilSimple', 'Rename'),
                  iconMenuItem(cs, 'move', 'folderSimple', 'Move'),
                ],
                iconMenuItem(
                    cs,
                    'hide',
                    f.isHidden ? 'visibility' : 'visibility_off',
                    f.isHidden ? 'Unhide' : 'Hide from views'),
                if (!f.isSystem)
                  iconMenuItem(cs, 'delete', 'trash', 'Delete', danger: true),
              ],
              onSelected: (v) => switch (v) {
                'rename' => _renameFolder(f),
                'move' => _moveFolder(f),
                'hide' =>
                  DatabaseService().setFolderHidden(f.id, !f.isHidden),
                'delete' => _deleteFolder(f),
                _ => null,
              },
            ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          // Picker routes carry a name so 'Upload here' at any depth can
          // popUntil past the whole stack in one motion.
          settings: _isPicker
              ? const RouteSettings(name: kUploadPickerRouteName)
              : null,
          builder: (_) => FolderBrowserScreen(
              folder: f, pickerSession: widget.pickerSession))),
    );
  }

  // ---- File rows (Drive idiom: thumb/icon left, name + size · date) -----

  static const _videoExts = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'};

  bool _isMedia(CnestFile f) => f.type == CnestFileType.image;

  bool _isVideo(CnestFile f) {
    final dot = f.filename.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExts.contains(f.filename.substring(dot + 1).toLowerCase());
  }


  Widget _fileRow(ColorScheme cs, CnestFile file) {
    final isSelected = _selectedIds.contains(file.id);
    var subtitle =
        '${formatBytes(file.sizeBytes)} · ${DateFormat.yMMMd().format(file.createdAt)}';
    if (file.isHidden) subtitle = '$subtitle · Hidden from views';

    Widget leading;
    if (_isMedia(file)) {
      leading = ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            fit: StackFit.expand,
            children: [
              GalleryGridItem(
                  key: ValueKey('row_${file.id}'),
                  file: file,
                  decodeWidth: 96,
                  compact: true),
              if (_isVideo(file))
                const Center(
                    child: ThemeIcon('playCircle',
                        color: Colors.white, size: 18)),
            ],
          ),
        ),
      );
    } else if (file.thumbnailCloudId != null) {
      // PDFs (and audio with embedded art) carry a real encrypted thumb —
      // render it, Drive-style. Never GalleryGridItem here: its loader
      // would decrypt the WHOLE blob as a jpeg for non-media types.
      leading = DocThumbnail(
        key: ValueKey('doc_${file.id}'),
        file: file,
        width: 44,
        height: 44,
        borderRadius: BorderRadius.circular(6),
        iconSize: 26,
      );
    } else {
      final v = fileVisual(file.filename, ThemeController().tokens);
      leading = SizedBox(
        width: 44,
        height: 44,
        child: Center(
            child:
                ThemeIcon(v.icon, color: v.color.withAlpha(204), size: 26)),
      );
    }
    // Same dimmed cue hidden FOLDERS carry.
    if (file.isHidden) leading = Opacity(opacity: 0.55, child: leading);

    // Picker mode: files are context, not targets — visible (so the user
    // sees what already lives here) but inert and dimmed.
    if (_isPicker) {
      return Opacity(
        opacity: 0.45,
        child: ListTile(
          leading: leading,
          title: Text(file.filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14)),
          subtitle: Text(subtitle,
              style: TextStyle(
                  color: cs.onSurface.withAlpha(140), fontSize: 12)),
          enabled: false,
        ),
      );
    }

    return ListTile(
      leading: leading,
      title: Text(file.filename,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle,
          style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12)),
      trailing: _selectionMode
          ? ThemeIcon(isSelected ? 'checkCircle' : 'radio_button_unchecked',
              selected: isSelected,
              color: isSelected ? cs.primary : cs.onSurface.withAlpha(120),
              size: 22)
          : (_openingFileId == file.id
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: cs.onSurface))
              : PopupMenuButton<String>(
                  icon: ThemeIcon('dotsThreeVertical',
                      color: cs.onSurface.withAlpha(120), size: 20),
                  itemBuilder: (_) => [
                    iconMenuItem(cs, 'send', 'shareFat', 'Send file'),
                    iconMenuItem(cs, 'save', 'downloadSimple', 'Save to device'),
                    iconMenuItem(cs, 'rename', 'pencilSimple', 'Rename'),
                    iconMenuItem(cs, 'move', 'folderSimple', 'Move to folder'),
                    iconMenuItem(
                        cs,
                        'hide',
                        file.isHidden ? 'visibility' : 'visibility_off',
                        file.isHidden ? 'Unhide' : 'Hide from views'),
                    iconMenuItem(cs, 'delete', 'trash', 'Delete', danger: true),
                  ],
                  onSelected: (v) => switch (v) {
                    'send' => sendFilesPlain(context, [file]),
                    'save' => saveFileToDevice(context, file),
                    'rename' => promptRenameFile(context, file),
                    'move' => _moveOneFile(file),
                    'hide' =>
                      DatabaseService().setFileHidden(file.id, !file.isHidden),
                    'delete' => _deleteOneFile(file),
                    _ => null,
                  },
                )),
      onTap: () => _openFile(file),
      onLongPress: () {
        setState(() {
          _selectionMode = true;
          _selectedIds.add(file.id);
        });
        _updateSelectionClaim();
      },
    );
  }

  Future<void> _openFile(CnestFile file) async {
    if (_selectionMode) {
      _toggleSelected(file.id);
      return;
    }
    if (_isMedia(file)) {
      // The folder's own photos and videos, in the order shown here, so
      // the viewer swipes through this folder with its strip. A lone media
      // file keeps the single-file preview (nothing to swipe to).
      final media = _files.where(_isMedia).toList();
      final index = media.indexWhere((f) => f.id == file.id);
      if (media.length <= 1 || index < 0) {
        Navigator.of(context).push(photoViewerRoute(ImageViewerScreen(
            files: [file], initialIndex: 0, standalone: true)));
        return;
      }
      Navigator.of(context).push(photoViewerRoute(
          ImageViewerScreen(files: media, initialIndex: index)));
      return;
    }
    if (file.type == CnestFileType.audio) {
      // Single-track queue — "you're viewing one file", same model as the
      // media preview. The full library queue lives in the Music tab.
      try {
        await AudioPlayerService().playQueue([file],
            startIndex: 0, sourceName: widget.folder?.name ?? 'Folders');
      } catch (e) {
        Notify.error('Could not play: $e');
      }
      return;
    }
    // PDFs, text/Markdown, and images render in the in-app read-only viewer
    // (in-memory, no disk). Everything else decrypts to the app-private temp
    // dir and hands off to the system viewer.
    if (canViewInApp(file.filename)) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => DocumentViewerScreen(file: file)));
      return;
    }
    if (_openingFileId != null) return;
    setState(() => _openingFileId = file.id);
    try {
      // A prior-key file (adopted after a start-over) can never decrypt
      // under this vault's phrase — say so instead of trying and dying.
      if (await DatabaseService().isPriorKeyFile(file.id)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
        return;
      }
      final dir = await getTemporaryDirectory();
      final tempFile = File('${dir.path}/${safeFilename(file.filename)}');
      if (!await tempFile.exists()) {
        if (file.cloudId == null) throw Exception('File not synced');
        final encrypted = await CloudService().downloadFile(file.cloudId!);
        final decrypted = await EncryptionService.decryptFile(encrypted);
        await tempFile.writeAsBytes(decrypted);
      }
      final result = await OpenFile.open(tempFile.path);
      if (result.type != ResultType.done) throw Exception(result.message);
    } catch (e) {
      // Wrong-key MAC failure (prior-key leftover) gets plain language,
      // never the raw crypto exception.
      if (isCryptoAuthFailure(e)) {
        if (mounted) await showCnestError(context, const PriorKeyFileError());
      } else {
        Notify.error('Could not open file: $e');
      }
    } finally {
      if (mounted) setState(() => _openingFileId = null);
    }
  }
}
