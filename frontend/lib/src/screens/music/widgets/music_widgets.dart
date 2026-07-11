import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../../../services/audio_player_service.dart';
import '../../../config/theme_controller.dart';
import '../../../models/file_model.dart';
import '../../../widgets/theme_icon.dart';
import '../now_playing_screen.dart';

/// Square track-art tile. Until ID3 art extraction lands, every track gets
/// the Samsung-style note-on-grey placeholder.
class TrackArt extends StatelessWidget {
  final double size;
  final double? iconSize;
  const TrackArt({super.key, this.size = 48, this.iconSize});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(t.rIc),
      ),
      child: Center(
        child: ThemeIcon(
          'musicNote',
          size: iconSize ?? size * 0.45,
          color: cs.onSurface.withAlpha(160),
        ),
      ),
    );
  }
}

/// One track in any list: art, title, artist, overflow menu. The current
/// track's title takes the accent color, Samsung-style.
class TrackRow extends StatelessWidget {
  final CnestFile file;
  final VoidCallback onTap;
  final List<PopupMenuEntry<String>> Function(BuildContext)? menuBuilder;
  final ValueChanged<String>? onMenuSelected;

  const TrackRow({
    super.key,
    required this.file,
    required this.onTap,
    this.menuBuilder,
    this.onMenuSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: AudioPlayerService(),
      builder: (context, _) {
        final isCurrent = AudioPlayerService().current?.id == file.id;
        return InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const TrackArt(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AudioPlayerService.displayTitle(file),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent ? cs.primary : cs.onSurface,
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Unknown',
                        style: TextStyle(
                          color: cs.onSurface.withAlpha(120),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (menuBuilder != null)
                  PopupMenuButton<String>(
                    icon: ThemeIcon(
                      'dotsThreeVertical',
                      size: 20,
                      color: cs.onSurface.withAlpha(120),
                    ),
                    itemBuilder: menuBuilder!,
                    onSelected: onMenuSelected,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The persistent bottom bar: art disc, title, prev/play/next. Tapping the
/// text area opens the fullscreen Now Playing sheet. Hidden while nothing
/// has ever been queued.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final service = AudioPlayerService();
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final current = service.current;
        if (current == null) return const SizedBox.shrink();
        return SafeArea(
          top: false,
          child: Container(
            margin: const EdgeInsets.fromLTRB(10, 4, 10, 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(t.rPill),
              border: Border.all(color: cs.outline.withAlpha(90)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 4),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: ThemeIcon(
                      'musicNote',
                      size: 18,
                      color: cs.onSurface.withAlpha(160),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => NowPlayingScreen.open(context),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AudioPlayerService.displayTitle(current),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurface,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'Unknown',
                          style: TextStyle(
                            color: cs.onSurface.withAlpha(120),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: ThemeIcon('skipBack', selected: true, size: 20),
                  onPressed: service.previous,
                ),
                StreamBuilder<PlayerState>(
                  stream: service.player.playerStateStream,
                  builder: (context, snap) {
                    final playing = snap.data?.playing ?? false;
                    final processing = snap.data?.processingState;
                    if (processing == ProcessingState.loading ||
                        processing == ProcessingState.buffering) {
                      return SizedBox(
                        width: 40,
                        height: 40,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: cs.primary,
                          ),
                        ),
                      );
                    }
                    return IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: ThemeIcon(
                        playing ? 'pause' : 'play',
                        selected: true,
                        size: 24,
                      ),
                      onPressed: service.toggle,
                    );
                  },
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: ThemeIcon('skipForward', selected: true, size: 20),
                  onPressed: service.next,
                ),
                const SizedBox(width: 2),
              ],
            ),
          ),
        );
      },
    );
  }
}
