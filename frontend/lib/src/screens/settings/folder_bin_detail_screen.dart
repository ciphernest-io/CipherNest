import 'package:flutter/material.dart';

import '../../../services/database_service.dart';
import '../../../services/notify.dart';
import '../../../services/recycle_bin_service.dart';
import '../../models/file_model.dart';
import '../../models/folder_model.dart';
import '../../widgets/theme_icon.dart';
import '../gallery/image_viewer_screen.dart';
import '../gallery/pictures_tab.dart' show GalleryGridItem;
import 'recycle_bin_screen.dart'
    show
        FolderPathText,
        confirmRestoreFolder,
        confirmPurgeFolder,
        restoreFileToSafePlace;

/// Read-only look inside a deleted folder before deciding its fate:
/// cascade-binned subfolders as rows, cascade-binned files as a grid.
/// Restore-the-folder is the primary action; individual files can also be
/// restored one at a time (they surface at the vault root until the folder
/// itself is restored, then rejoin it — the sheet copy says so).
class FolderBinDetailScreen extends StatefulWidget {
  final CnestFolder folder;
  const FolderBinDetailScreen({super.key, required this.folder});

  @override
  State<FolderBinDetailScreen> createState() =>
      _FolderBinDetailScreenState();
}

class _FolderBinDetailScreenState extends State<FolderBinDetailScreen> {
  List<CnestFolder> _subfolders = [];
  List<CnestFile> _files = [];
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
    final subfolders =
        await DatabaseService().getCascadeBinnedFolders(widget.folder.id);
    final files =
        await DatabaseService().getCascadeBinnedFiles(widget.folder.id);
    if (!mounted) return;
    // Restored or purged elsewhere while open — nothing left to inspect.
    if (subfolders.isEmpty && files.isEmpty && !_loading) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _subfolders = subfolders;
      _files = files;
      _loading = false;
    });
  }

  Future<void> _restoreFolder() async {
    if (!await confirmRestoreFolder(context, widget.folder)) return;
    await DatabaseService().restoreFolder(widget.folder.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _purgeFolder() async {
    if (!await confirmPurgeFolder(context, widget.folder, _files.length)) {
      return;
    }
    await RecycleBinService().purgeFolderPermanently(widget.folder.id);
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _restoreSingleFile(CnestFile file) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restore "${file.filename}"?'),
        content: const Text(
            'The file returns to your vault in a "Restored" folder (its '
            'original folder is in the Recycle Bin). Move it anywhere you '
            'like from there.'),
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
    if (ok != true) return;
    await restoreFileToSafePlace(file);
    Notify.info('"${file.filename}" restored to "Restored"');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.folder.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Restore folder',
            icon: const ThemeIcon('arrowCounterClockwise'),
            onPressed: _restoreFolder,
          ),
          IconButton(
            tooltip: 'Delete forever',
            icon: ThemeIcon('trashSimple', color: cs.error),
            onPressed: _purgeFolder,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FolderPathText(
                            folderId: widget.folder.parentId,
                            fontSize: 13),
                        const SizedBox(height: 4),
                        Text(
                          'Deleted folder — contents are read-only until '
                          'restored.',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(140),
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_subfolders.isNotEmpty)
                  SliverList.builder(
                    itemCount: _subfolders.length,
                    itemBuilder: (context, i) {
                      final f = _subfolders[i];
                      return ListTile(
                        leading: ThemeIcon('folder',
                            color: cs.onSurface.withAlpha(140), size: 26),
                        title: Text(f.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: FolderPathText(folderId: f.parentId),
                      );
                    },
                  ),
                if (_files.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 8),
                    sliver: SliverGrid.builder(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 1.5,
                        mainAxisSpacing: 1.5,
                      ),
                      itemCount: _files.length,
                      itemBuilder: (context, i) {
                        final file = _files[i];
                        return GestureDetector(
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => ImageViewerScreen(
                                      files: _files,
                                      initialIndex: i,
                                      fromRecycleBin: true))),
                          onLongPress: () => _restoreSingleFile(file),
                          child: GalleryGridItem(
                              key: ValueKey(file.id), file: file),
                        );
                      },
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            ),
    );
  }
}
