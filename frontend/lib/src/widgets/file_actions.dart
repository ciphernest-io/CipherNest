import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../services/database_service.dart';
import '../../services/file_export_service.dart';
import '../models/file_model.dart';
import 'theme_icon.dart';

/// The three cross-surface file actions — "send the actual file" (system
/// share sheet), "save a decrypted copy to the device", and rename — shared
/// by the viewer, category tabs, music menu, and the Files browser so every
/// surface behaves identically.

Future<T?> _runWithProgress<T>(
  BuildContext context,
  String label,
  Future<T> Function() work,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogUp = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 20),
            Expanded(child: Text(label)),
          ],
        ),
      ),
    ),
  ).whenComplete(() => dialogUp = false);
  try {
    return await work();
  } finally {
    if (dialogUp) navigator.pop();
  }
}

/// Decrypts [files] into the app-private temp dir and hands them to the
/// system share sheet (WhatsApp, Gmail, …). The receiver gets plaintext —
/// that's the point; the on-disk copies stay app-private and are reclaimed
/// by the cache GC (same artifact the documents-open flow leaves).
Future<void> sendFilesPlain(BuildContext context, List<CnestFile> files) async {
  if (files.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);

  final xfiles = await _runWithProgress(context, 'Decrypting…', () async {
    final out = <XFile>[];
    for (final f in files) {
      final plain = await FileExportService.materializePlaintext(f);
      if (plain != null) out.add(XFile(plain.path, name: f.filename));
    }
    return out;
  });
  if (xfiles == null) return;

  final missing = files.length - xfiles.length;
  if (xfiles.isEmpty) {
    messenger.showSnackBar(const SnackBar(
        content:
            Text('File isn\'t downloadable yet — sync and try again.')));
    return;
  }
  if (missing > 0) {
    messenger.showSnackBar(SnackBar(
        content: Text('$missing file${missing == 1 ? ' isn\'t' : 's aren\'t'} '
            'downloadable yet — sharing the rest.')));
  }
  await Share.shareXFiles(xfiles);
}

/// Confirm → decrypt → save outside the vault. Media goes to the phone
/// gallery, other types to a user-picked location.
Future<void> saveFileToDevice(BuildContext context, CnestFile file) async {
  final messenger = ScaffoldMessenger.of(context);
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
  if (!context.mounted) return;

  try {
    final outcome = await _runWithProgress(
        context, 'Decrypting…', () => FileExportService.saveToDevice(file));
    final message = switch (outcome) {
      SaveOutcome.savedToGallery => 'Saved to your phone\'s gallery',
      SaveOutcome.savedToPicked => 'Saved',
      SaveOutcome.alreadyInGallery =>
        'This file is already in your phone\'s gallery',
      SaveOutcome.cancelled || null => null,
    };
    if (message != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
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
    builder: (ctx) => SafeArea(
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
              subtitle: Text('Stays encrypted — the key never leaves the link',
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
  );
}
