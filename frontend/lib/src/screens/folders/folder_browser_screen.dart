import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/saf_folder_import.dart';
import '../../../services/upload_foreground_guard.dart';
import '../../../services/upload_pipeline.dart';
import '../../config/theme_controller.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../../utils/byte_format.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/folder_picker_sheet.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/theme_icon.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;

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
  const FolderBrowserScreen({super.key, this.folder});

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
  int _uploadDone = 0;
  int _uploadTotal = 0;
  String? _openingFileId;

  /// Fresh row for the folder being viewed (widget.folder goes stale the
  /// moment a rename/hide lands elsewhere). Null at root.
  CnestFolder? _self;

  String? get _folderId => widget.folder?.id;

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
    final folders = await DatabaseService().getFolders(parentId: _folderId);
    final files = await DatabaseService().getFilesInFolder(_folderId);
    final counts = await DatabaseService().getFolderFileCounts();
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
      _loading = false;
    });
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('A folder named "$name" already exists here')));
      }
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

  Future<void> _renameCurrent() async {
    final folder = widget.folder!;
    final name =
        await _promptForName(title: 'Rename folder', initial: folder.name);
    if (name == null || name.isEmpty || name == folder.name) return;
    await DatabaseService().renameFolder(folder.id, name);
  }

  Future<void> _moveCurrent() async {
    final folder = widget.folder!;
    final pick = await showFolderPicker(context,
        title: 'Move "${folder.name}" to', excludeSubtreeOf: folder.id);
    if (pick == null) return;
    final moved = await DatabaseService().moveFolder(folder.id, pick.folderId);
    if (!moved && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A folder can\'t be moved into itself')));
    }
  }

  Future<void> _deleteCurrent() async {
    final folder = widget.folder!;
    final directCount = _counts[folder.id] ?? 0;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${folder.name}"?'),
        content: Text(
            'The folder and everything inside it move to the Recycle Bin '
            'as one entry${directCount > 0 ? ' ($directCount item'
                '${directCount == 1 ? '' : 's'} here)' : ''}. '
            'You can restore it for 30 days.'),
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
    if (mounted) Navigator.of(context).pop();
  }

  // ---- File selection ---------------------------------------------------

  void _toggleSelected(String id) {
    setState(() {
      if (!_selectedIds.remove(id)) _selectedIds.add(id);
      if (_selectedIds.isEmpty) _selectionMode = false;
    });
  }

  Future<void> _moveOneFile(CnestFile file) async {
    final pick = await showFolderPicker(context);
    if (pick == null) return;
    await DatabaseService().moveFileToFolder(file.id, pick.folderId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Moved to "${pick.label}"')));
  }

  Future<void> _moveSelectedFiles() async {
    final pick = await showFolderPicker(context);
    if (pick == null) return;
    final ids = List<String>.from(_selectedIds);
    for (final id in ids) {
      await DatabaseService().moveFileToFolder(id, pick.folderId);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${ids.length} moved to "${pick.label}"')));
    setState(() {
      _selectionMode = false;
      _selectedIds.clear();
    });
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = widget.folder?.name ?? 'Folders';

    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'New folder',
            icon: const ThemeIcon('plus'),
            onPressed: _createFolder,
          ),
          if (widget.folder != null)
            PopupMenuButton<String>(
              icon: const ThemeIcon('dotsThreeVertical'),
              onSelected: (v) => switch (v) {
                'rename' => _renameCurrent(),
                'move' => _moveCurrent(),
                'hide' => DatabaseService().setFolderHidden(
                    _folderId!, !((_self ?? widget.folder!).isHidden)),
                'delete' => _deleteCurrent(),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                const PopupMenuItem(value: 'move', child: Text('Move')),
                PopupMenuItem(
                    value: 'hide',
                    child: Text((_self ?? widget.folder!).isHidden
                        ? 'Unhide'
                        : 'Hide from Photos & other views')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_selectionMode) _buildSelectionBar(),
                Expanded(child: _buildBody(cs)),
              ],
            ),
      floatingActionButton: _selectionMode
          ? null
          : FloatingActionButton.extended(
              onPressed: _isUploading ? null : _showBrowserUploadSheet,
              backgroundColor: cs.primary,
              icon: _isUploading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: cs.onPrimary, strokeWidth: 2))
                  : ThemeIcon('uploadSimple', color: cs.onPrimary),
              label: Text(_isUploading
                  ? (_uploadTotal > 1
                      ? 'Encrypting ${(_uploadDone + 1).clamp(1, _uploadTotal)}'
                          '/$_uploadTotal...'
                      : 'Encrypting...')
                  : 'Upload'),
            ),
    );
  }

  void _showBrowserUploadSheet() {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
    try {
      tree = await SafFolderImport.pickTree();
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Couldn\'t read that folder — try "Upload files" instead.')));
      return;
    }
    if (tree == null || !mounted) return; // cancelled
    final picked = tree;
    if (picked.entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That folder has no files.')));
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadDone = 0;
      _uploadTotal = picked.entries.length;
    });
    // One foreground pin across the whole import — the per-batch pins nest
    // inside it (ref-counted), so the notification doesn't flap between
    // files.
    final guard = UploadForegroundGuard();
    await guard.begin();
    var secured = 0, failed = 0;
    String rootName = picked.name;
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
          );
          for (final o in res) {
            if (o.ok) {
              secured++;
            } else {
              failed++;
            }
          }
        }
        if (mounted) setState(() => _uploadDone = i + 1);
      }

      if (!mounted) return;
      final parts = <String>[];
      if (secured > 0) parts.add('$secured file${secured == 1 ? '' : 's'}');
      if (failed > 0) parts.add('$failed failed');
      // No silent caps: a truncated walk is said out loud.
      if (picked.truncated) parts.add('first 2000 files only');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported "$rootName": ${parts.join(' · ')}')));
    } catch (e) {
      if (mounted) {
        await showCnestError(context, UploadPipeline.mapUploadError(e));
      }
    } finally {
      await guard.end();
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

    setState(() {
      _isUploading = true;
      _uploadDone = 0;
      _uploadTotal = result.files.length;
    });
    try {
      final outcomes = await UploadPipeline.uploadBatch(
        result.files,
        category: UploadCategory.other,
        folderId: _folderId,
        onProgress: (done, total) {
          if (mounted) setState(() => _uploadDone = done);
        },
      );
      if (mounted) await _reportUploadOutcomes(outcomes);
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> _reportUploadOutcomes(List<UploadOutcome> outcomes) async {
    final uploaded =
        outcomes.where((o) => o.ok && !o.skippedDuplicate).length;
    final dups = outcomes.where((o) => o.skippedDuplicate).length;
    final failures = outcomes.where((o) => !o.ok).toList();

    final parts = <String>[];
    if (uploaded > 0) {
      parts.add('$uploaded file${uploaded == 1 ? '' : 's'} secured here');
    }
    if (dups > 0) parts.add('$dups already in your vault');
    if (failures.isNotEmpty) parts.add('${failures.length} failed');
    if (parts.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(parts.join(' · '))));
    }
    if (failures.isNotEmpty && mounted) {
      await showCnestError(
          context, UploadPipeline.mapUploadError(failures.first.error!));
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
              onPressed: () => setState(() {
                _selectionMode = false;
                _selectedIds.clear();
              }),
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

    // System folders ("Phone Backup" tree) sit BELOW user folders as one
    // unobtrusive row each — the auto-sync machinery must not clutter the
    // root's user-created organization.
    final userFolders = _folders.where((f) => !f.isSystem).toList();
    final systemFolders = _folders.where((f) => f.isSystem).toList();

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
        if (_folders.isNotEmpty && _files.isNotEmpty)
          const SliverToBoxAdapter(child: Divider(height: 1)),
        if (_files.isNotEmpty)
          SliverList.builder(
            itemCount: _files.length,
            itemBuilder: (context, i) => _fileRow(cs, _files[i]),
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
      trailing: PopupMenuButton<String>(
        icon: ThemeIcon('dotsThreeVertical',
            color: cs.onSurface.withAlpha(120), size: 20),
        itemBuilder: (_) => [
          PopupMenuItem(
              value: 'hide',
              child: Text(f.isHidden
                  ? 'Unhide'
                  : 'Hide from Photos & other views')),
        ],
        onSelected: (v) => switch (v) {
          'hide' => DatabaseService().setFolderHidden(f.id, !f.isHidden),
          _ => null,
        },
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => FolderBrowserScreen(folder: f))),
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

  String _typeIcon(CnestFile f) => switch (f.type) {
        CnestFileType.audio => 'musicNote',
        CnestFileType.document => 'fileText',
        _ => 'file',
      };

  Widget _fileRow(ColorScheme cs, CnestFile file) {
    final isSelected = _selectedIds.contains(file.id);
    final subtitle =
        '${formatBytes(file.sizeBytes)} · ${DateFormat.yMMMd().format(file.createdAt)}';

    final Widget leading;
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
    } else {
      leading = SizedBox(
        width: 44,
        height: 44,
        child: Center(
            child: ThemeIcon(_typeIcon(file), color: cs.primary, size: 26)),
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
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'send', child: Text('Send file')),
                    PopupMenuItem(
                        value: 'save', child: Text('Save to device')),
                    PopupMenuItem(value: 'rename', child: Text('Rename')),
                    PopupMenuItem(
                        value: 'move', child: Text('Move to folder')),
                  ],
                  onSelected: (v) => switch (v) {
                    'send' => sendFilesPlain(context, [file]),
                    'save' => saveFileToDevice(context, file),
                    'rename' => promptRenameFile(context, file),
                    'move' => _moveOneFile(file),
                    _ => null,
                  },
                )),
      onTap: () => _openFile(file),
      onLongPress: () => setState(() {
        _selectionMode = true;
        _selectedIds.add(file.id);
      }),
    );
  }

  Future<void> _openFile(CnestFile file) async {
    if (_selectionMode) {
      _toggleSelected(file.id);
      return;
    }
    if (_isMedia(file)) {
      // Drive-style preview: THIS file, full-screen, in place. Back
      // returns here. No filmstrip, no swiping a timeline — that lives in
      // the Photos & Videos tab.
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ImageViewerScreen(
              files: [file], initialIndex: 0, standalone: true)));
      return;
    }
    if (file.type == CnestFileType.audio) {
      // Single-track queue — "you're viewing one file", same model as the
      // media preview. The full library queue lives in the Music tab.
      try {
        await AudioPlayerService().playQueue([file],
            startIndex: 0, sourceName: widget.folder?.name ?? 'Folders');
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not play: $e'),
            backgroundColor: ThemeController().tokens.danger));
      }
      return;
    }
    // Documents / other: decrypt to the app-private temp dir and hand off
    // to the system viewer — the same secure-open pattern as the category
    // tabs (plaintext never touches public storage).
    if (_openingFileId != null) return;
    setState(() => _openingFileId = file.id);
    try {
      final dir = await getTemporaryDirectory();
      final tempFile = File('${dir.path}/${file.filename}');
      if (!await tempFile.exists()) {
        if (file.cloudId == null) throw Exception('File not synced');
        final encrypted = await CloudService().downloadFile(file.cloudId!);
        final decrypted = await EncryptionService.decryptFile(encrypted);
        await tempFile.writeAsBytes(decrypted);
      }
      final result = await OpenFile.open(tempFile.path);
      if (result.type != ResultType.done) throw Exception(result.message);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not open file: $e'),
            backgroundColor: ThemeController().tokens.danger));
      }
    } finally {
      if (mounted) setState(() => _openingFileId = null);
    }
  }
}
