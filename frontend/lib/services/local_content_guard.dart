import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:photo_manager/photo_manager.dart';

import '../src/models/file_model.dart';
import 'database_service.dart';
import 'encryption_service.dart';

/// Decides whether a local gallery file may be trusted as a display shortcut
/// for a vault entry — the fix for "filename is not identity".
///
/// The display rungs (MediaStore `assetId`, then `localPath`) used to trust a
/// local source purely because a reference existed. That serves the WRONG
/// image when a name/id is later reused by different content, or after a
/// replace-original edit left a stale reference. This guard verifies content:
///
///  * **Size gate (always, cheap):** the local file's length must equal the
///    vault entry's plaintext size. A different-size file is rejected
///    outright — this alone catches virtually every real case (an edited or
///    replaced image almost always changes size).
///  * **Hash check (images only, memoized):** when sizes match and we have a
///    content hash, confirm SHA-256 of the local bytes equals it. This is the
///    only way to catch a same-size, different-content swap. It is skipped
///    for video / oversized files: hashing a multi-GB video on the display
///    path would freeze the UI, and the size gate is the guarantee there.
///
/// Rejection just falls through to the (correct) cloud blob.
class LocalContentGuard {
  LocalContentGuard._();

  /// Images at or below this size are hash-verified on display; larger files
  /// (videos especially) use the size gate only, never an on-thread hash.
  static const int _hashCeilingBytes = 50 * 1024 * 1024;

  /// Verdict cache keyed by (file id, local size, local mtime) so a file is
  /// hashed at most once per session and re-verified if its bytes change.
  static final Map<String, bool> _verdicts = {};

  /// True if [localFile] (or the original behind [asset]) may be trusted to
  /// display [file]. Resolution errors read as "not trusted" → use cloud.
  static Future<bool> matches(
    CnestFile file, {
    File? localFile,
    AssetEntity? asset,
  }) async {
    try {
      final f = localFile ?? (asset != null ? await asset.file : null);
      if (f == null || !await f.exists()) return false;

      final len = await f.length();
      // Size gate. sizeBytes == 0 means we don't know it yet (a just-synced
      // peer row before its size propagated) — don't reject on that.
      if (file.sizeBytes > 0 && len != file.sizeBytes) return false;

      // Legacy row (pre-hash) or an oversized/video file: size gate is all we
      // can safely do without risking an on-thread hash of a huge file.
      // The video check must be by EXTENSION — vault rows for videos carry
      // type == image (they live in the pictures tab), so the type check
      // alone would full-file-hash a ≤50 MB video on the display path.
      final ext = file.filename.split('.').last.toLowerCase();
      final isVideo =
          const {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'}.contains(ext);
      if (file.contentHash == null ||
          file.type != CnestFileType.image ||
          isVideo ||
          len > _hashCeilingBytes) {
        return true;
      }

      final mtime = (await f.lastModified()).millisecondsSinceEpoch;
      final key = '${file.id}|$len|$mtime';
      final cached = _verdicts[key];
      if (cached != null) return cached;
      // L2: the persisted verdict table — a photo is hashed once EVER for
      // a given (len, mtime), not once per session. Best-effort: a DB
      // hiccup (or a test with no database) must never break
      // verification itself.
      bool? stored;
      try {
        stored = await DatabaseService().getGuardVerdict(key);
      } catch (_) {}
      if (stored != null) {
        _verdicts[key] = stored;
        return stored;
      }
      // Miss: hash on a BACKGROUND isolate. Pure-Dart SHA-256 completes
      // synchronously, so hashing here froze a frame per first-seen tile.
      final ok = await EncryptionService.hashFileInBackground(f.path) ==
          file.contentHash;
      _verdicts[key] = ok;
      unawaited(
          DatabaseService().putGuardVerdict(key, ok).catchError((_) {}));
      return ok;
    } catch (_) {
      return false; // any resolution failure → prefer the cloud blob
    }
  }

  /// Verify-and-read in ONE pass: the same rules as [matches] (size gate
  /// always; SHA-256 for hash-carrying images under the ceiling), but the
  /// hash runs on a BACKGROUND isolate and the file is read exactly once
  /// — the display path never blocks the UI isolate and never reads the
  /// bytes twice. Images only; returns null when the file may not be
  /// trusted (caller falls through to the cloud blob).
  static Future<Uint8List?> verifiedRead(CnestFile file) async {
    final path = file.localPath;
    if (path == null) return null;
    try {
      final f = File(path);
      if (!await f.exists()) return null;
      final len = await f.length();
      if (file.sizeBytes > 0 && len != file.sizeBytes) return null;
      final ext = file.filename.split('.').last.toLowerCase();
      if (const {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'}.contains(ext)) {
        return null; // the display-read shortcut is for images only
      }
      final needsHash = file.contentHash != null &&
          file.type == CnestFileType.image &&
          len <= _hashCeilingBytes;
      if (!needsHash) return f.readAsBytes();
      final mtime = (await f.lastModified()).millisecondsSinceEpoch;
      final key = '${file.id}|$len|$mtime';
      var cached = _verdicts[key];
      if (cached == null) {
        try {
          cached = await DatabaseService().getGuardVerdict(key);
        } catch (_) {}
      }
      if (cached == false) {
        _verdicts[key] = false;
        return null;
      }
      if (cached == true) {
        _verdicts[key] = true;
        return f.readAsBytes();
      }
      final expected = file.contentHash!;
      final bytes = await Isolate.run(() async {
        final b = await File(path).readAsBytes();
        final ok = await EncryptionService.hashPlaintext(b) == expected;
        return ok ? b : null;
      });
      _verdicts[key] = bytes != null;
      unawaited(DatabaseService()
          .putGuardVerdict(key, bytes != null)
          .catchError((_) {}));
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
