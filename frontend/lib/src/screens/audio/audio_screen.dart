import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import '../../widgets/theme_icon.dart';

import '../../models/file_model.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cloud/cloud_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../../services/encryption_service.dart';
import '../../../services/sync_service.dart';
import '../share/share_dialog.dart';

class AudioScreen extends StatefulWidget {
  const AudioScreen({super.key});

  @override
  State<AudioScreen> createState() => _AudioScreenState();
}

class _AudioScreenState extends State<AudioScreen> {
  late Future<List<CnestFile>> _filesFuture;
  final _player = AudioPlayer();
  CnestFile? _nowPlaying;
  String? _preparingFileId;

  @override
  void initState() {
    super.initState();
    SyncService().syncNotifier.addListener(_onSyncComplete);
    _refresh();
  }

  @override
  void dispose() {
    SyncService().syncNotifier.removeListener(_onSyncComplete);
    _player.dispose();
    super.dispose();
  }

  void _onSyncComplete() {
    if (mounted) _refresh();
  }

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.audio);
    });
  }

  Future<void> _handleSync() async {
    await SyncService().syncNow(force: true);
  }

  /// Decrypts to a temp file (cached) and feeds it to just_audio.
  /// Could be upgraded to streaming via VideoStreamingServer later if needed.
  Future<void> _handlePlay(CnestFile file) async {
    if (_preparingFileId == file.id) return; // already preparing
    if (_nowPlaying?.id == file.id) {
      // Tap-to-toggle: pause if playing, resume if paused
      if (_player.playing) {
        await _player.pause();
      } else {
        await _player.play();
      }
      setState(() {});
      return;
    }

    setState(() => _preparingFileId = file.id);

    try {
      File? srcFile;
      // Local-first
      if (file.localPath != null) {
        final f = File(file.localPath!);
        if (await f.exists()) srcFile = f;
      }
      // Cloud cache fallback
      if (srcFile == null) {
        final tempDir = await getTemporaryDirectory();
        final cached = File('${tempDir.path}/${file.id}_audio.bin');
        if (!await cached.exists()) {
          if (file.cloudId == null) throw Exception('No cloud ID');
          final encryptedBytes = await CloudService().downloadFile(file.cloudId!);
          final decryptStream = EncryptionService.decryptToStream(encryptedBytes);
          final sink = cached.openWrite();
          await sink.addStream(decryptStream);
          await sink.close();
        }
        srcFile = cached;
      }

      await _player.setFilePath(srcFile.path);
      await _player.play();
      if (mounted) {
        setState(() {
          _nowPlaying = file;
          _preparingFileId = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _preparingFileId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not play: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _handleDelete(CnestFile file) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Audio?'),
        content: Text('Permanently delete "${file.filename}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      // Stop player if it was playing this file
      if (_nowPlaying?.id == file.id) {
        await _player.stop();
        _nowPlaying = null;
      }

      if (file.cloudId != null) {
        await CloudService().deleteFile(file.cloudId!);
      }
      if (file.thumbnailCloudId != null) {
        await CloudService().deleteFile(file.thumbnailCloudId!);
      }
      await DatabaseService().deleteFile(file.id);
      AutoSyncService.trackDeletion(file.filename, file.sizeBytes);
      DatabaseBackupService().scheduleBackup();

      // Cleanup cached temp file
      final tempDir = await getTemporaryDirectory();
      final cached = File('${tempDir.path}/${file.id}_audio.bin');
      if (await cached.exists()) await cached.delete();

      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio'),
        actions: [
          IconButton(
            icon: ThemeIcon('arrowsClockwise'),
            onPressed: _handleSync,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _handleSync,
              child: FutureBuilder<List<CnestFile>>(
                future: _filesFuture,
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final files = snapshot.data!;
                  if (files.isEmpty) {
                    return ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        const SizedBox(height: 200),
                        Center(
                          child: Column(
                            children: [
                              ThemeIcon('musicNote',
                                  size: 64, color: cs.onSurface.withAlpha(80)),
                              const SizedBox(height: 16),
                              Text('No audio files yet',
                                  style: TextStyle(color: cs.onSurface.withAlpha(120))),
                            ],
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    itemCount: files.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final file = files[index];
                      final isPreparing = _preparingFileId == file.id;
                      final isCurrent = _nowPlaying?.id == file.id;
                      final isPlaying = isCurrent && _player.playing;
                      return Container(
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cs.outline),
                        ),
                        child: ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          leading: CircleAvatar(
                            backgroundColor: cs.primary.withAlpha(60),
                            child: isPreparing
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: cs.primary),
                                  )
                                : Icon(
                                    isPlaying
                                        ? themeIconData('pause', selected: true)
                                        : themeIconData('play', selected: true),
                                    color: cs.primary,
                                    size: 18,
                                  ),
                          ),
                          title: Text(
                            file.filename,
                            style: TextStyle(
                                color: cs.onSurface,
                                fontWeight: FontWeight.w600,
                                fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${_formatSize(file.sizeBytes)} · ${DateFormat.yMMMd().format(file.createdAt)}',
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(140),
                                fontSize: 12),
                          ),
                          trailing: PopupMenuButton<String>(
                            icon: ThemeIcon('dotsThreeVertical',
                                color: cs.onSurface.withAlpha(140)),
                            onSelected: (v) {
                              if (v == 'share') ShareDialog.show(context, file);
                              if (v == 'delete') _handleDelete(file);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'share',
                                child: Text('Share'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete',
                                    style: TextStyle(color: Colors.redAccent)),
                              ),
                            ],
                          ),
                          onTap: () => _handlePlay(file),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
          if (_nowPlaying != null) _buildPlayerBar(cs),
        ],
      ),
    );
  }

  Widget _buildPlayerBar(ColorScheme cs) {
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(top: BorderSide(color: cs.outline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ThemeIcon('musicNote',
                  size: 20, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _nowPlaying!.filename,
                  style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(
                  _player.playing
                      ? themeIconData('pause', selected: true)
                      : themeIconData('play', selected: true),
                  color: cs.primary,
                ),
                onPressed: () async {
                  if (_player.playing) {
                    await _player.pause();
                  } else {
                    await _player.play();
                  }
                  if (mounted) setState(() {});
                },
              ),
              IconButton(
                icon: ThemeIcon('stop',
                    color: cs.onSurface.withAlpha(140)),
                onPressed: () async {
                  await _player.stop();
                  if (mounted) setState(() => _nowPlaying = null);
                },
              ),
            ],
          ),
          StreamBuilder<Duration>(
            stream: _player.positionStream,
            builder: (context, snap) {
              final pos = snap.data ?? Duration.zero;
              final total = _player.duration ?? Duration.zero;
              final fraction = total.inMilliseconds == 0
                  ? 0.0
                  : pos.inMilliseconds / total.inMilliseconds;
              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: fraction.clamp(0.0, 1.0),
                      onChanged: (v) {
                        if (total.inMilliseconds > 0) {
                          _player.seek(Duration(
                              milliseconds:
                                  (v * total.inMilliseconds).round()));
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(pos),
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(140), fontSize: 11)),
                        Text(_formatDuration(total),
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(140), fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
