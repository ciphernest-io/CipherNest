import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
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

class AlbumsTab extends StatefulWidget {
  const AlbumsTab({super.key});

  @override
  State<AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends State<AlbumsTab> {
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
  }

  @override
  void dispose() {
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

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: [
        if (_deviceAlbums.isNotEmpty) ...[
          _sectionHeader('On this phone', cs),
          _grid([
            for (final album in _deviceAlbums)
              _AlbumCard(album: album, onTap: () => _openAlbum(album)),
          ]),
        ],
        _sectionHeader('My albums', cs,
            // Honesty label (deliberate): curated albums are device-local
            // in an app whose headline feature is sync — say so instead of
            // letting it read as a bug. Folders sync; albums don't (yet).
            subtitle: 'On this device — albums don\'t sync yet'),
        _grid([
          for (final album in _albums)
            _AlbumCard(album: album, onTap: () => _openAlbum(album)),
          _buildCreateCard(),
        ]),
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
    return GridView.count(
      crossAxisCount: 2,
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
    return GestureDetector(
      onTap: widget.onTap,
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
              child: _coverBytes != null
                  ? Image.memory(_coverBytes!, fit: BoxFit.cover)
                  : Container(
                      color: cs.surfaceContainerHighest,
                      child: ThemeIcon(
                        widget.album.isSmart
                            ? _smartAlbumIcon(widget.album.smartQuery)
                            : 'folderSimple',
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
