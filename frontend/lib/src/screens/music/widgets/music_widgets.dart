import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../../widgets/cn_menu_button.dart';
import 'package:just_audio/just_audio.dart';

import '../../../../services/audio_player_service.dart';
import '../../../../services/database_service.dart';
import '../../../config/theme_controller.dart';
import '../../../models/file_model.dart';
import '../../../widgets/doc_thumbnail.dart';
import '../../../widgets/theme_icon.dart';
import '../now_playing_screen.dart';
import '../../../../services/cloud/account_registry.dart';

/// Square track-art tile. Renders the track's embedded cover art (uploaded
/// as its encrypted thumbnail) when [file] carries one; the Samsung-style
/// note-on-grey placeholder otherwise (and for legacy rows uploaded before
/// art extraction).
class TrackArt extends StatelessWidget {
  final double size;
  final double? iconSize;
  final CnestFile? file;
  const TrackArt({super.key, this.size = 48, this.iconSize, this.file});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;
    final placeholder = Container(
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
    final f = file;
    if (f == null || f.thumbnailCloudId == null) return placeholder;
    return DocThumbnail(
      key: ValueKey('art_${f.id}'),
      file: f,
      width: size,
      height: size,
      borderRadius: BorderRadius.circular(t.rIc),
      fallback: placeholder,
    );
  }
}

/// Playlist grid-tile art: renders the playlist's custom cover — a hidden
/// vault image referenced by [coverFileId] — when one is set, otherwise the
/// note-on-grey placeholder. Resolves the cover file lazily by id so the
/// caller only has to pass the album's coverFileId.
class PlaylistCover extends StatefulWidget {
  final String? coverFileId;
  final BorderRadius borderRadius;

  /// When set, a cover file that has gone missing or been deleted clears
  /// itself from this album on the next render, so a removed cover photo
  /// does not linger as a broken reference.
  final String? albumId;
  const PlaylistCover({
    super.key,
    this.coverFileId,
    this.albumId,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  State<PlaylistCover> createState() => _PlaylistCoverState();
}

class _PlaylistCoverState extends State<PlaylistCover> {
  CnestFile? _cover;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(PlaylistCover old) {
    super.didUpdateWidget(old);
    if (old.coverFileId != widget.coverFileId) {
      _cover = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final id = widget.coverFileId;
    if (id == null) return;
    final f = await DatabaseService().getLiveFileById(id);
    // Reconcile: the cover file was deleted (its folder binned, or the user
    // removed it) but the album still points at it. Clear the reference so
    // the placeholder shows and the dangling id is dropped.
    if (f == null && widget.albumId != null) {
      await DatabaseService().setAlbumCover(widget.albumId!, null);
    }
    if (mounted) setState(() => _cover = f);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Center(
      child: ThemeIcon('album',
          size: 56, color: cs.onSurface.withAlpha(170)),
    );
    final c = _cover;
    if (widget.coverFileId == null || c == null) return placeholder;
    return DocThumbnail(
      key: ValueKey('pl_${c.id}'),
      file: c,
      width: double.infinity,
      height: double.infinity,
      borderRadius: widget.borderRadius,
      fallback: placeholder,
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
                TrackArt(file: file),
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
                  CnMenuButton<String>(
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
      animation: Listenable.merge([service, AccountRegistry()]),
      builder: (context, _) {
        final current = service.current;
        if (current == null) return const SizedBox.shrink();
        // Playback belongs to the vault it started in. Switching accounts
        // leaves it running (one player, one notification), but the bar in
        // another account's vault must not show a track that vault does
        // not hold. Playing anything here replaces the queue and stops it.
        final owner = current.accountId;
        final active = AccountRegistry().activeAccount?.id;
        if (owner != null && active != null && owner != active) {
          return const SizedBox.shrink();
        }
        return SafeArea(
          top: false,
          child: Padding(
            // Reduced bottom gap so the taller bar extends DOWNWARD toward the
            // screen edge instead of pushing its top up.
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(t.rPill),
              // Frosted glass: blur + translucent fill so the list scrolls
              // through behind it, instead of an opaque slab on the scaffold.
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(
                  // ~20% taller; symmetric vertical padding keeps the row
                  // (art, text, controls) centered in the taller bar. The bar
                  // grows downward via the reduced outer bottom gap above.
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 11),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh.withValues(alpha: 0.68),
                    borderRadius: BorderRadius.circular(t.rPill),
                    border:
                        Border.all(color: cs.outline.withValues(alpha: 0.30)),
                  ),
                  child: Row(
              children: [
                const SizedBox(width: 4),
                ClipOval(
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: DocThumbnail(
                      key: ValueKey('mini_${current.id}'),
                      file: current,
                      width: 40,
                      height: 40,
                      fallback: Container(
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
              ),
            ),
          ),
        );
      },
    );
  }
}
