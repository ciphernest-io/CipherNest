import 'package:flutter/material.dart';

import '../../../services/database_service.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../widgets/theme_icon.dart';

/// Bottom sheet: pick a playlist to add [file] to, or create a new one.
/// Smart playlists are query-driven, so only user playlists are offered.
class PlaylistPickerSheet extends StatelessWidget {
  final CnestFile file;
  const PlaylistPickerSheet({super.key, required this.file});

  static Future<void> show(BuildContext context, CnestFile file) {
    return showModalBottomSheet(
      context: context,
      builder: (_) => PlaylistPickerSheet(file: file),
    );
  }

  Future<void> _add(BuildContext context, CnestAlbum playlist) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await DatabaseService().addFileToAlbum(playlist.id, file.id);
    navigator.pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Added to ${playlist.name}')),
    );
  }

  Future<void> _createAndAdd(BuildContext context) async {
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
    if (!context.mounted) return;
    final playlist = await DatabaseService().createPlaylist(name);
    if (!context.mounted) return;
    await _add(context, playlist);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: FutureBuilder<List<CnestAlbum>>(
        future: DatabaseService().getPlaylists(),
        builder: (context, snap) {
          final playlists =
              (snap.data ?? []).where((p) => !p.isSmart).toList();
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: cs.onSurface.withAlpha(60),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    'Add to playlist',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: ThemeIcon('plus', color: cs.primary),
                  title: Text('New playlist',
                      style: TextStyle(color: cs.primary)),
                  onTap: () => _createAndAdd(context),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final playlist in playlists)
                        ListTile(
                          leading: const ThemeIcon('playlist'),
                          title: Text(playlist.name),
                          subtitle: Text(
                            '${playlist.fileCount} tracks',
                            style: TextStyle(
                              color: cs.onSurface.withAlpha(120),
                              fontSize: 12,
                            ),
                          ),
                          onTap: () => _add(context, playlist),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
