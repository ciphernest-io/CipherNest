import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/activity_center.dart';
import '../../services/database_service.dart';
import '../../services/file_export_service.dart';
import '../models/file_model.dart';
import 'theme_icon.dart';

/// The three cross-surface file actions — "send the actual file" (system
/// share sheet), "save a decrypted copy to the device", and rename — shared
/// by the viewer, category tabs, music menu, and the Files browser so every
/// surface behaves identically. Decrypt phases run as activity-pill tasks
/// (the old blocking "Decrypting…" modal is gone) — the user keeps
/// browsing; the system share sheet / save dialog opens when the
/// materialization finishes.

/// Decrypts [files] into the app-private temp dir and hands them to the
/// system share sheet (WhatsApp, Gmail, …). The receiver gets plaintext —
/// that's the point; the on-disk copies stay app-private and are reclaimed
/// by the cache GC (same artifact the documents-open flow leaves).
Future<void> sendFilesPlain(BuildContext context, List<CnestFile> files) async {
  if (files.isEmpty) return;

  final task = ActivityCenter().start(
      kind: ActivityKind.export,
      label: 'Decrypting 0/${files.length}…',
      total: files.length);
  final out = <XFile>[];
  var done = 0;
  for (final f in files) {
    try {
      final plain = await FileExportService.materializePlaintext(f);
      if (plain != null) out.add(XFile(plain.path, name: f.filename));
    } catch (_) {
      // Counts as missing below — one dead download must not leak the
      // task or sink the whole share.
    }
    done++;
    task.update(done, label: 'Decrypting $done/${files.length}…');
  }

  final missing = files.length - out.length;
  if (out.isEmpty) {
    task.fail('File${files.length == 1 ? ' isn\'t' : 's aren\'t'} '
        'downloadable yet. Sync and try again.');
    return;
  }
  task.complete(missing > 0
      ? '$missing file${missing == 1 ? ' isn\'t' : 's aren\'t'} '
          'downloadable yet, sharing the rest'
      : null);
  // Context-free on Android (sharePositionOrigin is an iPad concern) — the
  // sheet opens over whatever screen the user is on now.
  await Share.shareXFiles(out);
}

/// Confirm → decrypt → save outside the vault. Media goes to the phone
/// gallery, other types to a user-picked location.
Future<void> saveFileToDevice(BuildContext context, CnestFile file) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save a decrypted copy?'),
      content: Text(
          '"${file.filename}" will be saved outside your vault, without '
          'encryption. Anyone with access to this device can open it.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save')),
      ],
    ),
  );
  if (confirmed != true) return;

  final task = ActivityCenter().start(
      kind: ActivityKind.export, label: 'Decrypting "${file.filename}"…');
  try {
    final outcome = await FileExportService.saveToDevice(file);
    switch (outcome) {
      case SaveOutcome.savedToGallery:
        task.complete('Saved to your phone\'s gallery');
      case SaveOutcome.savedToPicked:
        task.complete('Saved');
      case SaveOutcome.alreadyInGallery:
        task.complete('This file is already in your phone\'s gallery');
      case SaveOutcome.cancelled:
        task.discard();
    }
  } catch (e) {
    task.fail('Could not save: $e');
  }
}

/// Rename prompt + the renameFile op. [onRenamed] fires with the new name
/// for screens that hold a local copy of the row.
Future<void> promptRenameFile(
  BuildContext context,
  CnestFile file, {
  void Function(String newName)? onRenamed,
}) async {
  final controller = TextEditingController(text: file.filename);
  final newName = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(hintText: 'File name'),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('OK')),
      ],
    ),
  );
  if (newName == null || newName.isEmpty || newName == file.filename) return;
  await DatabaseService().renameFile(file.id, newName);
  onRenamed?.call(newName);
}

/// The share chooser used wherever a single file's share button lives:
/// "Send file" (plain, via the system sheet) vs "Share secure link" (the
/// zero-knowledge magic link). [onSecureLink] opens the existing
/// ShareDialog — passed in so this widget stays free of the share-service
/// dependency.
Future<void> showShareChoiceSheet(
  BuildContext context,
  CnestFile file, {
  required VoidCallback onSecureLink,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: cs.surface,
    // Two subtitled tiles (~208dp) exceed the 9/16 cap in landscape.
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: ThemeIcon('shareFat', color: cs.primary),
              title: Text('Send file', style: TextStyle(color: cs.onSurface)),
              subtitle: Text('WhatsApp, Gmail… the file itself, decrypted',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                sendFilesPlain(context, [file]);
              },
            ),
            ListTile(
              leading: ThemeIcon('link', color: cs.primary),
              title: Text('Share secure link',
                  style: TextStyle(color: cs.onSurface)),
              subtitle: Text('Stays encrypted. The key never leaves the link',
                  style: TextStyle(
                      color: cs.onSurface.withAlpha(140), fontSize: 11)),
              onTap: () {
                Navigator.pop(ctx);
                onSecureLink();
              },
            ),
          ],
        ),
        ),
      ),
    ),
  );
}
