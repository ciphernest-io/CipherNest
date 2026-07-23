import 'package:flutter/material.dart';

import '../../../services/database_service.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../../widgets/folder_picker_sheet.dart';
import '../../widgets/theme_icon.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;

/// The virtual folder tree, browsed one level at a time (Samsung "My
/// Files" idiom): subfolder rows on top, a mixed-type file grid below.
/// Navigating into a folder pushes another instance of this screen.
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

    return CustomScrollView(
      slivers: [
        if (_folders.isNotEmpty)
          SliverList.builder(
            itemCount: _folders.length,
            itemBuilder: (context, i) {
              final f = _folders[i];
              final n = _counts[f.id] ?? 0;
              return ListTile(
                leading: ThemeIcon('folder', color: cs.primary, size: 28),
                title: Text(f.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('$n item${n == 1 ? '' : 's'}',
                    style: TextStyle(
                        color: cs.onSurface.withAlpha(140), fontSize: 12)),
                trailing: const ThemeIcon('caretRight', size: 16),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => FolderBrowserScreen(folder: f))),
              );
            },
          ),
        if (_folders.isNotEmpty && _files.isNotEmpty)
          const SliverToBoxAdapter(child: Divider(height: 1)),
        if (_files.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.only(top: 1.5),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 1.5,
                mainAxisSpacing: 1.5,
              ),
              itemCount: _files.length,
              itemBuilder: (context, i) {
                final file = _files[i];
                final isSelected = _selectedIds.contains(file.id);
                return GestureDetector(
                  onTap: () {
                    if (_selectionMode) {
                      _toggleSelected(file.id);
                      return;
                    }
                    if (file.type == CnestFileType.image) {
                      final images = _files
                          .where((f) => f.type == CnestFileType.image)
                          .toList();
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => ImageViewerScreen(
                              files: images,
                              initialIndex: images.indexOf(file))));
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(
                              '"${file.filename}" opens from its category '
                              'tab')));
                    }
                  },
                  onLongPress: () => setState(() {
                    _selectionMode = true;
                    _selectedIds.add(file.id);
                  }),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      GalleryGridItem(key: ValueKey(file.id), file: file),
                      if (_selectionMode)
                        Container(
                          color: isSelected
                              ? Colors.black45
                              : Colors.transparent,
                          child: Align(
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
                    ],
                  ),
                );
              },
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}
