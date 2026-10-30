import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/cover_art_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../../services/notify.dart';
import '../../../services/sync_service.dart';
import '../../config/app_info.dart';
import '../../config/routes.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../widgets/activity_pill.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/friendly_error_sheet.dart';
import '../../widgets/theme_icon.dart';
import '../share/share_dialog.dart';
import 'audio_details_screen.dart';
import 'playlist_detail_screen.dart';
import 'playlist_picker_sheet.dart';
import 'playlists_morph.dart';
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

class _MusicHomeScreenState extends State<MusicHomeScreen>
    with SingleTickerProviderStateMixin {
  late Future<List<CnestFile>> _tracksFuture;
  late Future<List<CnestAlbum>> _playlistsFuture;
  final ScrollController _tracksController = ScrollController();

  // Own the controller (not DefaultTabController) so the AppBar can react to
  // the active tab: the + only belongs on Playlists, and search scopes to the
  // tab you're on.
  late final TabController _tabController =
      TabController(length: 3, vsync: this, initialIndex: 2);

  bool _searching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  // Bottom room the lists reserve so their last item clears the floating,
  // translucent mini player (0 when nothing is playing). Recomputed in build.
  double _barSpace = 0;

  // True while a gesture inside a tab must own the screen — dragging the
  // alphabet rail, or pinch-zooming the Playlists grid — so tab-swiping is
  // frozen and the gesture never flips to another tab.
  bool _freezeTabs = false;

  // TrackRow: 48px art + 2×8 vertical padding.
  static const double _rowHeight = 64.0;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onDataChanged);
    DatabaseService().addListener(_onDataChanged);
    // Rebuild the AppBar actions (the +) as the tab changes.
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    // AppBar carries a TabBar — the top-anchored activity pill drops below.
    _pillInset = ActivityPillInset.claim(kTextTabBarHeight);
    _refresh();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onDataChanged);
    DatabaseService().removeListener(_onDataChanged);
    _pillInset.release();
    _tabController.dispose();
    _searchCtrl.dispose();
    _tracksController.dispose();
    super.dispose();
  }

  late final InsetClaim _pillInset;

  bool _matchesQuery(String text) =>
      _query.isEmpty || text.toLowerCase().contains(_query.toLowerCase());

  void _closeSearch() {
    setState(() {
      if (_query.isNotEmpty) {
        _query = '';
        _searchCtrl.clear();
      } else {
        _searching = false;
      }
    });
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
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search music',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : const Text('Music'),
        actions: _searching
            ? [
                IconButton(
                  icon: const ThemeIcon('x'),
                  onPressed: _closeSearch,
                ),
              ]
            : [
                // The + adds a playlist, so it only belongs on the Playlists
                // tab; search stays the rightmost action everywhere.
                if (_tabController.index == 1)
                  IconButton(
                    icon: const ThemeIcon('plus'),
                    onPressed: _createPlaylist,
                  ),
                IconButton(
                  icon: const ThemeIcon('magnifyingGlass'),
                  onPressed: () => setState(() => _searching = true),
                ),
                IconButton(
                  tooltip: 'Music settings',
                  icon: const ThemeIcon('gear'),
                  onPressed: () => Navigator.pushNamed(
                      context, AppRoutes.settings,
                      arguments: kSettingsMusicSection),
                ),
              ],
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Favourites'),
            Tab(text: 'Playlists'),
            Tab(text: 'Tracks'),
          ],
        ),
      ),
      body: AnimatedBuilder(
        animation: AudioPlayerService(),
        builder: (context, _) {
          // The bar floats over the list (frosted glass), so reserve just
          // enough scroll room to clear it when a track is playing.
          _barSpace = AudioPlayerService().current != null
              ? 64.0 + MediaQuery.of(context).padding.bottom
              : 0.0;
          return Stack(
            children: [
              Positioned.fill(
                child: TabBarView(
                  controller: _tabController,
                  physics: _freezeTabs
                      ? const NeverScrollableScrollPhysics()
                      : null,
                  children: [
                    _buildFavourites(),
                    _buildPlaylists(),
                    _buildTracks(),
                  ],
                ),
              ),
              const Align(
                alignment: Alignment.bottomCenter,
                child: MiniPlayerBar(),
              ),
            ],
          );
        },
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
      padding: EdgeInsets.only(bottom: _barSpace),
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
            Notify.error('Could not play: $e');
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
          final favs = snap.data!
              .where((f) =>
                  f.isFavorite &&
                  _matchesQuery(AudioPlayerService.displayTitle(f)))
              .toList();
          if (favs.isEmpty) {
            return _buildEmpty(_query.isEmpty
                ? 'No favourite tracks yet'
                : 'No matches in Favourites');
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
          final files = snap.data!
              .where((f) => _matchesQuery(AudioPlayerService.displayTitle(f)))
              .toList();
          if (files.isEmpty) {
            return _buildEmpty(
                _query.isEmpty ? 'No audio files yet' : 'No matching tracks');
          }
          final list = _buildTrackList(
            files,
            sourceName: 'Tracks',
            controller: _tracksController,
          );
          // The alphabet rail maps letters to positions in the FULL list, so
          // it only makes sense unfiltered — drop it while searching.
          if (_query.isNotEmpty) return list;
          return Stack(
            children: [
              Positioned.fill(right: 38, child: list),
              Positioned(
                // Held ~14px off the right edge so the finger doesn't land in
                // the system back-swipe zone while scrubbing the alphabet.
                right: 14,
                top: 0,
                bottom: 0,
                child: _AlphabetRail(
                  files: files,
                  onActive: (active) {
                    if (_freezeTabs != active) {
                      setState(() => _freezeTabs = active);
                    }
                  },
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
    return RefreshIndicator(
      onRefresh: _handleSync,
      child: FutureBuilder<List<CnestAlbum>>(
        future: _playlistsFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final playlists =
              snap.data!.where((p) => _matchesQuery(p.name)).toList();
          if (playlists.isEmpty && _query.isNotEmpty) {
            return _buildEmpty('No matching playlists');
          }
          // Same pinch-to-zoom morph as gallery Albums (list / 3-across /
          // 2-across), driven live by the fingers and snapped on release.
          return PlaylistsMorphView(
            playlists: playlists,
            bottomPadding: _barSpace,
            onPinchActive: (active) {
              if (_freezeTabs != active) {
                setState(() => _freezeTabs = active);
              }
            },
            onOpen: (playlist) async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PlaylistDetailScreen(playlist: playlist),
                ),
              );
              _refresh();
            },
            onLongPress: (playlist) {
              if (!playlist.isSmart) _showPlaylistActions(playlist);
            },
          );
        },
      ),
    );
  }

  Future<void> _changePlaylistCover(CnestAlbum playlist) async {
    final picked = await CoverArtService.pickImageWithName();
    if (picked == null) return;
    try {
      await CoverArtService().setPlaylistCover(
        playlist: playlist,
        imageBytes: picked.$1,
        originalName: picked.$2,
      );
      _refresh();
    } catch (e) {
      if (e is CnestError) {
        if (mounted) await showCnestError(context, e);
        return;
      }
      Notify.error('Could not set cover: $e');
    }
  }

  Future<void> _removePlaylistCover(CnestAlbum playlist) async {
    try {
      await CoverArtService().removePlaylistCover(playlist);
      _refresh();
    } catch (e) {
      Notify.error('Could not remove cover: $e');
    }
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
              leading: const ThemeIcon('image'),
              title: Text(playlist.coverFileId == null
                  ? 'Add cover image'
                  : 'Change cover image'),
              onTap: () {
                Navigator.pop(ctx);
                _changePlaylistCover(playlist);
              },
            ),
            if (playlist.coverFileId != null)
              ListTile(
                leading: ThemeIcon('trash', color: cs.error),
                title: Text('Remove cover image',
                    style: TextStyle(color: cs.error)),
                subtitle: const Text('Deletes the cover photo permanently'),
                onTap: () {
                  Navigator.pop(ctx);
                  _removePlaylistCover(playlist);
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
/// iOS-style fast-scroll index: press the alphabet and a magnified bubble
/// pops up next to your finger; slide up/down and the bubble follows, the
/// letter grows/changes, and the track list jumps to that letter live. Lift
/// off and you stay where you landed.
class _AlphabetRail extends StatefulWidget {
  final List<CnestFile> files;
  final ValueChanged<int> onJump;

  /// Fires true while a finger is dragging the rail, false on release — the
  /// parent freezes tab-swiping so a rail drag never flips to another tab.
  final ValueChanged<bool>? onActive;
  const _AlphabetRail({required this.files, required this.onJump, this.onActive});

  @override
  State<_AlphabetRail> createState() => _AlphabetRailState();
}

class _AlphabetRailState extends State<_AlphabetRail> {
  static const _letters = [
    'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
    'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', '#',
  ];

  int? _activeIndex;
  Offset _fingerGlobal = Offset.zero;
  OverlayEntry? _bubble;

  @override
  void dispose() {
    _bubble?.remove();
    _bubble = null;
    super.dispose();
  }

  int _firstTrackForLetter(String letter) {
    // First track whose title starts at/after the letter; '#' = the very top
    // (non-alphabetic titles sort before 'A').
    if (letter == '#') return 0;
    for (var i = 0; i < widget.files.length; i++) {
      final first = AudioPlayerService.displayTitle(widget.files[i])
          .trimLeft()
          .toUpperCase();
      if (first.isEmpty) continue;
      if (first.codeUnitAt(0) >= letter.codeUnitAt(0)) return i;
    }
    return widget.files.length - 1;
  }

  void _update(Offset local, Offset global) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final frac = (local.dy / box.size.height).clamp(0.0, 0.999);
    final idx = (frac * _letters.length).floor().clamp(0, _letters.length - 1);
    _fingerGlobal = global;
    if (idx != _activeIndex) {
      setState(() => _activeIndex = idx);
      widget.onJump(_firstTrackForLetter(_letters[idx]));
    }
    // Follow the finger even within one letter's band.
    if (_bubble == null) {
      _bubble = OverlayEntry(builder: _buildBubble);
      Overlay.of(context).insert(_bubble!);
      widget.onActive?.call(true); // freeze tab-swiping for this drag
    } else {
      _bubble!.markNeedsBuild();
    }
  }

  void _end() {
    final wasActive = _bubble != null;
    _bubble?.remove();
    _bubble = null;
    if (wasActive) widget.onActive?.call(false);
    if (mounted) {
      setState(() => _activeIndex = null);
    } else {
      _activeIndex = null;
    }
  }

  Widget _buildBubble(BuildContext ctx) {
    final idx = _activeIndex;
    if (idx == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    const size = 60.0;
    final screen = MediaQuery.of(ctx).size;
    final top =
        (_fingerGlobal.dy - size / 2).clamp(8.0, screen.height - size - 8);
    // Sit to the LEFT of the finger so the rail and the finger don't hide it.
    final left =
        (_fingerGlobal.dx - size - 24).clamp(8.0, screen.width - size - 8);
    return Positioned(
      left: left,
      top: top,
      // Material ancestor: without one, Text painted straight into the
      // Overlay shows the debug yellow double-underline.
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withAlpha(60),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              _letters[idx],
              style: TextStyle(
                color: cs.onPrimary,
                fontSize: 30,
                fontWeight: FontWeight.w700,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Raw Listener so a press-and-hold (no movement needed) shows the bubble
    // instantly and every subsequent move tracks the finger.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _update(e.localPosition, e.position),
      onPointerMove: (e) => _update(e.localPosition, e.position),
      onPointerUp: (_) => _end(),
      onPointerCancel: (_) => _end(),
      child: Container(
        width: 22,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: LayoutBuilder(
          builder: (_, c) => FittedBox(
            fit: BoxFit.scaleDown,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: c.maxWidth.isFinite ? c.maxWidth : 0.0,
                minHeight: c.maxHeight.isFinite ? c.maxHeight : 0.0,
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < _letters.length; i++)
                    Text(
                      _letters[i],
                      style: TextStyle(
                        color: _activeIndex == i
                            ? cs.primary
                            : cs.onSurface.withAlpha(120),
                        fontSize: 9,
                        fontWeight: _activeIndex == i
                            ? FontWeight.w900
                            : FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
