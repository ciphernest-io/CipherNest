import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../../services/sync_service.dart';
import '../../config/theme_controller.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../widgets/activity_pill.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/theme_icon.dart';
import '../share/share_dialog.dart';
import 'audio_details_screen.dart';
import 'playlist_detail_screen.dart';
import 'playlist_picker_sheet.dart';
import 'widgets/music_widgets.dart';

/// The music library, Samsung Music-style: Favourites / Playlists / Tracks
/// tabs over the vault's audio, with the persistent mini player docked at
/// the bottom. Playback itself lives in [AudioPlayerService] and keeps
/// going wherever the user navigates.
class MusicHomeScreen extends StatefulWidget {
  const MusicHomeScreen({super.key});

  @override
  State<MusicHomeScreen> createState() => _MusicHomeScreenState();
}

class _MusicHomeScreenState extends State<MusicHomeScreen> {
  late Future<List<CnestFile>> _tracksFuture;
  late Future<List<CnestAlbum>> _playlistsFuture;
  final ScrollController _tracksController = ScrollController();

  // TrackRow: 48px art + 2×8 vertical padding.
  static const double _rowHeight = 64.0;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onDataChanged);
    DatabaseService().addListener(_onDataChanged);
    AudioPlayerService().addListener(_syncPillInset);
    _syncPillInset();
    _refresh();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onDataChanged);
    DatabaseService().removeListener(_onDataChanged);
    AudioPlayerService().removeListener(_syncPillInset);
    _pillInset?.release();
    _tracksController.dispose();
    super.dispose();
  }

  // The MiniPlayerBar occupies the bottom band only while a queue exists —
  // the global activity pill claims clearance to match.
  InsetClaim? _pillInset;
  void _syncPillInset() {
    final hasPlayer = AudioPlayerService().current != null;
    if (hasPlayer && _pillInset == null) {
      _pillInset = ActivityPillInset.claim(68);
    } else if (!hasPlayer) {
      _pillInset?.release();
      _pillInset = null;
    }
  }

  void _onDataChanged() {
    if (mounted) _refresh();
  }

  void _refresh() {
    setState(() {
      _tracksFuture = DatabaseService()
          .getFilesByType(CnestFileType.audio)
          .then((files) => files
            ..sort((a, b) => AudioPlayerService.displayTitle(a)
                .toLowerCase()
                .compareTo(AudioPlayerService.displayTitle(b).toLowerCase())));
      _playlistsFuture = DatabaseService().getPlaylists();
    });
  }

  Future<void> _handleSync() => SyncService().syncNow(force: true);

  Future<void> _createPlaylist() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await DatabaseService().createPlaylist(name);
    _refresh();
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
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await AudioPlayerService().ejectFile(file.id);
    await DatabaseService().deleteFile(file.id);
    AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
    DatabaseBackupService().scheduleBackup();
    // Audio plaintext cache uses its own naming — wipe it here.
    final tempDir = await getTemporaryDirectory();
    final cached = File('${tempDir.path}/${file.id}_audio.bin');
    if (await cached.exists()) await cached.delete();
    _refresh();
  }

  List<PopupMenuEntry<String>> _trackMenu(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return [
      const PopupMenuItem(value: 'playlist', child: Text('Add to playlist')),
      const PopupMenuItem(value: 'send', child: Text('Send file')),
      const PopupMenuItem(value: 'share', child: Text('Share secure link')),
      const PopupMenuItem(value: 'save', child: Text('Save to device')),
      const PopupMenuItem(value: 'rename', child: Text('Rename')),
      const PopupMenuItem(value: 'details', child: Text('Details')),
      PopupMenuItem(
        value: 'delete',
        child: Text('Delete', style: TextStyle(color: cs.error)),
      ),
    ];
  }

  void _onTrackMenu(String action, CnestFile file) {
    switch (action) {
      case 'playlist':
        PlaylistPickerSheet.show(context, file);
      case 'send':
        sendFilesPlain(context, [file]);
      case 'share':
        ShareDialog.show(context, file);
      case 'save':
        saveFileToDevice(context, file);
      case 'rename':
        promptRenameFile(context, file, onRenamed: (_) => _refresh());
      case 'details':
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AudioDetailsScreen(file: file)),
        );
      case 'delete':
        _handleDelete(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Music'),
          actions: [
            IconButton(
              icon: const ThemeIcon('plus'),
              onPressed: _createPlaylist,
            ),
            IconButton(
              icon: const ThemeIcon('arrowsClockwise'),
              onPressed: _handleSync,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Favourites'),
              Tab(text: 'Playlists'),
              Tab(text: 'Tracks'),
            ],
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: TabBarView(
                children: [
                  _buildFavourites(),
                  _buildPlaylists(),
                  _buildTracks(),
                ],
              ),
            ),
            const MiniPlayerBar(),
          ],
        ),
      ),
    );
  }

  // --- Tabs ---

  Widget _buildEmpty(String message) {
    final cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 180),
        Center(
          child: Column(
            children: [
              ThemeIcon('musicNotes',
                  size: 64, color: cs.onSurface.withAlpha(80)),
              const SizedBox(height: 16),
              Text(message,
                  style: TextStyle(color: cs.onSurface.withAlpha(120))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTrackList(
    List<CnestFile> files, {
    required String sourceName,
    ScrollController? controller,
  }) {
    return ListView.builder(
      controller: controller,
      physics: const AlwaysScrollableScrollPhysics(),
      itemExtent: _rowHeight,
      padding: EdgeInsets.zero,
      itemCount: files.length,
      itemBuilder: (context, index) => TrackRow(
        file: files[index],
        onTap: () async {
          try {
            await AudioPlayerService().playQueue(
              files,
              startIndex: index,
              sourceName: sourceName,
            );
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not play: $e'),
                backgroundColor: ThemeController().tokens.danger,
              ),
            );
          }
        },
        menuBuilder: _trackMenu,
        onMenuSelected: (v) => _onTrackMenu(v, files[index]),
      ),
    );
  }

  Widget _buildFavourites() {
    return RefreshIndicator(
      onRefresh: _handleSync,
      child: FutureBuilder<List<CnestFile>>(
        future: _tracksFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final favs = snap.data!.where((f) => f.isFavorite).toList();
          if (favs.isEmpty) {
            return _buildEmpty('No favourite tracks yet');
          }
          return _buildTrackList(favs, sourceName: 'Favourites');
        },
      ),
    );
  }

  Widget _buildTracks() {
    return RefreshIndicator(
      onRefresh: _handleSync,
      child: FutureBuilder<List<CnestFile>>(
        future: _tracksFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final files = snap.data!;
          if (files.isEmpty) {
            return _buildEmpty('No audio files yet');
          }
          return Stack(
            children: [
              Positioned.fill(
                right: 26,
                child: _buildTrackList(
                  files,
                  sourceName: 'Tracks',
                  controller: _tracksController,
                ),
              ),
              Positioned(
                right: 2,
                top: 0,
                bottom: 0,
                child: _AlphabetRail(
                  files: files,
                  onJump: (index) {
                    _tracksController.jumpTo(
                      (index * _rowHeight).clamp(
                        0.0,
                        _tracksController.position.maxScrollExtent,
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlaylists() {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return RefreshIndicator(
      onRefresh: _handleSync,
      child: FutureBuilder<List<CnestAlbum>>(
        future: _playlistsFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final playlists = snap.data!;
          return GridView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 16,
              crossAxisSpacing: 16,
              childAspectRatio: 0.82,
            ),
            itemCount: playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlists[index];
              return GestureDetector(
                onTap: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PlaylistDetailScreen(playlist: playlist),
                    ),
                  );
                  _refresh();
                },
                onLongPress: playlist.isSmart
                    ? null
                    : () => _showPlaylistActions(playlist),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(t.rCardLg),
                        ),
                        child: Center(
                          child: ThemeIcon(
                            'musicNote',
                            size: 56,
                            color: cs.onSurface.withAlpha(170),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${playlist.fileCount} tracks',
                      style: TextStyle(
                        color: cs.onSurface.withAlpha(120),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showPlaylistActions(CnestAlbum playlist) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const ThemeIcon('pencilSimple'),
              title: const Text('Rename'),
              onTap: () async {
                Navigator.pop(ctx);
                final controller = TextEditingController(text: playlist.name);
                final name = await showDialog<String>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    title: const Text('Rename playlist'),
                    content: TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dctx),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () =>
                            Navigator.pop(dctx, controller.text.trim()),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                );
                if (name == null || name.isEmpty) return;
                await DatabaseService().renameAlbum(playlist.id, name);
                _refresh();
              },
            ),
            ListTile(
              leading: ThemeIcon('trash', color: cs.error),
              title: Text('Delete playlist',
                  style: TextStyle(color: cs.error)),
              subtitle: const Text('Tracks stay in your vault'),
              onTap: () async {
                Navigator.pop(ctx);
                await DatabaseService().deleteAlbum(playlist.id);
                _refresh();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Samsung's fast-scroll rail: the alphabet down the right edge; tap or drag
/// to jump the track list to the first title at that letter.
class _AlphabetRail extends StatelessWidget {
  final List<CnestFile> files;
  final ValueChanged<int> onJump;
  const _AlphabetRail({required this.files, required this.onJump});

  static const _letters = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#',
  ];

  void _jumpToLetter(String letter) {
    // First track whose title starts at/after the letter; '#' = first
    // non-alphabetic title (they sort before 'A'... digits do — so '#'
    // jumps to the very top of the non-letter block, i.e. index 0).
    if (letter == '#') {
      onJump(0);
      return;
    }
    for (var i = 0; i < files.length; i++) {
      final first = AudioPlayerService.displayTitle(files[i])
          .trimLeft()
          .toUpperCase();
      if (first.isEmpty) continue;
      if (first.codeUnitAt(0) >= letter.codeUnitAt(0)) {
        onJump(i);
        return;
      }
    }
    onJump(files.length - 1);
  }

  void _handleDrag(BuildContext context, Offset localPosition) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final fraction = (localPosition.dy / box.size.height).clamp(0.0, 0.999);
    _jumpToLetter(_letters[(fraction * _letters.length).floor()]);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _handleDrag(context, d.localPosition),
      onVerticalDragUpdate: (d) => _handleDrag(context, d.localPosition),
      child: Container(
        width: 22,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final letter in _letters)
              Text(
                letter,
                style: TextStyle(
                  color: cs.onSurface.withAlpha(120),
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
