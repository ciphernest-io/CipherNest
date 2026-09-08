import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/backup_backfill_runner.dart';
import '../../../services/backup_selection_service.dart';
import '../../../services/migration_service.dart';
import '../../../services/system_folders.dart';
import '../../widgets/theme_icon.dart';

/// Which device albums back up — the Ente-style checklist behind auto-sync.
/// All-mode rows render checked-and-dimmed (informational); selected-mode
/// rows toggle, and enrolling one asks "from now" vs "include existing"
/// (the latter queues a bucket-scoped backfill).
class BackupAlbumsScreen extends StatefulWidget {
  const BackupAlbumsScreen({super.key, this.deferBackfill = false});

  /// Quick-settings path: enrollments queue their backfill but nothing
  /// uploads until onboarding actually enters the app (MTR#2 A11).
  final bool deferBackfill;

  @override
  State<BackupAlbumsScreen> createState() => _BackupAlbumsScreenState();
}

class _BackupAlbumsScreenState extends State<BackupAlbumsScreen> {
  BackupSelection? _selection;
  List<AlbumInfo>? _albums;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final selection = await BackupSelectionService().load();
    final albums = await MigrationService().getAlbums();
    if (!mounted) return;
    setState(() {
      _selection = selection;
      _albums = albums.where((a) => !a.path.isAll).toList();
    });
  }

  Future<void> _setMode(BackupMode mode) async {
    await BackupSelectionService().setMode(mode);
    await _load();
  }

  Future<void> _toggle(AlbumInfo album, bool enroll) async {
    if (enroll) {
      final backfill = await showBackupEnrollSheet(context, album.name,
          existingCount: album.count);
      if (backfill == null) return; // dismissed = don't enroll
      await BackupSelectionService().enroll(album.name, backfill: backfill);
      // Deferred (quick settings): the queue is persisted; the onboarding
      // finish fires runPending once the user actually enters.
      if (backfill && !widget.deferBackfill) {
        unawaited(BackupBackfillRunner().runPending());
      }
    } else {
      await BackupSelectionService().unenroll(album.name);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selection = _selection;
    final albums = _albums;

    return Scaffold(
      appBar: AppBar(title: const Text('Backed-up albums')),
      // Every checkbox change writes through immediately; Done is the
      // explicit confirm affordance the flow lacked (back-arrow-only exit
      // read as "did that save?" in the field).
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: () => Navigator.pop(context),
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('Done'),
          ),
        ),
      ),
      body: selection == null || albums == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                RadioGroup<BackupMode>(
                  groupValue: selection.mode,
                  onChanged: (m) {
                    if (m != null) _setMode(m);
                  },
                  child: Column(
                    children: [
                      RadioListTile<BackupMode>(
                        value: BackupMode.all,
                        title: const Text('All albums'),
                        subtitle: Text(
                          'Every album on this phone backs up, including '
                          'new albums that appear later',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(140),
                              fontSize: 12),
                        ),
                      ),
                      RadioListTile<BackupMode>(
                        value: BackupMode.selected,
                        title: const Text('Selected albums only'),
                        subtitle: Text(
                          'Only the albums you tick below back up',
                          style: TextStyle(
                              color: cs.onSurface.withAlpha(140),
                              fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                if (albums.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No albums found on this device',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.onSurface.withAlpha(120)),
                    ),
                  ),
                for (final album in albums)
                  _albumRow(album, selection, cs),
              ],
            ),
    );
  }

  Widget _albumRow(AlbumInfo album, BackupSelection selection, ColorScheme cs) {
    final allMode = selection.mode == BackupMode.all;
    final enrolled = allMode ||
        selection.enrolled.contains(SystemFolders.normalize(album.name));
    return Opacity(
      opacity: allMode ? 0.55 : 1,
      child: CheckboxListTile(
        value: enrolled,
        onChanged: allMode ? null : (v) => _toggle(album, v == true),
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(album.name, style: TextStyle(color: cs.onSurface)),
        subtitle: Text(
          '${album.count} item${album.count == 1 ? '' : 's'}',
          style: TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
        ),
      ),
    );
  }
}

/// "From now" vs "include existing" ask when one album is enrolled.
/// Returns null = dismissed (don't enroll), false = from now, true = also
/// backfill existing photos.
Future<bool?> showBackupEnrollSheet(BuildContext context, String albumName,
    {int? existingCount}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Back up "$albumName"',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const ThemeIcon('clock'),
            title: const Text('From now'),
            subtitle: Text(
              'Only photos added after today',
              style:
                  TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
            ),
            onTap: () => Navigator.pop(ctx, false),
          ),
          ListTile(
            leading: const ThemeIcon('arrowsClockwise'),
            title: const Text('Include existing photos'),
            subtitle: Text(
              existingCount == null
                  ? 'Also encrypts everything already in this album'
                  : 'Also encrypts the $existingCount items already in this '
                      'album',
              style:
                  TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
            ),
            onTap: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 8),
        ],
        ),
      ),
    ),
  );
}

/// The onboarding / first-enable ask: all albums vs a checklist. Persists
/// the mode; the all-albums path also offers the include-existing shortcut
/// (queues a backfill for every current bucket). Pushing the checklist
/// screen presets selected mode.
///
/// Returns false when the sheet was DISMISSED without a choice — callers
/// that just flipped auto-sync on must revert the toggle: an absent
/// selection pref reads as BackupMode.all, so a silent dismissal used to
/// commit the most aggressive setting (all albums, background) by
/// not-choosing (MTR#1 F8).
Future<bool> showBackupAlbumChoiceSheet(
  BuildContext context, {
  bool deferBackfill = false,
}) async {
  final cs = Theme.of(context).colorScheme;
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Which albums should back up?',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          ListTile(
            leading: const ThemeIcon('infinity'),
            title: const Text('All albums'),
            subtitle: Text(
              'Includes new albums later',
              style:
                  TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
            ),
            onTap: () => Navigator.pop(ctx, 'all'),
          ),
          ListTile(
            leading: const ThemeIcon('checklist'),
            title: const Text('Choose albums'),
            subtitle: Text(
              'Pick exactly which albums are protected',
              style:
                  TextStyle(color: cs.onSurface.withAlpha(140), fontSize: 12),
            ),
            onTap: () => Navigator.pop(ctx, 'choose'),
          ),
          const SizedBox(height: 8),
        ],
        ),
      ),
    ),
  );
  if (choice == null) return false; // dismissed: caller reverts the toggle

  if (choice == 'all') {
    await BackupSelectionService().setMode(BackupMode.all);
    if (!context.mounted) return true;
    final backfill = await showBackupEnrollSheet(context, 'all albums');
    if (backfill == true) {
      final albums = await MigrationService().getAlbums();
      await BackupSelectionService().queueBackfills(
          albums.where((a) => !a.path.isAll).map((a) => a.name));
      // deferBackfill (quick settings): the queue is persisted; the caller
      // fires runPending when the user actually enters the app.
      if (!deferBackfill) unawaited(BackupBackfillRunner().runPending());
    }
    return true;
  }

  await BackupSelectionService().setMode(BackupMode.selected);
  if (!context.mounted) return true;
  await Navigator.push(
    context,
    MaterialPageRoute(
        builder: (_) => BackupAlbumsScreen(deferBackfill: deferBackfill)),
  );
  return true;
}
