import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/auto_sync_service.dart';
import '../../../services/cover_art_service.dart';
import '../../../services/database_backup_service.dart';
import '../../../services/database_service.dart';
import '../../../services/notify.dart';
import '../../models/file_model.dart';

/// Shared track actions so the now-playing screen, the Music lists, and a
/// playlist's tracks all offer the SAME three-dot options (delete, share,
/// set-as-cover) with identical behavior.

/// Moves a track to the Recycle Bin: confirm, stop it if playing, soft-delete,
/// and wipe its private audio cache. [onDeleted] fires after a real delete.
Future<void> deleteTrack(
  BuildContext context,
  CnestFile file, {
  VoidCallback? onDeleted,
}) async {
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
          child: Text('Delete',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
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
  if (context.mounted) Notify.info('Moved to Recycle Bin');
  onDeleted?.call();
}

/// Picks an image and sets it as [file]'s cover. [onUpdated] receives the
/// refreshed row (new thumbnail) on success.
Future<void> setTrackCoverFlow(
  BuildContext context,
  CnestFile file, {
  ValueChanged<CnestFile>? onUpdated,
}) async {
  final bytes = await CoverArtService.pickImageBytes();
  if (bytes == null) return;
  try {
    final updated =
        await CoverArtService().setTrackCover(track: file, imageBytes: bytes);
    onUpdated?.call(updated);
    if (context.mounted) Notify.info('Cover updated');
  } catch (e) {
    Notify.error('Could not set cover: $e');
  }
}
