import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../services/database_service.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../../utils/byte_format.dart';
import '../../widgets/folder_picker_sheet.dart';
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
    // showing a ghost.
    if (_folderId != null) {
      final self = await DatabaseService().getFolderPathSegments(_folderId!);
      if (!mounted) return;
      if (self.isEmpty || self.last.isDeleted) {
        Navigator.of(context).pop();
        return;
      }
    }
    setState(() {
      _folders = folders;
      _files = files;
      _counts = counts;
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
                'delete' => _deleteCurrent(),
                _ => null,
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'move', child: Text('Move')),
                PopupMenuItem(value: 'delete', child: Text('Delete')),
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
                  ? 'No folders yet.\nTap + to create one, then move files '
                      'in from any tab\'s selection mode.'
                  : 'This folder is empty.\nMove files here from any tab\'s '
                      'selection mode.',
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
    return ListTile(
      leading: ThemeIcon(f.isSystem ? 'smartphone' : 'folder',
          color: f.isSystem ? cs.onSurface.withAlpha(160) : cs.primary,
          size: 28),
      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
          f.isSystem ? 'Auto-synced media · $countLabel' : countLabel,
          style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12)),
      trailing: const ThemeIcon('caretRight', size: 16),
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
          : null,
      onTap: () => _openFile(file),
      onLongPress: () => setState(() {
        _selectionMode = true;
        _selectedIds.add(file.id);
      }),
    );
  }

  void _openFile(CnestFile file) {
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
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"${file.filename}" opens from its category tab')));
    }
  }
}
