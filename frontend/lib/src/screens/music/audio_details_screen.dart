import 'package:flutter/material.dart';
import '../../utils/byte_format.dart';
import 'package:intl/intl.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/database_service.dart';
import '../../config/theme_controller.dart';
import '../../models/file_model.dart';
import '../../widgets/theme_icon.dart';
import 'widgets/music_widgets.dart';

/// Samsung Music-style track details: art, title, then a card of
/// field/value rows. Edit renames the track in the vault.
class AudioDetailsScreen extends StatefulWidget {
  final CnestFile file;
  const AudioDetailsScreen({super.key, required this.file});

  @override
  State<AudioDetailsScreen> createState() => _AudioDetailsScreenState();
}

class _AudioDetailsScreenState extends State<AudioDetailsScreen> {
  late CnestFile _file = widget.file;

  String get _format {
    final ext = _file.filename.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      default:
        return ext.toUpperCase();
    }
  }

  String get _size => formatBytes(_file.sizeBytes);

  /// Track length is only known when this track is loaded in the player —
  /// duration lives inside the encrypted blob, and we don't decrypt just to
  /// display a number.
  String get _length {
    final service = AudioPlayerService();
    if (service.current?.id == _file.id) {
      final d = service.player.duration;
      if (d != null && d > Duration.zero) {
        final m = d.inMinutes.toString();
        final s = (d.inSeconds % 60).toString().padLeft(2, '0');
        return '$m:$s';
      }
    }
    return '—';
  }

  Future<void> _rename() async {
    final controller = TextEditingController(
      text: AudioPlayerService.displayTitle(_file),
    );
    final ext = _file.filename.contains('.')
        ? '.${_file.filename.split('.').last}'
        : '';
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename track'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final filename = '$name$ext';
    await DatabaseService().renameFile(_file.id, filename);
    final updated = CnestFile(
      id: _file.id,
      cloudId: _file.cloudId,
      thumbnailCloudId: _file.thumbnailCloudId,
      provider: _file.provider,
      accountId: _file.accountId,
      filename: filename,
      sizeBytes: _file.sizeBytes,
      createdAt: _file.createdAt,
      isUploaded: _file.isUploaded,
      localPath: _file.localPath,
      assetId: _file.assetId,
      isFavorite: _file.isFavorite,
      type: _file.type,
    );
    AudioPlayerService().updateFile(updated);
    if (mounted) setState(() => _file = updated);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    final fields = <(String, String)>[
      ('Artist', 'Unknown'),
      ('Track length', _length),
      ('Format', _format),
      ('Size', _size),
      ('Date added', DateFormat.yMMMd().format(_file.createdAt)),
      ('Synced', _file.isUploaded ? 'Yes' : 'Not yet'),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Details'),
        actions: [
          IconButton(
            icon: const ThemeIcon('pencilSimple'),
            onPressed: _rename,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Center(child: TrackArt(size: 180, iconSize: 72)),
          const SizedBox(height: 20),
          Text(
            AudioPlayerService.displayTitle(_file),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cs.primary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Unknown',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 13),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerLow,
              borderRadius: BorderRadius.circular(t.rCardLg),
            ),
            child: Column(
              children: [
                for (final (label, value) in fields)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: label == fields.last.$1
                            ? BorderSide.none
                            : BorderSide(color: cs.outline.withAlpha(80)),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 110,
                          child: Text(
                            label,
                            style: TextStyle(
                              color: cs.onSurface.withAlpha(140),
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            value,
                            style:
                                TextStyle(color: cs.onSurface, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Vault',
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            _file.id,
            style: TextStyle(
              color: cs.onSurface.withAlpha(140),
              fontSize: 11,
              fontFamily: t.monoFontFamily,
            ),
          ),
        ],
      ),
    );
  }
}
