import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/database_service.dart';
import '../../config/theme_controller.dart';
import '../../models/file_model.dart';
import '../../widgets/doc_thumbnail.dart';
import '../../widgets/theme_icon.dart';
import 'audio_details_screen.dart';
import 'playlist_picker_sheet.dart';

/// Fullscreen player, Samsung Music-style: big art, title block, seek bar,
/// shuffle / prev / play / next / repeat. Slides up from the mini bar.
class NowPlayingScreen extends StatelessWidget {
  const NowPlayingScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (_, _, _) => const NowPlayingScreen(),
        transitionsBuilder: (_, animation, _, child) {
          final curved =
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
          return SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                .animate(curved),
            child: child,
          );
        },
      ),
    );
  }

  Future<void> _toggleFavorite(CnestFile file) async {
    final next = !file.isFavorite;
    await DatabaseService().setFavorite(file.id, next);
    AudioPlayerService().updateFile(CnestFile(
      id: file.id,
      cloudId: file.cloudId,
      thumbnailCloudId: file.thumbnailCloudId,
      provider: file.provider,
      accountId: file.accountId,
      filename: file.filename,
      sizeBytes: file.sizeBytes,
      createdAt: file.createdAt,
      isUploaded: file.isUploaded,
      localPath: file.localPath,
      assetId: file.assetId,
      isFavorite: next,
      type: file.type,
    ));
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString();
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final service = AudioPlayerService();
    final cs = Theme.of(context).colorScheme;
    final t = ThemeController().tokens;

    return Scaffold(
      body: SafeArea(
        child: AnimatedBuilder(
          animation: service,
          builder: (context, _) {
            final current = service.current;
            if (current == null) {
              // Queue evaporated (deleted last track) — nothing to show.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.of(context).maybePop();
              });
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  // --- Top chrome ---
                  Row(
                    children: [
                      IconButton(
                        icon: const ThemeIcon('caretDown'),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      PopupMenuButton<String>(
                        icon: ThemeIcon(
                          'dotsThreeVertical',
                          color: cs.onSurface,
                        ),
                        onSelected: (v) {
                          if (v == 'details') {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    AudioDetailsScreen(file: current),
                              ),
                            );
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'details',
                            child: Text('Details'),
                          ),
                        ],
                      ),
                    ],
                  ),

                  // --- Art ---
                  Expanded(
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: 1,
                        child: DocThumbnail(
                          key: ValueKey('now_${current.id}'),
                          file: current,
                          borderRadius: BorderRadius.circular(t.rCardLg),
                          fallback: Container(
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius:
                                  BorderRadius.circular(t.rCardLg),
                            ),
                            child: Center(
                              child: ThemeIcon(
                                'musicNote',
                                size: 120,
                                color: cs.onSurface.withAlpha(160),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // --- Title block ---
                  Text(
                    AudioPlayerService.displayTitle(current),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    service.queueSourceName == null
                        ? 'Unknown'
                        : 'Unknown · ${service.queueSourceName}',
                    style: TextStyle(
                      color: cs.onSurface.withAlpha(140),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 18),

                  // --- Favorite / add-to-playlist ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: ThemeIcon(
                          'heart',
                          selected: current.isFavorite,
                          color: current.isFavorite ? cs.error : cs.onSurface,
                        ),
                        onPressed: () => _toggleFavorite(current),
                      ),
                      IconButton(
                        icon: const ThemeIcon('plus'),
                        onPressed: () =>
                            PlaylistPickerSheet.show(context, current),
                      ),
                    ],
                  ),

                  // --- Seek bar ---
                  StreamBuilder<Duration>(
                    stream: service.player.positionStream,
                    builder: (context, snap) {
                      final pos = snap.data ?? Duration.zero;
                      final total = service.player.duration ?? Duration.zero;
                      final fraction = total.inMilliseconds == 0
                          ? 0.0
                          : pos.inMilliseconds / total.inMilliseconds;
                      return Column(
                        children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 2.5,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 7),
                            ),
                            child: Slider(
                              value: fraction.clamp(0.0, 1.0),
                              onChanged: (v) {
                                if (total.inMilliseconds > 0) {
                                  service.seek(Duration(
                                    milliseconds:
                                        (v * total.inMilliseconds).round(),
                                  ));
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                              children: [
                                Text(_fmt(pos),
                                    style: TextStyle(
                                        color: cs.onSurface.withAlpha(140),
                                        fontSize: 12)),
                                Text(_fmt(total),
                                    style: TextStyle(
                                        color: cs.onSurface.withAlpha(140),
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 10),

                  // --- Transport controls ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        icon: ThemeIcon(
                          'shuffle',
                          color: service.shuffleEnabled
                              ? cs.primary
                              : cs.onSurface.withAlpha(160),
                        ),
                        onPressed: service.toggleShuffle,
                      ),
                      IconButton(
                        iconSize: 36,
                        icon: const ThemeIcon('skipBack',
                            selected: true, size: 36),
                        onPressed: service.previous,
                      ),
                      StreamBuilder<PlayerState>(
                        stream: service.player.playerStateStream,
                        builder: (context, snap) {
                          final playing = snap.data?.playing ?? false;
                          return GestureDetector(
                            onTap: service.toggle,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: cs.primary,
                                shape: BoxShape.circle,
                              ),
                              child: Center(
                                child: ThemeIcon(
                                  playing ? 'pause' : 'play',
                                  selected: true,
                                  size: 34,
                                  color: cs.onPrimary,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        iconSize: 36,
                        icon: const ThemeIcon('skipForward',
                            selected: true, size: 36),
                        onPressed: service.next,
                      ),
                      IconButton(
                        icon: ThemeIcon(
                          service.loopMode == LoopMode.one
                              ? 'repeat_one'
                              : 'repeat',
                          color: service.loopMode != LoopMode.off
                              ? cs.primary
                              : cs.onSurface.withAlpha(160),
                        ),
                        onPressed: service.cycleRepeat,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
