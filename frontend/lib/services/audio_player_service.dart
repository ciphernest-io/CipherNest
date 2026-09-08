import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'encryption_service.dart';
import 'video_streaming_server.dart';

/// App-wide music player. One instance owns the [AudioPlayer], the queue,
/// and the media session, so playback survives navigation and keeps running
/// in the background (just_audio_background drives the lock-screen
/// notification and hardware buttons).
///
/// Zero-knowledge posture: tracks decrypt into the app's private temp cache
/// on first play ([_VaultAudioSource]); nothing plaintext ever leaves the
/// sandbox. What the OS media session gets to display is gated by the
/// lock-screen title setting.
class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal() {
    // Re-emit player state as ChangeNotifier ticks so plain widgets can
    // listen without wiring five separate streams.
    _player.currentIndexStream.listen((_) => notifyListeners());
    _player.playingStream.listen((_) => notifyListeners());
    _player.processingStateStream.listen((_) => notifyListeners());
    _player.shuffleModeEnabledStream.listen((_) => notifyListeners());
    _player.loopModeStream.listen((_) => notifyListeners());
    _loadLockScreenPref();
  }

  static const String prefsKeyLockScreenTitles = 'audio_lockscreen_titles';

  final AudioPlayer _player = AudioPlayer();
  List<CnestFile> _queue = [];
  String? _queueSourceName;
  bool _showTitlesOnLockScreen = true;

  AudioPlayer get player => _player;
  List<CnestFile> get queue => List.unmodifiable(_queue);
  String? get queueSourceName => _queueSourceName;
  bool get hasQueue => _queue.isNotEmpty;
  bool get playing => _player.playing;
  bool get shuffleEnabled => _player.shuffleModeEnabled;
  LoopMode get loopMode => _player.loopMode;
  bool get showTitlesOnLockScreen => _showTitlesOnLockScreen;

  /// The track under the playhead, or null when no queue is loaded.
  CnestFile? get current {
    final i = _player.currentIndex;
    if (i == null || i < 0 || i >= _queue.length) return null;
    return _queue[i];
  }

  /// Filename without its extension — what Samsung Music shows when a track
  /// has no ID3 title.
  static String displayTitle(CnestFile file) {
    final name = file.filename;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  Future<void> _loadLockScreenPref() async {
    final prefs = await SharedPreferences.getInstance();
    _showTitlesOnLockScreen = prefs.getBool(prefsKeyLockScreenTitles) ?? true;
  }

  /// Toggle whether the media notification shows real track titles or a
  /// generic label. Applies from the next [playQueue] on — the media session
  /// tags of an already-loaded queue are immutable.
  Future<void> setShowTitlesOnLockScreen(bool value) async {
    _showTitlesOnLockScreen = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKeyLockScreenTitles, value);
    notifyListeners();
  }

  MediaItem _mediaItemFor(CnestFile file, {Uri? artUri}) {
    return MediaItem(
      id: file.id,
      title: _showTitlesOnLockScreen ? displayTitle(file) : 'CipherNest Audio',
      artist: _showTitlesOnLockScreen ? 'Unknown' : null,
      album: _showTitlesOnLockScreen ? _queueSourceName : null,
      artUri: artUri,
    );
  }

  /// Lock-screen album art. GATED on the same privacy flag as the titles —
  /// a picture would defeat the "generic label" setting. Reuses the SHARED
  /// thumb cache file (`thumb_<cloudId>.jpg`, app-private temp — the exact
  /// artifact DocThumbnail writes), so one decrypt serves the UI and the
  /// media session and the cache GC already knows the name. Null on any
  /// failure/offline: the placeholder is fine.
  ///
  /// [allowDownload] is true ONLY for the track playback starts on:
  /// resolving art for the WHOLE queue used to fire one download+decrypt
  /// per track before setAudioSource, so tapping one song in a large
  /// library sat silent behind N network round trips (and offline, behind
  /// N timeouts). Other tracks get cached-art-or-placeholder.
  Future<Uri?> _artUriFor(CnestFile file, {required bool allowDownload}) async {
    if (!_showTitlesOnLockScreen) return null;
    final thumbId = file.thumbnailCloudId;
    if (thumbId == null || file.cloudId == null) return null;
    try {
      final dir = await getTemporaryDirectory();
      final cacheFile = File('${dir.path}/thumb_${file.cloudId}.jpg');
      if (!await cacheFile.exists()) {
        if (!allowDownload) return null;
        final enc = await CloudService().downloadFile(thumbId);
        final dec = await EncryptionService.decryptFile(enc);
        await cacheFile.writeAsBytes(dec);
      }
      return Uri.file(cacheFile.path);
    } catch (_) {
      return null;
    }
  }

  /// The playable source for one track, cheapest first:
  ///   1. the device original (localPath),
  ///   2. a previously decrypted copy in the private audio cache,
  ///   3. progressive streaming through the loopback proxy — it fetches and
  ///      decrypts cloud chunks on demand, so playback starts in ~a second
  ///      instead of after a full download (which is also what made the
  ///      player time out before the first byte arrived).
  ///
  /// Art is resolved HERE (awaited) because media-session tags are
  /// immutable once the queue loads.
  Future<AudioSource> _sourceFor(CnestFile file,
      {bool artDownload = false}) async {
    final tag = _mediaItemFor(file,
        artUri: await _artUriFor(file, allowDownload: artDownload));
    if (file.localPath != null) {
      final local = File(file.localPath!);
      if (await local.exists()) {
        return AudioSource.file(local.path, tag: tag);
      }
    }
    final dir = await getTemporaryDirectory();
    final cached = File('${dir.path}/${file.id}_audio.bin');
    if (await cached.exists()) {
      return AudioSource.file(cached.path, tag: tag);
    }
    if (file.cloudId != null) {
      // Progressive streaming through the loopback proxy: the first byte
      // arrives in ~a second so playback starts effectively instantly, and
      // the proxy writes every decrypted chunk it serves to its on-disk
      // cache (video_<cloudId>.plain) AND prefetches ahead, so by the end of
      // the track the whole file is cached — a replay or a later tap then
      // plays entirely from disk with zero network. This is why tapping a
      // song no longer waits on a full download+decrypt first.
      final url = await VideoStreamingServer().urlFor(file);
      return AudioSource.uri(Uri.parse(url), tag: tag);
    }
    // No local copy and never uploaded — point at the (missing) cache path
    // so this ITEM errors when reached instead of failing the whole queue.
    return AudioSource.file(cached.path, tag: tag);
  }

  void _endCloudSessions() {
    for (final f in _queue) {
      if (f.cloudId != null) VideoStreamingServer().endSession(f.id);
    }
  }

  /// Replace the queue with [tracks] and start playing at [startIndex].
  /// [sourceName] labels where the queue came from (playlist name, "Tracks")
  /// for the now-playing screen.
  Future<void> playQueue(
    List<CnestFile> tracks, {
    int startIndex = 0,
    String? sourceName,
  }) async {
    if (tracks.isEmpty) return;
    _endCloudSessions();
    _queue = List.of(tracks);
    _queueSourceName = sourceName;
    final start = startIndex.clamp(0, _queue.length - 1);
    final sources = await Future.wait([
      for (var i = 0; i < _queue.length; i++)
        _sourceFor(_queue[i], artDownload: i == start),
    ]);
    final playlist = ConcatenatingAudioSource(children: sources);
    await _player.setAudioSource(
      playlist,
      initialIndex: start,
    );
    unawaited(_player.play());
    notifyListeners();
  }

  /// Play/pause toggle for the current track.
  Future<void> toggle() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      // Replay from the top if the queue ran to completion.
      if (_player.processingState == ProcessingState.completed) {
        await _player.seek(Duration.zero, index: 0);
      }
      unawaited(_player.play());
    }
  }

  /// The queue's play order: shuffle order while shuffling, natural order
  /// otherwise. Manual skip steps through THIS so it always moves one track
  /// and wraps the ends — independent of loop mode. (just_audio's own
  /// seekToNext/seekToPrevious bake loop mode in: under LoopMode.one they
  /// replay the same track, and under LoopMode.off they dead-end at the
  /// queue's edges instead of wrapping — both of which the buttons should
  /// never do.)
  List<int> get _playOrder {
    final n = _queue.length;
    if (_player.shuffleModeEnabled) {
      final s = _player.shuffleIndices;
      if (s != null && s.length == n) return s;
    }
    return [for (var i = 0; i < n; i++) i];
  }

  Future<void> _skipTo(int actualIndex) async {
    // Preserve intent: keep playing if we were, and resume if the queue had
    // run to completion (LoopMode.off past the last track).
    final resume =
        _player.playing || _player.processingState == ProcessingState.completed;
    await _player.seek(Duration.zero, index: actualIndex);
    if (resume && !_player.playing) unawaited(_player.play());
  }

  /// Manual next: always advances one track, wrapping the last back to the
  /// first, whatever the loop mode.
  Future<void> next() async {
    final order = _playOrder;
    if (order.isEmpty) return;
    var pos = order.indexOf(_player.currentIndex ?? order.first);
    if (pos < 0) pos = 0;
    await _skipTo(order[(pos + 1) % order.length]);
  }

  /// Manual previous. With [allowRestart] (the transport BUTTON), Samsung
  /// behavior: past the first few seconds it restarts the current track;
  /// near the start it steps back a track. SWIPING passes false so it always
  /// changes track — a swipe should never just rewind the current song.
  /// Either way it wraps the first back to the last.
  Future<void> previous({bool allowRestart = true}) async {
    final order = _playOrder;
    if (order.isEmpty) return;
    if (allowRestart && _player.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      return;
    }
    var pos = order.indexOf(_player.currentIndex ?? order.first);
    if (pos < 0) pos = 0;
    await _skipTo(order[(pos - 1 + order.length) % order.length]);
  }

  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> toggleShuffle() async {
    final enable = !_player.shuffleModeEnabled;
    if (enable) await _player.shuffle();
    await _player.setShuffleModeEnabled(enable);
  }

  /// off → all → one → off, mirroring Samsung's repeat button.
  Future<void> cycleRepeat() async {
    final next = switch (_player.loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    await _player.setLoopMode(next);
  }

  /// Stop playback and drop the queue (also dismisses the media session).
  Future<void> stop() async {
    await _player.stop();
    _endCloudSessions();
    _queue = [];
    _queueSourceName = null;
    notifyListeners();
  }

  /// Called when a file is deleted from the vault: stop if it's the current
  /// track, otherwise just forget it so the queue can't navigate onto it.
  Future<void> ejectFile(String fileId) async {
    VideoStreamingServer().endSession(fileId);
    if (_queue.isEmpty) return;
    if (current?.id == fileId) {
      await stop();
      return;
    }
    final index = _queue.indexWhere((f) => f.id == fileId);
    if (index < 0) return;
    _queue.removeAt(index);
    final source = _player.audioSource;
    if (source is ConcatenatingAudioSource && index < source.length) {
      await source.removeAt(index);
    }
    notifyListeners();
  }

  /// Keep the in-queue copy in sync after a favorite toggle or rename so the
  /// now-playing UI doesn't show stale state.
  void updateFile(CnestFile updated) {
    final index = _queue.indexWhere((f) => f.id == updated.id);
    if (index < 0) return;
    _queue[index] = updated;
    notifyListeners();
  }
}

