import 'package:flutter/material.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/database_service.dart';
import '../../models/album_model.dart';
import '../../models/file_model.dart';
import '../../widgets/theme_icon.dart';
import 'widgets/music_widgets.dart';

/// Multi-select picker for adding vault tracks to a playlist. Pops with
/// `true` when tracks were added.
class TrackPickerScreen extends StatefulWidget {
  final CnestAlbum playlist;
  final Set<String> alreadyIn;
  const TrackPickerScreen({
    super.key,
    required this.playlist,
    required this.alreadyIn,
  });

  @override
  State<TrackPickerScreen> createState() => _TrackPickerScreenState();
}

class _TrackPickerScreenState extends State<TrackPickerScreen> {
  late Future<List<CnestFile>> _tracksFuture;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _tracksFuture = DatabaseService()
        .getFilesByType(CnestFileType.audio)
        .then((files) => files
          ..sort((a, b) => AudioPlayerService.displayTitle(a)
              .toLowerCase()
              .compareTo(AudioPlayerService.displayTitle(b).toLowerCase())));
  }

  Future<void> _confirm() async {
    if (_selected.isEmpty) return;
    await DatabaseService()
        .addFilesToAlbum(widget.playlist.id, _selected.toList());
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty
            ? 'Add tracks'
            : '${_selected.length} selected'),
        actions: [
          IconButton(
            icon: ThemeIcon('check',
                color: _selected.isEmpty
                    ? cs.onSurface.withAlpha(80)
                    : cs.primary),
            onPressed: _confirm,
          ),
        ],
      ),
      body: FutureBuilder<List<CnestFile>>(
        future: _tracksFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final files = snap.data!
              .where((f) => !widget.alreadyIn.contains(f.id))
              .toList();
          if (files.isEmpty) {
            return Center(
              child: Text(
                'Every track is already in this playlist',
                style: TextStyle(color: cs.onSurface.withAlpha(120)),
              ),
            );
          }
          return ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              final selected = _selected.contains(file.id);
              return InkWell(
                onTap: () => setState(() {
                  selected ? _selected.remove(file.id) : _selected.add(file.id);
                }),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      ThemeIcon(
                        selected ? 'checkCircle' : 'radio_button_unchecked',
                        selected: selected,
                        color: selected
                            ? cs.primary
                            : cs.onSurface.withAlpha(120),
                        size: 22,
                      ),
                      const SizedBox(width: 12),
                      const TrackArt(),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          AudioPlayerService.displayTitle(file),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
