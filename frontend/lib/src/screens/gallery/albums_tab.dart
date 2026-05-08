import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../../config/routes.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';

class AlbumsTab extends StatefulWidget {
  const AlbumsTab({super.key});

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab> {
  List<CnestAlbum> _albums = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    DatabaseService().getAlbums().then((albums) {
      if (mounted) setState(() { _albums = albums; _loading = false; });
    });
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

    if (_albums.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(PhosphorIcons.folderSimple(PhosphorIconsStyle.thin), size: 64, color: cs.onSurface.withAlpha(120)),
            const SizedBox(height: 16),
            Text('No albums yet',
                style: TextStyle(color: cs.onSurface.withAlpha(120))),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _createAlbum,
              icon: Icon(PhosphorIcons.plus(PhosphorIconsStyle.thin)),
              label: const Text('Create Album'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary),
            ),
          ],
        ),
      );
    }

    // +1 for the "Create Album" card at the end
    final itemCount = _albums.length + 1;

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
        childAspectRatio: 0.85,
      ),
      itemCount: itemCount,
      itemBuilder: (context, index) {
        if (index == _albums.length) return _buildCreateCard();
        return _AlbumCard(
          album: _albums[index],
          onTap: () async {
            await Navigator.pushNamed(
              context,
              AppRoutes.albumDetail,
              arguments: _albums[index],
            );
            _reload();
          },
        );
      },
    );
  }

  Widget _buildCreateCard() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: _createAlbum,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outline),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(PhosphorIcons.plus(PhosphorIconsStyle.thin), color: cs.onSurface.withAlpha(140), size: 40),
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

  const _AlbumCard({required this.album, required this.onTap});

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

  Future<void> _loadCover() async {
    final coverFile =
        await DatabaseService().getAlbumCoverFile(widget.album);
    if (coverFile == null) return;

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
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _coverBytes != null
                  ? Image.memory(_coverBytes!, fit: BoxFit.cover)
                  : Container(
                      color: cs.surfaceContainerHighest,
                      child: Icon(
                        widget.album.isSmart
                            ? _smartAlbumIcon(widget.album.smartQuery)
                            : PhosphorIcons.folderSimple(PhosphorIconsStyle.thin),
                        color: cs.onSurface.withAlpha(60),
                        size: 40,
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
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
                      style:
                          TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _smartAlbumIcon(String? query) {
    switch (query) {
      case 'all_images':
        return PhosphorIcons.images(PhosphorIconsStyle.thin);
      case 'camera':
        return PhosphorIcons.camera(PhosphorIconsStyle.thin);
      case 'screenshots':
        return PhosphorIcons.screencast(PhosphorIconsStyle.thin);
      case 'videos':
        return PhosphorIcons.videoCamera(PhosphorIconsStyle.thin);
      default:
        return PhosphorIcons.folderSimple(PhosphorIconsStyle.thin);
    }
  }
}
