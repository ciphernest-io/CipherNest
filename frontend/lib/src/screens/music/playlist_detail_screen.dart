import 'package:flutter/material.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/database_service.dart';
import '../../../services/notify.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../widgets/theme_icon.dart';
import '../share/share_dialog.dart';
import 'audio_details_screen.dart';
import 'music_actions.dart';
import 'track_picker_screen.dart';
import 'widgets/music_widgets.dart';

/// One playlist: header with shuffle/play, then its tracks. User playlists
/// can add and remove tracks; smart ones (Recently added, Favourites) are
/// query-driven and read-only.
class PlaylistDetailScreen extends StatefulWidget {
  final CnestAlbum playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late Future<List<CnestFile>> _filesFuture;

  bool _searching = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    DatabaseService().addListener(_onDataChanged);
    _refresh();
  }

  @override
  void dispose() {
    DatabaseService().removeListener(_onDataChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

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
      _filesFuture = DatabaseService().getFilesForAlbum(widget.playlist);
    });
  }

  Future<void> _addTracks() async {
    final files = await _filesFuture;
    if (!mounted) return;
    final added = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TrackPickerScreen(
          playlist: widget.playlist,
          alreadyIn: files.map((f) => f.id).toSet(),
        ),
      ),
    );
    if (added == true) _refresh();
  }

  Future<void> _play(List<CnestFile> files,
      {int startIndex = 0, bool shuffled = false}) async {
    if (files.isEmpty) return;
    final service = AudioPlayerService();
    try {
      await service.playQueue(
        files,
        startIndex: startIndex,
        sourceName: widget.playlist.name,
      );
      if (shuffled != service.shuffleEnabled) {
        await service.toggleShuffle();
      }
    } catch (e) {
      Notify.error('Could not play: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search in playlist',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.playlist.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  FutureBuilder<List<CnestFile>>(
                    future: _filesFuture,
                    builder: (context, snap) => Text(
                      '${snap.data?.length ?? widget.playlist.fileCount} tracks',
                      style: TextStyle(
                        color: cs.onSurface.withAlpha(140),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
        actions: _searching
            ? [
                IconButton(
                  icon: const ThemeIcon('x'),
                  onPressed: _closeSearch,
                ),
              ]
            : [
                if (!widget.playlist.isSmart)
                  IconButton(
                    icon: const ThemeIcon('plus'),
                    onPressed: _addTracks,
                  ),
                IconButton(
                  icon: const ThemeIcon('magnifyingGlass'),
                  onPressed: () => setState(() => _searching = true),
                ),
              ],
      ),
      body: FutureBuilder<List<CnestFile>>(
        future: _filesFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final files = snap.data!;
          final visible = _query.isEmpty
              ? files
              : files
                  .where((f) =>
                      _matchesQuery(AudioPlayerService.displayTitle(f)))
                  .toList();
          return AnimatedBuilder(
            animation: AudioPlayerService(),
            builder: (context, _) {
              // Room for the floating, translucent mini player.
              final barSpace = AudioPlayerService().current != null
                  ? 64.0 + MediaQuery.of(context).padding.bottom
                  : 0.0;
              return Stack(
                children: [
                  Column(
                    children: [
              // Shuffle + play, right-aligned above the list (Samsung).
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _RoundButton(
                      icon: 'shuffle',
                      background: cs.surfaceContainerHigh,
                      foreground: cs.onSurface,
                      onTap: () => _play(files, shuffled: true),
                    ),
                    const SizedBox(width: 12),
                    _RoundButton(
                      icon: 'play',
                      selected: true,
                      background: cs.primary,
                      foreground: cs.onPrimary,
                      onTap: () => _play(files),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text(
                          _query.isNotEmpty
                              ? 'No matching tracks'
                              : widget.playlist.isSmart
                                  ? 'Nothing here yet'
                                  : 'No tracks yet. Tap + to add some.',
                          style: TextStyle(
                            color: cs.onSurface.withAlpha(120),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        padding: EdgeInsets.only(bottom: barSpace),
                        itemBuilder: (context, index) => TrackRow(
                          file: visible[index],
                          onTap: () => _play(visible, startIndex: index),
                          menuBuilder: (ctx) => [
                            if (!widget.playlist.isSmart)
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('Remove from playlist'),
                              ),
                            const PopupMenuItem(
                              value: 'share',
                              child: Text('Share'),
                            ),
                            const PopupMenuItem(
                              value: 'details',
                              child: Text('Details'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                          onMenuSelected: (v) async {
                            final file = visible[index];
                            switch (v) {
                              case 'remove':
                                await DatabaseService().removeFileFromAlbum(
                                    widget.playlist.id, file.id);
                                _refresh();
                              case 'delete':
                                if (context.mounted) {
                                  await deleteTrack(context, file,
                                      onDeleted: _refresh);
                                }
                              case 'share':
                                if (context.mounted) {
                                  ShareDialog.show(context, file);
                                }
                              case 'details':
                                if (context.mounted) {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          AudioDetailsScreen(file: file),
                                    ),
                                  );
                                }
                            }
                          },
                        ),
                      ),
              ),
                    ],
                  ),
                  const Align(
                    alignment: Alignment.bottomCenter,
                    child: MiniPlayerBar(),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final String icon;
  final bool selected;
  final Color background;
  final Color foreground;
  final VoidCallback onTap;
  const _RoundButton({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Center(
          child: ThemeIcon(icon, selected: selected, size: 20,
              color: foreground),
        ),
      ),
    );
  }
}
