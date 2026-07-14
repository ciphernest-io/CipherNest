/// Op-log segment codec: batches of [SyncOp]s <-> sealed `.cnest` blobs.
///
/// Segments are ordinary format-v1 CipherNest blobs (same header, same
/// AAD-bound chunked body as every vault file) whose plaintext is
/// `{"v":1,"ops":[...]}`. Two properties are load-bearing:
///
///  * SEAL IS PUBLIC-KEY-ONLY. [seal] needs nothing but the vault public
///    key, so a LOCKED device (background auto-sync) can append its
///    create-ops with zero secret material in memory. The encrypt-locked
///    architecture does not bend for sync.
///  * OPEN REQUIRES THE UNLOCKED VAULT. Merging other devices' history is
///    a foreground, authenticated activity by construction.
///
/// Naming: `ops_<deviceId>_<seq>.cnest`, appended to `backup/log/` and
/// immutable once written. deviceId is a UUID (hyphens, never
/// underscores), so the LAST underscore splits id from seq unambiguously.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../encryption_service.dart';
import 'sync_op.dart';

class SegmentCodec {
  SegmentCodec._();

  static const int payloadVersion = 1;
  static const String namePrefix = 'ops_';
  static const String nameSuffix = '.cnest';

  static String segmentName(String deviceId, int seq) =>
      '$namePrefix${deviceId}_$seq$nameSuffix';

  /// Parses `ops_<deviceId>_<seq>.cnest`; null for anything else.
  static ({String deviceId, int seq})? parseName(String name) {
    if (!name.startsWith(namePrefix) || !name.endsWith(nameSuffix)) {
      return null;
    }
    final core =
        name.substring(namePrefix.length, name.length - nameSuffix.length);
    final cut = core.lastIndexOf('_');
    if (cut <= 0 || cut == core.length - 1) return null;
    final seq = int.tryParse(core.substring(cut + 1));
    if (seq == null || seq < 0) return null;
    return (deviceId: core.substring(0, cut), seq: seq);
  }

  /// Seals [ops] into a format-v1 blob. Public-key-only: works while the
  /// vault is locked. Returns null when no vault public key exists on this
  /// device yet (nothing to sync against anyway).
  static Future<Uint8List?> seal(List<SyncOp> ops) async {
    try {
      final payload = utf8.encode(jsonEncode({
        'v': payloadVersion,
        'ops': [for (final op in ops) op.toJson()],
      }));
      return await EncryptionService.encryptFile(
          Uint8List.fromList(payload));
    } catch (e) {
      debugPrint('SegmentCodec.seal failed: $e');
      return null;
    }
  }

  /// Opens a sealed segment. Requires the unlocked vault. Returns null on
  /// ANY failure — locked, tampered, truncated, foreign key, bad version.
  /// Callers must count failures for Vault Health, never silently absorb a
  /// segment into "seen".
  static Future<List<SyncOp>?> tryOpen(Uint8List blob) async {
    try {
      final plain = await EncryptionService.decryptFile(blob);
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      if (json['v'] != payloadVersion) return null;
      return [
        for (final op in (json['ops'] as List))
          SyncOp.fromJson(op as Map<String, dynamic>),
      ];
    } catch (_) {
      return null;
    }
  }
}
