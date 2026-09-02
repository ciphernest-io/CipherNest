import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../src/models/file_model.dart';
import 'local_content_guard.dart';

/// The one session-wide thumbnail source of truth.
///
/// Before this store existed there were FOUR independent thumbnail
/// pipelines (grid memo, viewer placeholder fields, filmstrip fields,
/// video strip), each fetching its own bytes at its own size and decoding
/// under its own ImageCache key — identical pixels, four decodes, and a
/// visible flicker every time one surface handed off to another.
///
/// Invariants that kill the flicker:
///  * ONE `Uint8List` instance per photo. `MemoryImage` equality is
///    byte-list identity, so handing every surface the same instance is
///    what lets them share a single decoded ImageCache entry.
///  * ONE `ImageProvider` instance per (photo, decode width), built lazily
///    and cached — the provider object itself is stable across rebuilds.
class ThumbEntry {
  Uint8List? bytes;
  String? diskPath;
  String? localPath;
  final Map<int, ImageProvider> _providers = {};

  bool get hasSource => bytes != null || diskPath != null || localPath != null;
}

class ThumbStore {
  ThumbStore._();
  static final ThumbStore instance = ThumbStore._();

  static const int _entryCap = 1200;
  static const int _byteCap = 64 << 20;

  final LinkedHashMap<String, ThumbEntry> _entries = LinkedHashMap();
  int _heldBytes = 0;

  /// Synchronous peek (LRU-promoting). Null means no session knowledge —
  /// the caller runs its ladder and writes the result back through.
  ThumbEntry? peek(String id) {
    final e = _entries.remove(id);
    if (e == null) return null;
    _entries[id] = e;
    return e;
  }

  ThumbEntry _obtain(String id) {
    final existing = peek(id);
    if (existing != null) return existing;
    final e = ThumbEntry();
    _entries[id] = e;
    _trim();
    return e;
  }

  void putBytes(String id, Uint8List bytes) {
    final e = _obtain(id);
    if (identical(e.bytes, bytes)) return;
    _heldBytes += bytes.length - (e.bytes?.length ?? 0);
    e.bytes = bytes;
    e._providers.clear();
    _trim();
  }

  void putDiskPath(String id, String path) {
    final e = _obtain(id);
    if (e.diskPath == path) return;
    e.diskPath = path;
    // Bytes (when present) still win inside providerFor; only a
    // bytes-less entry changes its provider source.
    if (e.bytes == null) e._providers.clear();
  }

  /// A content-guard-verified local original (grid ladder rung 2).
  void putLocalPath(String id, String path) {
    final e = _obtain(id);
    if (e.localPath == path) return;
    e.localPath = path;
    if (e.bytes == null && e.diskPath == null) e._providers.clear();
  }

  void evict(String id) {
    final e = _entries.remove(id);
    if (e != null) _heldBytes -= e.bytes?.length ?? 0;
  }

  /// App lock drops every plaintext thumbnail byte from memory.
  void clear() {
    _entries.clear();
    _heldBytes = 0;
  }

  /// The canonical provider for this photo at [width]. Stable instance:
  /// two calls with the same arguments return the identical object.
  ImageProvider? providerFor(String id, {int width = 300}) {
    final e = peek(id);
    if (e == null || !e.hasSource) return null;
    final cached = e._providers[width];
    if (cached != null) return cached;
    final built = _build(e, width);
    if (built != null) e._providers[width] = built;
    return built;
  }

  ImageProvider? _build(ThumbEntry e, int width) {
    final bytes = e.bytes;
    if (bytes != null) return ResizeImage(MemoryImage(bytes), width: width);
    final disk = e.diskPath;
    if (disk != null) return ResizeImage(FileImage(File(disk)), width: width);
    final local = e.localPath;
    if (local != null) {
      return ResizeImage(FileImage(File(local)), width: width);
    }
    return null;
  }

  void _trim() {
    while (_entries.length > _entryCap && _entries.isNotEmpty) {
      evict(_entries.keys.first);
    }
    if (_heldBytes <= _byteCap) return;
    // Byte pressure: drop oldest byte-holding entries; path-only entries
    // are near-free and stay.
    final victims = <String>[];
    for (final kv in _entries.entries) {
      if (_heldBytes <= _byteCap) break;
      if (kv.value.bytes != null) {
        _heldBytes -= kv.value.bytes!.length;
        kv.value.bytes = null;
        kv.value._providers.clear();
        if (!kv.value.hasSource) victims.add(kv.key);
      }
    }
    victims.forEach(_entries.remove);
  }

  /// Bounded prewarm for a file whose tile is about to be needed (the
  /// gallery follow-jump lands on a fresh region while the viewer covers
  /// it). MediaStore + disk-cache rungs only — never the network.
  Future<void> prefetch(CnestFile file) async {
    if (peek(file.id)?.hasSource ?? false) return;
    if (file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(file.assetId!);
        if (asset != null &&
            await LocalContentGuard.matches(file, asset: asset)) {
          final bytes = await asset.thumbnailDataWithSize(
            const ThumbnailSize(300, 300),
          );
          if (bytes != null) {
            putBytes(file.id, bytes);
            return;
          }
        }
      } catch (_) {}
    }
    if (file.cloudId != null) {
      try {
        final dir = await getTemporaryDirectory();
        final thumb = File('${dir.path}/thumb_${file.cloudId}.jpg');
        if (await thumb.exists()) putDiskPath(file.id, thumb.path);
      } catch (_) {}
    }
  }
}
