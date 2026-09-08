import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:just_audio/just_audio.dart';

import '../../../services/audio_player_service.dart';
import '../../../services/database_service.dart';
import '../../config/theme_controller.dart';
import '../../models/file_model.dart';
import '../../widgets/doc_thumbnail.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/theme_icon.dart';
import '../share/share_dialog.dart';
import 'audio_details_screen.dart';
import 'music_actions.dart';
import 'playlist_picker_sheet.dart';

/// Fullscreen player, Samsung Music-style: big art, title block, seek bar,
/// shuffle / prev / play / next / repeat. Slides up from the mini bar, and
/// drags back down onto the track list (grab the art and pull down).
class NowPlayingScreen extends StatefulWidget {
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

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  // Downward drag offset while pulling the player back onto the list.
  double _dragDy = 0;
  Offset _dragStart = Offset.zero;
  bool _dragArmed = false;
  // Axis lock: 0 = undecided, 1 = vertical (dismiss), 2 = horizontal (track
  // change). Once the finger passes [_axisLock] the gesture commits to ONE
  // axis for the rest of the touch, so a diagonal swipe can never both pull
  // the screen down and change the track.
  int _axis = 0;

  static const double _axisLock = 12;
  static const double _dismissDistance = 80;
  static const double _swipeDistance = 60; // horizontal → prev/next

  // Raw pointer gestures on the ART/TITLE zone (the top of the screen). A
  // raw Listener (not the gesture arena) is used deliberately: the arena let
  // the Slider grab the first touch of a swipe, so it "took two swipes and
  // nudged the progress bar". Arming ONLY in the upper region keeps the
  // Slider out of it entirely, and raw tracking makes one swipe enough.
  void _onPointerDown(PointerDownEvent e, double bodyHeight) {
    _dragArmed = e.localPosition.dy < bodyHeight * 0.58;
    _dragStart = e.position;
    _axis = 0;
    if (_dragDy != 0) setState(() => _dragDy = 0);
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_dragArmed) return;
    final dx = e.position.dx - _dragStart.dx;
    final dy = e.position.dy - _dragStart.dy;
    // Commit to an axis once the finger clears the lock threshold, then honor
    // ONLY that axis for the rest of the gesture.
    if (_axis == 0) {
      if (dx.abs() < _axisLock && dy.abs() < _axisLock) return;
      _axis = dy.abs() >= dx.abs() ? 1 : 2;
    }
    // Vertical only pulls the screen down; horizontal never moves it.
    if (_axis == 1) {
      final target = dy > 0 ? dy : 0.0;
      if (target != _dragDy) setState(() => _dragDy = target);
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (!_dragArmed) return;
    _dragArmed = false;
    final d = e.position - _dragStart;
    final axis = _axis;
    _axis = 0;
    // The locked axis alone decides the outcome — the two can never co-fire.
    if (axis == 1) {
      if (d.dy > _dismissDistance) {
        Navigator.of(context).pop();
        return;
      }
    } else if (axis == 2) {
      // Swipe left → next, right → previous. allowRestart:false so a swipe
      // always changes track instead of rewinding the current one first.
      if (d.dx.abs() > _swipeDistance) {
        d.dx < 0
            ? AudioPlayerService().next()
            : AudioPlayerService().previous(allowRestart: false);
      }
    }
    if (mounted) setState(() => _dragDy = 0);
  }

