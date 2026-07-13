import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../crypto/hpke.dart';
import '../../src/models/file_model.dart';
import '../key_manager_service.dart';

/// HPKE-sealed cloud metadata — closes the plaintext-filename leak.
///
/// Providers used to write the user's real filename and file type into cloud
/// metadata in the clear (Drive `appProperties`, OneDrive filename encoding)
/// so reconcile could rebuild rows after a reinstall. That handed the
/// provider the most semantic metadata we hold. This module replaces both
/// fields with ONE sealed payload:
///
///   base64url( enc[32] || ct )   where   pt = JSON {"v":1,"n":name,"t":type}
///
/// sealed to the vault's X25519 public key via HPKE under the frozen info
/// string [metaInfo]. Properties:
///
///  * **Public-key-only seal** — background auto-sync keeps writing metadata
///    while the vault is locked; the encrypt-locked property survives.
///  * **Cloud-metadata only** — the `.cnest` file format (headers, body,
///    frozen info strings) is untouched. [metaInfo] is a NEW domain-separated
///    string, itself frozen from first ship.
///  * **Open requires unlock** — reconcile runs post-unlock at both call
///    sites; a failed open degrades to a UUID display name, never a failure.
class SealedMetadata {
  SealedMetadata._();

  /// Frozen forever once shipped — sealed blobs in users' clouds depend on it.
  static final Uint8List metaInfo =
      Uint8List.fromList('ciphernest/meta/v1'.codeUnits);

  /// Payload version inside the sealed JSON.
  static const int payloadVersion = 1;

  /// Name budget inside the payload. OneDrive carries the sealed blob in the
  /// cloud filename (~400-char ceiling incl. UUID stem), which bounds the
  /// plaintext; Drive could take more but a uniform budget keeps blobs
  /// provider-portable. Truncation happens INSIDE the sealed payload only —
  /// SQLite always keeps the full name.
  static const int maxNameBytes = 120;

  /// Drive caps each appProperty at 124 bytes of key+value; "m0".."m9" keys
  /// leave a comfortable 100-char value budget.
  static const int _chunkSize = 100;

  /// Seals `{v:1, n:name, t:type}` to the vault public key. Returns null when
  /// no public key is available (no vault on this device yet) — an upload
  /// must never fail over metadata, reconcile just falls back to the UUID.
  static Future<String?> seal({
    required String name,
    required CnestFileType type,
  }) async {
    try {
      if (!await KeyManagerService().loadPublicKeyForEncrypt()) return null;
      final pub = KeyManagerService().vaultPublicKey;

      var nameBytes = utf8.encode(name);
      if (nameBytes.length > maxNameBytes) {
        // Truncate on a UTF-8 boundary; the full name lives in SQLite.
        var cut = maxNameBytes;
        while (cut > 0 && (nameBytes[cut] & 0xC0) == 0x80) {
          cut--;
        }
        nameBytes = nameBytes.sublist(0, cut);
      }

      final payload = utf8.encode(jsonEncode({
        'v': payloadVersion,
        'n': utf8.decode(nameBytes),
        't': type.wireName,
      }));
      final sealed = await Hpke.sealPayload(
          pub, metaInfo, Uint8List.fromList(payload));
      return base64UrlEncode([...sealed.enc, ...sealed.ct])
          .replaceAll('=', '');
    } catch (e) {
      debugPrint('SealedMetadata.seal failed (metadata omitted): $e');
      return null;
    }
  }

  /// Opens a sealed blob. Returns null on ANY failure — locked vault,
  /// corrupt blob, foreign vault key, bad version — so reconcile can fall
  /// back to the UUID display name without ever failing the sweep.
  static Future<({String name, CnestFileType? type})?> tryOpen(
      String sealedB64) async {
    try {
      if (!KeyManagerService().isUnlocked) return null;
      final raw = base64Url.decode(_pad(sealedB64));
      if (raw.length <= Hpke.nEnc + Hpke.nT) return null;
      final enc = Uint8List.fromList(raw.sublist(0, Hpke.nEnc));
      final ct = Uint8List.fromList(raw.sublist(Hpke.nEnc));
      final pt = await Hpke.openPayload(
          KeyManagerService().vaultKeyPair, metaInfo, enc, ct);
      final json = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      if (json['v'] != payloadVersion) return null;
      final name = json['n'] as String?;
      if (name == null || name.isEmpty) return null;
      return (
        name: name,
        type: CnestFileTypeWire.fromWire(json['t'] as String?),
      );
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  // Drive appProperties chunking (124-byte per-property cap)
  // ------------------------------------------------------------------

  /// Splits a sealed blob across appProperties m0..mN.
  static Map<String, String> chunkForAppProperties(String sealed) {
    final out = <String, String>{};
    var i = 0;
    for (var off = 0; off < sealed.length; off += _chunkSize) {
      out['m$i'] = sealed.substring(
          off, off + _chunkSize > sealed.length ? sealed.length : off + _chunkSize);
      i++;
    }
    return out;
  }

  /// Reassembles m0..mN from a properties map (googleapis types values as
  /// nullable). Returns null when absent.
  static String? fromAppProperties(Map<String, String?>? props) {
    if (props == null || props['m0'] == null) return null;
    final buf = StringBuffer();
    for (var i = 0;; i++) {
      final chunk = props['m$i'];
      if (chunk == null) break;
      buf.write(chunk);
    }
    return buf.toString();
  }

  static String _pad(String s) {
    final rem = s.length % 4;
    return rem == 0 ? s : s + ('=' * (4 - rem));
  }
}

/// Pure resolution of a cloud listing entry to (display name, type) — the
/// reconcile core, extracted so the sealed / legacy-plaintext / UUID-fallback
/// ladder is unit-testable without a database.
class CloudNameResolver {
  CloudNameResolver._();

  /// [sealedOpened] is the result of [SealedMetadata.tryOpen] (null when
  /// there was no sealed blob or it failed to open); [legacyName] /
  /// [legacyType] are the transition-era plaintext fields; [stem] is the
  /// cloud UUID stem, the fallback of last resort.
  ///
  /// Returns the resolved name/type plus whether this entry should be counted
  /// as metadata-unreadable in Vault Health (a sealed blob existed but would
  /// not open, and no legacy plaintext rescued it).
  static ({String name, CnestFileType type, bool unreadable}) resolve({
    required bool hadSealed,
    ({String name, CnestFileType? type})? sealedOpened,
    String? legacyName,
    String? legacyType,
    required String stem,
  }) {
    final name = sealedOpened?.name ??
        ((legacyName != null && legacyName.isNotEmpty) ? legacyName : stem);

    var type = sealedOpened?.type ??
        CnestFileTypeWire.fromWire(legacyType) ??
        CnestFileTypeWire.fromFilename(name);
    // Early builds lumped everything non-image into `document`; extension
    // inference auto-heals music files and misc binaries (mirrors the
    // pre-existing reconcile behavior).
    if (type == CnestFileType.document) {
      final inferred = CnestFileTypeWire.fromFilename(name);
      if (inferred == CnestFileType.audio || inferred == CnestFileType.image) {
        type = inferred;
      }
    }

    final rescued = sealedOpened != null ||
        (legacyName != null && legacyName.isNotEmpty);
    return (name: name, type: type, unreadable: hadSealed && !rescued);
  }
}
