import 'package:flutter/material.dart';
import '../../utils/byte_format.dart';
import 'package:intl/intl.dart';

import '../../../services/audio_art_parser.dart';
import '../../../services/audio_player_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/cover_art_service.dart';
import '../../../services/database_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/notify.dart';
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
  AudioTags? _tags;

  @override
  void initState() {
    super.initState();
    _loadTags();
  }

  /// Reads the track's embedded tags (title/artist/album/…) on demand. The
  /// tags sit at the start of the file, but decryptFile decrypts the whole
  /// blob, so skip very large files. Best-effort: fields stay 'Unknown' on
  /// any failure. Plaintext lives only in memory here.
  Future<void> _loadTags() async {
    final f = _file;
    if (f.cloudId == null) return;
    if (f.sizeBytes > 30 * 1024 * 1024) return;
    try {
      final enc = await CloudService().downloadFile(f.cloudId!);
      final dec = await EncryptionService.decryptFile(enc);
      final tags = AudioArtParser.tags(dec, f.filename);
      if (mounted && tags != null) setState(() => _tags = tags);
    } catch (_) {
      // Leave the fields as 'Unknown'.
    }
  }

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

  Widget _editField(TextEditingController c, String label,
      {bool autofocus = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: c,
        autofocus: autofocus,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  /// Samsung-Music-style "Edit details": name (renames the file), plus the
  /// audio tags. Prefills from the saved override, else the embedded tag.
  Future<void> _showEditDetails() async {
    String seed(String? override, String? parsed) => override ?? parsed ?? '';
    final nameCtrl = TextEditingController(
        text: AudioPlayerService.displayTitle(_file));
    final artistCtrl =
        TextEditingController(text: seed(_file.tagArtist, _tags?.artist));
    final albumCtrl =
        TextEditingController(text: seed(_file.tagAlbum, _tags?.album));
    final albumArtistCtrl = TextEditingController(
        text: seed(_file.tagAlbumArtist, _tags?.albumArtist));
    final genreCtrl =
        TextEditingController(text: seed(_file.tagGenre, _tags?.genre));

    final saved = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Edit details'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _editField(nameCtrl, 'Name', autofocus: true),
              _editField(artistCtrl, 'Artist'),
              _editField(albumCtrl, 'Album'),
              _editField(albumArtistCtrl, 'Album artist'),
              _editField(genreCtrl, 'Genre'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;

    String? nz(String s) => s.trim().isEmpty ? null : s.trim();
    // Name renames the file (keeps its extension); empty keeps the current.
    final ext = _file.filename.contains('.')
        ? '.${_file.filename.split('.').last}'
        : '';
    final name = nameCtrl.text.trim();
    if (name.isNotEmpty && '$name$ext' != _file.filename) {
      await DatabaseService().renameFile(_file.id, '$name$ext');
    }
    await DatabaseService().updateAudioTags(
      _file.id,
      artist: nz(artistCtrl.text),
      album: nz(albumCtrl.text),
      albumArtist: nz(albumArtistCtrl.text),
      genre: nz(genreCtrl.text),
    );
    final updated = await DatabaseService().getFileById(_file.id);
    if (updated != null) {
      AudioPlayerService().updateFile(updated);
      if (mounted) setState(() => _file = updated);
    }
  }

  Future<void> _changeCover() async {
    final bytes = await CoverArtService.pickImageBytes();
    if (bytes == null) return;
    try {
      final updated = await CoverArtService()
          .setTrackCover(track: _file, imageBytes: bytes);
      if (mounted) setState(() => _file = updated);
    } catch (e) {
      Notify.error('Could not set cover: $e');
    }
  }

  Future<void> _removeCover() async {
    try {
      final updated = await CoverArtService().removeTrackCover(_file);
      if (mounted) setState(() => _file = updated);
    } catch (e) {
      Notify.error('Could not remove cover: $e');
    }
  }

  void _showEditSheet() {
    final cs = Theme.of(context).colorScheme;
    final hasCover = _file.thumbnailCloudId != null;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const ThemeIcon('pencilSimple'),
              title: const Text('Edit details'),
              onTap: () {
                Navigator.pop(ctx);
                _showEditDetails();
              },
            ),
            ListTile(
              leading: const ThemeIcon('image'),
              title: Text(hasCover ? 'Change cover photo' : 'Add cover photo'),
              onTap: () {
                Navigator.pop(ctx);
                _changeCover();
              },
            ),
            if (hasCover)
              ListTile(
                leading: ThemeIcon('trash', color: cs.error),
                title: Text('Remove cover photo',
                    style: TextStyle(color: cs.error)),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeCover();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    final tags = _tags;
    String show(String? override, String? parsed) =>
        override ?? parsed ?? 'Unknown';
    final fields = <(String, String)>[
      ('Title', AudioPlayerService.displayTitle(_file)),
      ('Artist', show(_file.tagArtist, tags?.artist)),
      ('Album', show(_file.tagAlbum, tags?.album)),
      ('Album artist', show(_file.tagAlbumArtist, tags?.albumArtist)),
      ('Genre', show(_file.tagGenre, tags?.genre)),
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
            onPressed: _showEditSheet,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: GestureDetector(
              onTap: _changeCover,
              child: Stack(
                children: [
                  TrackArt(size: 180, iconSize: 72, file: _file),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: cs.surface.withAlpha(230),
                        shape: BoxShape.circle,
                        border: Border.all(color: cs.outline.withAlpha(90)),
                      ),
                      child: ThemeIcon('camera',
                          size: 16, color: cs.onSurface),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
            _file.tagArtist ?? _tags?.artist ?? 'Unknown',
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
