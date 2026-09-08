import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';

/// Per-video streaming session state. Created on `beginSession`, lives until
/// `endSession`. Caches the (decrypted) file key + sizes so we don't re-derive
/// them for every range request.
class _StreamingSession {
  final CnestFile file;
  final SecretKey fileKey;
  final Uint8List contentId;
  final int plaintextSize;
  final int encryptedSize;
  final int totalChunks;
  final int lastChunkEncryptedSize;

  /// On-disk plaintext chunk cache. Chunks are written at their exact
  /// plaintext offset as they arrive, so any cached chunk is served without
  /// a network round-trip — replays, seek-backs, and overlapping requests
  /// cost nothing. Lives in the temp dir under the cache manager's LRU
  /// sweep (priority 1: large plaintext, evicted first) and is wiped by
  /// aggressive-delete via CacheManagerService.invalidateFile.
  final File cacheFile;

  /// Sidecar written once every chunk is on disk. Its presence lets the
  /// NEXT session for this video play entirely from disk, zero network.
  final File completeMarker;

  /// Sidecar chunk index (`.idx`): which chunks the cache file actually
  /// holds, persisted as the cache grows. This is what lets a PARTIAL cache
  /// survive across sessions — before it existed, anything short of a
  /// fully-watched video was truncated and re-downloaded on every open.
  final File idxFile;

  RandomAccessFile? writeHandle;
  final Set<int> cachedChunks = {};
  bool complete;

  /// Serializes downloads + cache writes across player requests and the
  /// prefetcher so overlapping ranges are never downloaded twice.
  Future<void> _fetchQueue = Future.value();

  _StreamingSession({
    required this.file,
    required this.fileKey,
    required this.contentId,
    required this.plaintextSize,
    required this.encryptedSize,
    required this.totalChunks,
    required this.lastChunkEncryptedSize,
    required this.cacheFile,
    required this.completeMarker,
    required this.idxFile,
    required this.complete,
  });

  bool hasChunk(int chunkIndex) =>
      complete || cachedChunks.contains(chunkIndex);

  Future<T> enqueue<T>(Future<T> Function() action) {
    final run = _fetchQueue.then((_) => action());
    _fetchQueue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> dispose() async {
    try {
      await writeHandle?.close();
    } catch (_) {}
    writeHandle = null;
  }

  /// Encrypted byte offset where chunk [chunkIndex] starts (0-based). The
  /// body's 20-byte preamble (content_id + total_chunks) sits between the
  /// header and chunk 0, so it's part of every chunk's base offset.
  int chunkEncryptedStart(int chunkIndex) {
    return EncryptionService.headerSize +
        EncryptionService.bodyPreambleSize +
        chunkIndex * EncryptionService.encryptedChunkSize;
  }

  /// Encrypted byte size of chunk [chunkIndex] (handles last partial chunk).
  int chunkEncryptedSize(int chunkIndex) {
    if (chunkIndex == totalChunks - 1) return lastChunkEncryptedSize;
    return EncryptionService.encryptedChunkSize;
  }
}

/// Loopback HTTP server that translates plaintext byte ranges into
/// (download encrypted chunks → decrypt → slice) for the video player.
class VideoStreamingServer {
  static final VideoStreamingServer _instance = VideoStreamingServer._internal();
  factory VideoStreamingServer() => _instance;
  VideoStreamingServer._internal();

  HttpServer? _server;
  int? _port;
  final Map<String, _StreamingSession> _sessions = {};

  /// True while any video streaming session is open — used by the auto-lock
  /// service to defer locking during playback.
  bool get hasActiveSessions => _sessions.isNotEmpty;

  /// Maximum plaintext bytes returned in a single HTTP response, regardless
  /// of how much the client requested. When ExoPlayer opens the URL it sends
  /// `Range: bytes=0-`, which the pre-fix code interpreted as "download the
  /// entire remaining file, decrypt it, then respond." For a 100 MB video on
  /// a typical mobile connection that's 10+ seconds of wall-clock silence,
  /// well beyond the player's initial-response timeout — hence the "video
  /// loads for ages, then errors out" symptom.
  ///
  /// Capping to 2 MB (4 × 512 KB chunks) means the first response arrives
  /// in ~200 ms on a 10 MB/s link. HTTP allows the server to reply with a
  /// smaller range than requested via `Content-Range: bytes X-Y/total`; the
  /// player just issues follow-up range requests as it plays — which is
  /// exactly how chunked streaming is supposed to work.
  static const int _maxResponseBytes = 4 * EncryptionService.plaintextChunkSize;

