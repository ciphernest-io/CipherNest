import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
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

  _StreamingSession({
    required this.file,
    required this.fileKey,
    required this.plaintextSize,
    required this.encryptedSize,
    required this.totalChunks,
    required this.lastChunkEncryptedSize,
  });

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
    _sessions.clear();
  }

  /// Prepares streaming for [file]: downloads the header, decrypts the file
  /// key with the master key, caches sizes. Returns the localhost URL the
  /// video player should connect to.
  Future<String> beginSession(CnestFile file) async {
    final port = await start();
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
    final headerBytes = await CloudService().downloadRange(
      file.cloudId!,
      0,
      EncryptionService.headerSize - 1,
    );
    final fileKey = await EncryptionService.decryptFileKeyFromHeader(headerBytes);

    _sessions[file.id] = _StreamingSession(
      file: file,
      fileKey: fileKey,
      plaintextSize: plaintextSize,
      encryptedSize: encryptedSize,
      totalChunks: totalChunks,
      lastChunkEncryptedSize: lastChunkEncryptedSize,
    );

    return 'http://127.0.0.1:$port/${file.id}';
  }

  /// Drops the cached file key for a session. Call from dispose().
  void endSession(String fileId) {
    _sessions.remove(fileId);
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
    final session = _sessions[fileId];
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

    final headers = <String, String>{
      'Content-Type': 'video/mp4',
      'Accept-Ranges': 'bytes',
      'Content-Length': '${rangeEnd - rangeStart + 1}',
    };
    if (isPartial) {
      headers['Content-Range'] = 'bytes $rangeStart-$rangeEnd/$total';
    }

    if (request.method == 'HEAD') {
      return Response(isPartial ? 206 : 200, headers: headers);
    }

    try {
      final bytes = await _serveRange(session, rangeStart, rangeEnd);
      return Response(
        isPartial ? 206 : 200,
        body: bytes,
        headers: headers,
      );
    } catch (e) {
      debugPrint('VideoStreamingServer range error: $e');
      return Response.internalServerError(body: 'Range fetch failed: $e');
    }
  }

  /// Computes which encrypted chunks cover the plaintext range, downloads
  /// them, decrypts, and returns the precise plaintext slice.
  Future<Uint8List> _serveRange(
    _StreamingSession session,
    int pStart,
    int pEnd,
  ) async {
    final chunkSize = EncryptionService.plaintextChunkSize;
    final firstChunk = pStart ~/ chunkSize;
    final lastChunk = pEnd ~/ chunkSize;
    final chunkCount = lastChunk - firstChunk + 1;

    final encryptedStart = session.chunkEncryptedStart(firstChunk);
    final encryptedEnd =
        session.chunkEncryptedStart(lastChunk) + session.chunkEncryptedSize(lastChunk) - 1;

    final encryptedBytes = await CloudService().downloadRange(
      session.file.cloudId!,
      encryptedStart,
      encryptedEnd,
    );

    final lastChunkEncSize = (lastChunk == session.totalChunks - 1)
        ? session.lastChunkEncryptedSize
        : null;

    final plaintext = await EncryptionService.decryptChunkRange(
      encryptedBytes,
      session.fileKey,
      chunkCount,
      lastChunkEncryptedSize: lastChunkEncSize,
    );

    // Slice to exact requested range
    final sliceStart = pStart - firstChunk * chunkSize;
    final sliceLen = pEnd - pStart + 1;
    return Uint8List.sublistView(plaintext, sliceStart, sliceStart + sliceLen);
  }
}
