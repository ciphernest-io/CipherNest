import 'dart:async';
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

  RandomAccessFile? writeHandle;
  final Set<int> cachedChunks = {};
  bool complete;

  /// Serializes downloads + cache writes across player requests and the
  /// prefetcher so overlapping ranges are never downloaded twice.
  Future<void> _fetchQueue = Future.value();

  _StreamingSession({
    required this.file,
    required this.fileKey,
    required this.plaintextSize,
    required this.encryptedSize,
    required this.totalChunks,
    required this.lastChunkEncryptedSize,
    required this.cacheFile,
    required this.completeMarker,
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

  /// Encrypted byte offset where chunk [chunkIndex] starts (0-based).
  int chunkEncryptedStart(int chunkIndex) {
    return EncryptionService.headerSize + chunkIndex * EncryptionService.encryptedChunkSize;
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

    // Download just the header (64 bytes is enough; we use a slightly larger
    // window to be safe against unusual encrypted-key sizes).
    final headerStart = DateTime.now();
    final headerBytes = await CloudService().downloadRange(
      file.cloudId!,
      0,
      EncryptionService.headerSize - 1,
    );
    final headerElapsed = DateTime.now().difference(headerStart).inMilliseconds;
    debugPrint(
      'VideoStreamingServer beginSession ${file.id}: '
      'header fetched in ${headerElapsed}ms '
      '(${plaintextSize ~/ 1024 ~/ 1024} MB video, $totalChunks chunks)',
    );
    final fileKey = await EncryptionService.decryptFileKeyFromHeader(headerBytes);

    // Disk cache: a `.done` marker from an earlier session means the whole
    // plaintext is already on disk — playback needs zero network. A marker
    // whose cache file was evicted (LRU sweep) is stale; discard it.
    final tempDir = await getTemporaryDirectory();
    final cacheFile = File('${tempDir.path}/video_${file.cloudId}.plain');
    final completeMarker = File('${cacheFile.path}.done');
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

    final session = _StreamingSession(
      file: file,
      fileKey: fileKey,
      plaintextSize: plaintextSize,
      encryptedSize: encryptedSize,
      totalChunks: totalChunks,
      lastChunkEncryptedSize: lastChunkEncryptedSize,
      cacheFile: cacheFile,
      completeMarker: completeMarker,
      complete: complete,
    );
    if (!complete) {
      // FileMode.write truncates. Partial caches from older sessions carry
      // no chunk map, so they can't be trusted anyway — start fresh.
      session.writeHandle = await cacheFile.open(mode: FileMode.write);
    }

    await _sessions[file.id]?.dispose();
    _sessions[file.id] = session;

    // Warm the pipeline — the player's first request is always `bytes=0-`.
    unawaited(
      _ensureChunks(session, 0, math.min(_prefetchChunks, totalChunks) - 1)
          .catchError((e) => debugPrint('VideoStreamingServer warmup: $e')),
    );

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
          debugPrint(
            'VideoStreamingServer: ${session.file.id} fully cached on disk',
          );
        } catch (_) {
          // Marker is an optimization; failing to write it just means the
          // next session re-downloads.
        }
      }
    });
  }
}