  void _onPointerCancel() {
    _dragArmed = false;
    _axis = 0;
    if (_dragDy != 0 && mounted) setState(() => _dragDy = 0);
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

    // No AppBar here, so the AppBarTheme's overlay style never applies —
    // pin the status-bar icons to the theme (dark icons in light mode, so
    // the clock/battery aren't invisible white on a light background).
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      child: Scaffold(
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
              child: LayoutBuilder(builder: (context, constraints) {
                // Under 400dp of body height is landscape on every phone
                // (portrait is >= 461 even at 320x533): shrink the transport
                // chrome and let the art give way, then scroll if the chrome
                // alone still does not fit. Portrait keeps the design values.
                final compact = constraints.maxHeight < 400;
                final gap = compact ? 8.0 : 24.0;
                final playSize = compact ? 56.0 : 72.0;
                final skipSize = compact ? 28.0 : 36.0;
                final art = Center(
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
                        child: LayoutBuilder(
                          builder: (_, box) => Center(
                            child: ThemeIcon(
                              'musicNote',
                              // 120 whenever the art is >= 300dp wide
                              // (every portrait phone); scales with a
                              // smaller box instead of painting past it.
                              size: math.min(120.0, box.maxWidth * 0.4),
                              color: cs.onSurface.withAlpha(160),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                final column = Column(
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
                        onSelected: (v) => switch (v) {
                          'cover' => setTrackCoverFlow(context, current),
                          'playlist' =>
                            PlaylistPickerSheet.show(context, current),
                          'send' => sendFilesPlain(context, [current]),
                          'share' => ShareDialog.show(context, current),
                          'save' => saveFileToDevice(context, current),
                          'details' => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    AudioDetailsScreen(file: current),
                              ),
                            ),
                          'delete' => deleteTrack(context, current),
                          _ => null,
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'cover', child: Text('Set as cover')),
                          PopupMenuItem(
                              value: 'playlist',
                              child: Text('Add to playlist')),
                          PopupMenuItem(
                              value: 'send', child: Text('Send file')),
                          PopupMenuItem(
                              value: 'share',
                              child: Text('Share secure link')),
                          PopupMenuItem(
                              value: 'save', child: Text('Save to device')),
                          PopupMenuItem(
                              value: 'details', child: Text('Details')),
                          PopupMenuItem(
                              value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ],
                  ),

                  // --- Art ---
                  // Flexible (not Expanded) so the art can shrink to zero
                  // instead of throwing when the chrome needs the height.
                  // Compact: a Stack of only positioned children reports
                  // zero intrinsic height, so the IntrinsicHeight scroll
                  // fallback below sizes the column by its chrome and the
                  // art takes whatever is left (never a width-square art).
                  Flexible(
                    child: compact
                        ? Stack(children: [Positioned.fill(child: art)])
                        : art,
                  ),
                  SizedBox(height: gap),

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
                        iconSize: skipSize,
                        icon: ThemeIcon('skipBack',
                            selected: true, size: skipSize),
                        onPressed: service.previous,
                      ),
                      StreamBuilder<PlayerState>(
                        stream: service.player.playerStateStream,
                        builder: (context, snap) {
                          final playing = snap.data?.playing ?? false;
                          return GestureDetector(
                            onTap: service.toggle,
                            child: Container(
                              width: playSize,
                              height: playSize,
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
                        iconSize: skipSize,
                        icon: ThemeIcon('skipForward',
                            selected: true, size: skipSize),
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
                  SizedBox(height: gap),
                ],
                );
                final body = !compact
                    ? column
                    : SingleChildScrollView(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                              minHeight: constraints.maxHeight),
                          child: IntrinsicHeight(child: column),
                        ),
                      );
                // Portrait: a raw, translucent Listener over the body owns
                // the swipe. It arms only in the upper region (art/title),
                // so the seek bar and transport below keep working normally
                // and a single downward swipe minimizes without touching the
                // Slider; a horizontal swipe on the art changes track.
                final pad = compact
                    ? body
                    : Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (e) =>
                            _onPointerDown(e, constraints.maxHeight),
                        onPointerMove: _onPointerMove,
                        onPointerUp: _onPointerUp,
                        onPointerCancel: (_) => _onPointerCancel(),
                        child: body,
                      );
                if (_dragDy == 0) return pad;
                return Transform.translate(
                  offset: Offset(0, _dragDy),
                  child: Opacity(
                    opacity: (1 - _dragDy / 500).clamp(0.0, 1.0),
                    child: pad,
                  ),
                );
              }),
            );
          },
        ),
      ),
      ),
    );
  }
}