  /// How many chunks the server keeps fetched AHEAD of the last-served
  /// position (~4 MB). Without read-ahead the pipeline is purely reactive:
  /// the player drains its buffer, asks for the next slice, and only then
  /// does a cloud round-trip start — a visible freeze every ~2 MB of video.
  /// With it, the player's next request is almost always a disk-cache hit.
  static const int _prefetchChunks = 8;

  /// Starts the server (idempotent). Returns the bound port.
  Future<int> start() async {
    if (_server != null && _port != null) return _port!;

    final handler = const Pipeline().addHandler(_route);
    _server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0, // OS picks free port
    );
    _port = _server!.port;
    debugPrint('VideoStreamingServer listening on 127.0.0.1:$_port');
    return _port!;
  }

  /// Tears down the server (e.g. on app shutdown). Rarely needed.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
    for (final session in _sessions.values) {
      await session.dispose();
    }
    _sessions.clear();
  }

  /// Prepares streaming for [file]: downloads the header, decrypts the file
  /// key with the master key, caches sizes. Returns the localhost URL the
  /// video player should connect to.
  Future<String> beginSession(CnestFile file) async {
    final port = await start();
    await _openSession(file);
    return 'http://127.0.0.1:$port/${file.id}';
  }

  /// URL for [file] WITHOUT opening a session — the session is created
  /// lazily by [_route] on the first request. This is how the music queue
  /// can hold hundreds of cloud tracks without hundreds of header fetches.
  Future<String> urlFor(CnestFile file) async {
    final port = await start();
    return 'http://127.0.0.1:$port/${file.id}';
  }

  Future<_StreamingSession> _openSession(CnestFile file) async {
    if (file.cloudId == null) {
      throw Exception('File has no cloud_id, cannot stream');
    }

    final plaintextSize = file.sizeBytes;
    final encryptedSize = EncryptionService.calculateEncryptedSize(plaintextSize);
    final totalChunks = (plaintextSize / EncryptionService.plaintextChunkSize).ceil();

    // Last chunk may be smaller than the standard 524316.
    final lastPlaintextChunkSize =
        plaintextSize - (totalChunks - 1) * EncryptionService.plaintextChunkSize;
    final lastChunkEncryptedSize = lastPlaintextChunkSize +
        (EncryptionService.encryptedChunkSize - EncryptionService.plaintextChunkSize);
    // (plaintext + 28 overhead)

    // Download the header + body preamble in one shot: the header yields the
    // file key (HPKE open) and the 20-byte preamble yields content_id +
    // total_chunks, both needed to build each chunk's AAD.
    final prefixLen =
        EncryptionService.headerSize + EncryptionService.bodyPreambleSize;
    final headerStart = DateTime.now();
    final prefixBytes = await CloudService().downloadRange(
      file.cloudId!,
      0,
      prefixLen - 1,
    );
    final headerElapsed = DateTime.now().difference(headerStart).inMilliseconds;
    debugPrint(
      'VideoStreamingServer beginSession ${file.id}: '
      'header fetched in ${headerElapsed}ms '
      '(${plaintextSize ~/ 1024 ~/ 1024} MB video, $totalChunks chunks)',
    );
    final fileKey =
        await EncryptionService.decryptFileKeyFromHeader(prefixBytes);
    final (contentId, _) = EncryptionService.readBodyPreamble(
      prefixBytes.sublist(EncryptionService.headerSize),
    );

    // Disk cache: a `.done` marker from an earlier session means the whole
    // plaintext is already on disk — playback needs zero network. A marker
    // whose cache file was evicted (LRU sweep) is stale; discard it.
    final tempDir = await getTemporaryDirectory();
    final cacheFile = File('${tempDir.path}/video_${file.cloudId}.plain');
    final completeMarker = File('${cacheFile.path}.done');
    final idxFile = File('${cacheFile.path}.idx');
    bool complete = false;
    if (await completeMarker.exists()) {
      if (await cacheFile.exists() &&
          await cacheFile.length() == plaintextSize) {
        complete = true;
      } else {
        try {
          await completeMarker.delete();
        } catch (_) {}
      }
    }

    // Partial-cache resume: the `.idx` sidecar says which chunks the cache
    // file already holds. Validated hard (version, size, chunk bounds vs
    // the actual file length) — anything off means the pair is untrusted
    // and we start fresh, exactly like the pre-idx behavior.
    var seededChunks = const <int>{};
    if (!complete && await idxFile.exists() && await cacheFile.exists()) {
      try {
        final decoded = decodeChunkIndex(
          await idxFile.readAsString(),
          expectedSize: plaintextSize,
          totalChunks: totalChunks,
        );
        if (decoded != null && decoded.isNotEmpty) {
          final cacheLen = await cacheFile.length();
          final maxChunk = decoded.reduce(math.max);
          final maxEnd = math.min(
            (maxChunk + 1) * EncryptionService.plaintextChunkSize,
            plaintextSize,
          );
          if (maxEnd <= cacheLen) seededChunks = decoded;
        }
      } catch (_) {
        // Unreadable idx → fresh start below.
      }
    }

    final session = _StreamingSession(
      file: file,
      fileKey: fileKey,
      contentId: contentId,
      plaintextSize: plaintextSize,
      encryptedSize: encryptedSize,
      totalChunks: totalChunks,
      lastChunkEncryptedSize: lastChunkEncryptedSize,
      cacheFile: cacheFile,
      completeMarker: completeMarker,
      idxFile: idxFile,
      complete: complete,
    );
    if (!complete) {
      if (seededChunks.isEmpty) {
        // FileMode.write truncates — correct for an untrusted/absent cache.
        session.writeHandle = await cacheFile.open(mode: FileMode.write);
        try {
          if (await idxFile.exists()) await idxFile.delete();
        } catch (_) {}
      } else {
        // Trusted partial cache: open WITHOUT truncating. Dart's append
        // mode is fully seekable — _ensureChunks setPositions every write —
        // it just doesn't wipe the bytes already there.
        session.writeHandle = await cacheFile.open(mode: FileMode.append);
        session.cachedChunks.addAll(seededChunks);
        debugPrint(
          'VideoStreamingServer: resumed ${seededChunks.length}/'
          '$totalChunks cached chunks for ${file.id}',
        );
      }
    }

    await _sessions[file.id]?.dispose();
    _sessions[file.id] = session;

    // Warm the pipeline — the player's first request is always `bytes=0-`.
    // Skip it for AUDIO: that path streams the whole file continuously and
    // drives its own per-chunk read-ahead, so an 8-chunk warmup here would
    // only queue AHEAD of the first read and delay the first byte (for a
    // small song, it would fetch the entire file before playback starts).
    final isAudio =
        _contentTypeForFilename(file.filename).startsWith('audio/');
    if (!isAudio) {
      unawaited(
        _ensureChunks(session, 0, math.min(_prefetchChunks, totalChunks) - 1)
            .catchError((e) => debugPrint('VideoStreamingServer warmup: $e')),
      );
    }

    return session;
  }

  /// In-flight lazy opens, so parallel range requests for the same file
  /// don't fetch the header twice.
  final Map<String, Future<_StreamingSession?>> _lazyOpens = {};

  /// Session for [fileId], creating one on demand from the vault DB — used
  /// by URLs minted with [urlFor] where no beginSession ever ran.
  Future<_StreamingSession?> _sessionFor(String fileId) {
    final existing = _sessions[fileId];
    if (existing != null) return Future.value(existing);
    return _lazyOpens.putIfAbsent(fileId, () async {
      try {
        final file = await DatabaseService().getFileById(fileId);
        if (file == null || file.cloudId == null) return null;
        return await _openSession(file);
      } catch (e) {
        debugPrint('VideoStreamingServer lazy open $fileId failed: $e');
        return null;
      } finally {
        // The result is in _sessions now (or failed) — clear the gate so a
        // later retry can attempt a fresh open.
        _lazyOpens.remove(fileId);
      }
    });
  }

  /// Drops the cached file key for a session. Call from dispose(). The disk
  /// cache is intentionally left behind — that's what makes replays instant.
  void endSession(String fileId) {
    final session = _sessions.remove(fileId);
    if (session != null) unawaited(session.dispose());
  }

  // ---------------------------------------------------------------------------
  // Request handler
  // ---------------------------------------------------------------------------

  Future<Response> _route(Request request) async {
    if (request.method != 'GET' && request.method != 'HEAD') {
      return Response(405);
    }
    // Path is /<file_id>
    final fileId = request.url.path;
    final session = await _sessionFor(fileId);
    if (session == null) {
      return Response.notFound('No active session for $fileId');
    }

    final total = session.plaintextSize;
    final rangeHeader = request.headers['range'];
    int rangeStart = 0;
    int rangeEnd = total - 1;
    bool isPartial = false;

    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring(6);
      final parts = spec.split('-');
      if (parts.length == 2) {
        rangeStart = int.tryParse(parts[0]) ?? 0;
        if (parts[1].isNotEmpty) {
          rangeEnd = int.tryParse(parts[1]) ?? (total - 1);
        }
        isPartial = true;
      }
    }

    // Clamp
    if (rangeStart < 0) rangeStart = 0;
    if (rangeEnd >= total) rangeEnd = total - 1;
    if (rangeStart > rangeEnd) {
      return Response(
        416,
        headers: {'Content-Range': 'bytes */$total'},
      );
    }

    // AUDIO: serve the WHOLE remaining range as one continuous, decrypt-on-
    // the-fly stream instead of a capped slice. The capped-range path made
    // ExoPlayer stop a track short and skip to the next song: a header-based
    // duration estimate (VBR mp3 with no Xing header) plus a response that
    // ends before the file does reads as end-of-track. A single streamed
    // response is consumed to the file's TRUE EOF, so the song plays out and
    // the queue only advances when it actually finishes. Playback still
    // starts in ~a second (bytes flow as they decrypt) and range-seeks still
    // work (rangeStart is honored; a seek just opens a fresh stream from X).
    final contentType = _contentTypeForFilename(session.file.filename);
    if (contentType.startsWith('audio/')) {
      rangeEnd = total - 1;
      final headers = <String, String>{
        'Content-Type': contentType,
        'Accept-Ranges': 'bytes',
        'Content-Length': '${rangeEnd - rangeStart + 1}',
        if (rangeHeader != null)
          'Content-Range': 'bytes $rangeStart-$rangeEnd/$total',
      };
      final status = rangeHeader != null ? 206 : 200;
      if (request.method == 'HEAD') return Response(status, headers: headers);
      return Response(status,
          body: _audioStream(session, rangeStart, rangeEnd), headers: headers);
    }

    // Cap the response size. HTTP allows the server to return less than the
    // requested range — the client follows up with more range requests as it
    // needs more bytes. Without this, ExoPlayer's initial `bytes=0-` request
    // triggers a full-file download-and-decrypt before the first byte lands.
    final requestedLen = rangeEnd - rangeStart + 1;
    if (requestedLen > _maxResponseBytes) {
      rangeEnd = rangeStart + _maxResponseBytes - 1;
      isPartial = true;
    }

    final headers = <String, String>{
      'Content-Type': _contentTypeForFilename(session.file.filename),
      'Accept-Ranges': 'bytes',
      'Content-Length': '${rangeEnd - rangeStart + 1}',
    };
    if (isPartial) {
      headers['Content-Range'] = 'bytes $rangeStart-$rangeEnd/$total';
    }

    if (request.method == 'HEAD') {
      return Response(isPartial ? 206 : 200, headers: headers);
    }

    final started = DateTime.now();
    try {
      final bytes = await _serveRange(session, rangeStart, rangeEnd);
      final elapsed = DateTime.now().difference(started).inMilliseconds;
      debugPrint(
        'VideoStreamingServer served $fileId bytes $rangeStart-$rangeEnd '
        '(${bytes.length} B) in ${elapsed}ms',
      );

      // Read-ahead: keep the cache _prefetchChunks ahead of playback so the
      // player's next request lands on disk instead of on the network.
      final lastServedChunk =
          rangeEnd ~/ EncryptionService.plaintextChunkSize;
      final prefetchEnd =
          math.min(lastServedChunk + _prefetchChunks, session.totalChunks - 1);
      if (prefetchEnd > lastServedChunk) {
        unawaited(
          _ensureChunks(session, lastServedChunk + 1, prefetchEnd).catchError(
            (e) => debugPrint('VideoStreamingServer prefetch: $e'),
          ),
        );
      }

      return Response(
        isPartial ? 206 : 200,
        body: bytes,
        headers: headers,
      );
    } catch (e, st) {
      debugPrint('VideoStreamingServer range error for $fileId '
          'bytes $rangeStart-$rangeEnd: $e\n$st');
      return Response.internalServerError(body: 'Range fetch failed: $e');
    }
  }

  /// Best-effort MIME type from filename extension. Serving `video/mp4` for
  /// every video (as the pre-fix code did) confuses ExoPlayer when the
  /// underlying container is actually `.mov`, `.mkv`, or `.webm` — the parser
  /// sees the wrong magic bytes at offset 0 and gives up.
  String _contentTypeForFilename(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case 'avi':
        return 'video/x-msvideo';
      case '3gp':
        return 'video/3gpp';
      // Audio — the same pipeline streams the music player's cloud tracks.
      case 'mp3':
        return 'audio/mpeg';
      case 'm4a':
      case 'aac':
        return 'audio/mp4';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'wma':
        return 'audio/x-ms-wma';
      default:
        // Unknown extension — let the player sniff. `application/octet-stream`
        // is safer than misidentifying as mp4.
        return 'application/octet-stream';
    }
  }

  /// Serves a plaintext range from the disk cache, first making sure every
  /// chunk covering it has been fetched + decrypted + written.
  Future<Uint8List> _serveRange(
    _StreamingSession session,
    int pStart,
    int pEnd,
  ) async {
    final chunkSize = EncryptionService.plaintextChunkSize;
    final firstChunk = pStart ~/ chunkSize;
    final lastChunk = pEnd ~/ chunkSize;

    await _ensureChunks(session, firstChunk, lastChunk);

    final raf = await session.cacheFile.open(mode: FileMode.read);
    try {
      await raf.setPosition(pStart);
      final bytes = await raf.read(pEnd - pStart + 1);
      if (bytes.length != pEnd - pStart + 1) {
        throw Exception(
          'Cache short-read: got ${bytes.length} of ${pEnd - pStart + 1}',
        );
      }
      return bytes;
    } finally {
      await raf.close();
    }
  }

  /// Streams plaintext [pStart]..[pEnd] chunk by chunk, ensuring each chunk
  /// (plus a small read-ahead) is fetched + decrypted + on disk before it is
  /// read. Yields bytes as they become available so the audio player starts
  /// almost immediately and reads a single continuous body to EOF.
  Stream<List<int>> _audioStream(
    _StreamingSession session,
    int pStart,
    int pEnd,
  ) async* {
    final chunkSize = EncryptionService.plaintextChunkSize;
    final raf = await session.cacheFile.open(mode: FileMode.read);
    try {
      var pos = pStart;
      while (pos <= pEnd) {
        final chunkIdx = pos ~/ chunkSize;
        // Await ONLY the chunk under the read cursor (fast first byte), and
        // fire the read-ahead in the background so decryption stays ahead of
        // playback without blocking the first yield on a big batch.
        await _ensureChunks(session, chunkIdx, chunkIdx);
        final ahead =
            math.min(chunkIdx + _prefetchChunks, session.totalChunks - 1);
        if (ahead > chunkIdx) {
          unawaited(_ensureChunks(session, chunkIdx + 1, ahead)
              .catchError((e) => debugPrint('audio read-ahead: $e')));
        }
        final sliceEnd =
            math.min(chunkIdx * chunkSize + chunkSize - 1, pEnd);
        await raf.setPosition(pos);
        final bytes = await raf.read(sliceEnd - pos + 1);
        if (bytes.isEmpty) break; // defensive: never spin on a short read
        yield bytes;
        pos += bytes.length;
      }
    } finally {
      await raf.close();
    }
  }

  /// Downloads, decrypts, and persists every not-yet-cached chunk in
  /// [first]..[last]. Serialized per session so concurrent player requests
  /// and the prefetcher never download the same chunk twice. Contiguous
  /// missing chunks are fetched as one cloud range request.
  Future<void> _ensureChunks(_StreamingSession session, int first, int last) {
    if (first > last) return Future.value();
    return session.enqueue(() async {
      // Collect contiguous runs of missing chunks.
      final runs = <List<int>>[];
      int? runStart;
      for (int i = first; i <= last; i++) {
        if (session.hasChunk(i)) {
          if (runStart != null) {
            runs.add([runStart, i - 1]);
            runStart = null;
          }
        } else {
          runStart ??= i;
        }
      }
      if (runStart != null) runs.add([runStart, last]);
      if (runs.isEmpty) return;

      final raf = session.writeHandle;
      if (raf == null) return; // complete cache — nothing can be missing

      for (final run in runs) {
        final runFirst = run[0];
        final runLast = run[1];
        final encryptedStart = session.chunkEncryptedStart(runFirst);
        final encryptedEnd = session.chunkEncryptedStart(runLast) +
            session.chunkEncryptedSize(runLast) -
            1;

        final encryptedBytes = await CloudService().downloadRange(
          session.file.cloudId!,
          encryptedStart,
          encryptedEnd,
        );

        final lastChunkEncSize = (runLast == session.totalChunks - 1)
            ? session.lastChunkEncryptedSize
            : null;

        final plaintext = await EncryptionService.decryptChunkRange(
          encryptedBytes,
          session.fileKey,
          runLast - runFirst + 1,
          contentId: session.contentId,
          totalChunks: session.totalChunks,
          startIndex: runFirst,
          lastChunkEncryptedSize: lastChunkEncSize,
        );

        await raf.setPosition(runFirst * EncryptionService.plaintextChunkSize);
        await raf.writeFrom(plaintext);
        for (int i = runFirst; i <= runLast; i++) {
          session.cachedChunks.add(i);
        }
      }
      await raf.flush();

      if (!session.complete &&
          session.cachedChunks.length == session.totalChunks) {
        session.complete = true;
        try {
          await session.completeMarker.writeAsBytes(const []);
          // The idx is subsumed by the `.done` marker.
          if (await session.idxFile.exists()) await session.idxFile.delete();
          debugPrint(
            'VideoStreamingServer: ${session.file.id} fully cached on disk',
          );
        } catch (_) {
          // Marker is an optimization; failing to write it just means the
          // next session re-downloads.
        }
        return;
      }

      // Persist the chunk index after each fetch batch so the NEXT session
      // resumes this partial cache instead of truncating it. Atomic
      // tmp+rename: a torn idx must never validate.
      if (!session.complete) await _writeChunkIndex(session);
    });
  }

  /// Best-effort atomic write of the session's chunk index sidecar.
  Future<void> _writeChunkIndex(_StreamingSession session) async {
    try {
      final tmp = File('${session.idxFile.path}.tmp');
      await tmp.writeAsString(
        encodeChunkIndex(session.cachedChunks, session.plaintextSize),
        flush: true,
      );
      await tmp.rename(session.idxFile.path);
    } catch (e) {
      debugPrint('VideoStreamingServer: idx write failed: $e');
    }
  }

  /// Serializes a cached-chunk set as `{"v":1,"size":N,"chunks":[[a,b],…]}`
  /// (run-length ranges, sorted). Pure — unit-tested.
  @visibleForTesting
  static String encodeChunkIndex(Set<int> chunks, int plaintextSize) {
    final sorted = chunks.toList()..sort();
    final ranges = <List<int>>[];
    for (final c in sorted) {
      if (ranges.isNotEmpty && ranges.last[1] == c - 1) {
        ranges.last[1] = c;
      } else {
        ranges.add([c, c]);
      }
    }
    return jsonEncode({'v': 1, 'size': plaintextSize, 'chunks': ranges});
  }

  /// Parses an idx payload back to a chunk set. Null on ANY mismatch —
  /// wrong version, wrong plaintext size (file changed), malformed ranges,
  /// chunk numbers out of bounds. Null means "do not trust the cache".
  @visibleForTesting
  static Set<int>? decodeChunkIndex(
    String raw, {
    required int expectedSize,
    required int totalChunks,
  }) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      if (decoded['v'] != 1 || decoded['size'] != expectedSize) return null;
      final rawRanges = decoded['chunks'];
      if (rawRanges is! List) return null;
      final out = <int>{};
      for (final r in rawRanges) {
        if (r is! List || r.length != 2) return null;
        final a = r[0];
        final b = r[1];
        if (a is! int || b is! int) return null;
        if (a < 0 || b < a || b >= totalChunks) return null;
        for (int i = a; i <= b; i++) {
          out.add(i);
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }
}
