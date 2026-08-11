import 'package:flutter/material.dart';

import '../../services/activity_center.dart';
import '../../services/audio_player_service.dart';
import '../app.dart';
import '../config/theme_controller.dart';
import '../screens/music/now_playing_screen.dart';
import 'theme_icon.dart';

/// The expanded task list behind the activity pill: what's playing, what's
/// running (with real progress bars and migration controls), what recently
/// finished. The pill hides itself while this is up (setSheetOpen).
Future<void> showActivitySheet(BuildContext context) {
  ActivityCenter().setSheetOpen(true);
  return showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _ActivitySheetBody(),
  ).whenComplete(() => ActivityCenter().setSheetOpen(false));
}

class _ActivitySheetBody extends StatelessWidget {
  const _ActivitySheetBody();

  @override
  Widget build(BuildContext context) {
    final center = ActivityCenter();
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: AnimatedBuilder(
          animation: center,
          builder: (context, _) {
            final running = center.running;
            final recent = center.recent;
            return AnimatedBuilder(
              animation: AudioPlayerService(),
              builder: (context, _) {
                final track = AudioPlayerService().current;
                final empty =
                    running.isEmpty && recent.isEmpty && track == null;
                return ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    if (empty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(
                          child: Text(
                            'Nothing happening right now',
                            style: TextStyle(
                                color: cs.onSurface.withAlpha(140)),
                          ),
                        ),
                      ),
                    if (track != null)
                      ListTile(
                        leading: ThemeIcon('musicNote', color: cs.primary),
                        title: Text(
                          'Playing ${AudioPlayerService.displayTitle(track)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: cs.onSurface),
                        ),
                        trailing: ThemeIcon('caretRight',
                            size: 16, color: cs.onSurface.withAlpha(140)),
                        onTap: () {
                          Navigator.pop(context);
                          final ctx = App.navigatorKey.currentContext;
                          if (ctx != null) NowPlayingScreen.open(ctx);
                        },
                      ),
                    if (track != null &&
                        (running.isNotEmpty || recent.isNotEmpty))
                      const Divider(height: 1),
                    if (running.isNotEmpty)
                      _sectionHeader(cs, 'In progress'),
                    for (final task in running) _RunningRow(task: task),
                    if (recent.isNotEmpty) _sectionHeader(cs, 'Recent'),
                    for (final task in recent) _RecentRow(task: task),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _sectionHeader(ColorScheme cs, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          title,
          style: TextStyle(
            color: cs.onSurface.withAlpha(140),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
      );
}

class _RunningRow extends StatelessWidget {
  final ActivityTask task;
  const _RunningRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasControls = task.onPause != null || task.onCancel != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
                value: task.fraction, strokeWidth: 2.5),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurface, fontSize: 14)),
                if (task.detail != null)
                  Text(task.detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: cs.onSurface.withAlpha(140),
                          fontSize: 11.5)),
                if (task.fraction != null) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                        value: task.fraction, minHeight: 4),
                  ),
                ],
              ],
            ),
          ),
          if (hasControls) ...[
            if (task.onPause != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: ThemeIcon(task.paused ? 'play' : 'pause', size: 20),
                onPressed: () {
                  if (task.paused) {
                    task.onResume?.call();
                    task.setPaused(false);
                  } else {
                    task.onPause?.call();
                    task.setPaused(true);
                  }
                },
              ),
            if (task.onCancel != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const ThemeIcon('x', size: 20),
                onPressed: task.onCancel,
              ),
          ],
        ],
      ),
    );
  }
}

class _RecentRow extends StatelessWidget {
  final ActivityTask task;
  const _RecentRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final failed = task.state == ActivityState.failure;
    return ListTile(
      dense: true,
      leading: ThemeIcon(failed ? 'warningCircle' : 'check',
          size: 20, color: failed ? t.danger : cs.primary),
      title: Text(
        task.resultMessage ?? task.label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: cs.onSurface, fontSize: 13),
      ),
      trailing: Text(
        _relativeTime(task.endedAt),
        style:
            TextStyle(color: cs.onSurface.withAlpha(120), fontSize: 11),
      ),
    );
  }

  String _relativeTime(DateTime? when) {
    if (when == null) return '';
    final mins = DateTime.now().difference(when).inMinutes;
    if (mins < 1) return 'Just now';
    if (mins < 60) return '${mins}m ago';
    return '${(mins / 60).floor()}h ago';
  }
}
