import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../src/config/constants.dart';
import '../src/models/file_model.dart';
import '../src/models/share_model.dart';
import 'activity_center.dart';
import 'cloud/account_registry.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';

/// Share-blob header version that carries the expiry deadline in-band.
///
/// Distinct from [EncryptionService.formatVersion], which versions the vault
/// file format. A share blob reuses the vault body verbatim but frames its
/// own header, so the two version numbers are independent.
const int shareFormatV2 = 0x02;

/// Orchestrates the create / list / revoke share flows.
class ShareService {
  static final ShareService _instance = ShareService._internal();
  factory ShareService() => _instance;
  ShareService._internal();

  /// Common expiry presets for the share dialog.
  static const Map<String, Duration?> expiryOptions = {
    '1 hour': Duration(hours: 1),
    '1 day': Duration(days: 1),
    '7 days': Duration(days: 7),
    '30 days': Duration(days: 30),
    'Never': null,
  };

  /// Creates a magic-link share for [file].
  ///
  /// - [expiry]: optional TTL; `null` means no expiry
  /// - [password]: optional. If provided, the recipient must enter it; otherwise
  ///   the URL fragment carries the raw share key.
  ///
  /// Returns the persisted [CnestShare] (its `shareUrl` is what to send).
  Future<CnestShare> createShare({
    required CnestFile file,
    required Duration? expiry,
    String? password,
  }) async {
    if (file.cloudId == null) {
      throw Exception('Cannot share a file that is not yet uploaded');
    }
    final account = AccountRegistry().activeAccount;
    if (account == null) throw Exception('No active cloud account');

    // No entitlement gate on sharing. Every expiry option and password
    // protection are available on the free tier; the only paid limit in the
    // product is the stored-file cap (FreeTierGuard). Deliberate: the sharing
    // feature is the product's central usability argument, and putting the
    // password behind a paywall would mean the least protected links are the
    // ones the most casual users send.

    // 1. Download original encrypted blob (we need to swap its header).
    final originalBytes = await CloudService().downloadFile(file.cloudId!);

    // 2. Recover the file's per-file key from the vault header. This is an
    //    HPKE open, so it requires an unlocked vault — sharing is always an
    //    active, authenticated action, never a background one.
    final fileKey =
        await EncryptionService.decryptFileKeyFromHeader(originalBytes);

    // 3. Generate share key (random) or derive from password.
    SecretKey shareKey;
    Uint8List? salt;
    if (password != null && password.isNotEmpty) {
      salt = EncryptionService.generatePasswordSalt();
      shareKey = await EncryptionService.derivePasswordKey(password, salt);
    } else {
      shareKey = await EncryptionService.generateShareKey();
    }

    // Deadline is needed before the header is built, since v2 carries it.
    final expiresAt = expiry == null ? null : DateTime.now().add(expiry);

    // 4. Re-wrap the file key under the share key and frame the share header.
    //    Share header v1:
    //      [1 version][4 region-len BE][region]
    //      region = password ? (16 salt + 60 wrapped) : (60 wrapped)
    //    The body (preamble + AAD-bound chunks) is copied verbatim; its
    //    content_id lives in the body, so it survives the header swap.
    final wrapped =
        await EncryptionService.wrapFileKeyForShare(fileKey, shareKey);
    final region = salt == null
        ? wrapped
        : Uint8List.fromList([...salt, ...wrapped]);
    // Share header v2:
    //   [1 version=0x02][8 expiry epoch-ms BE, 0 = never][4 region-len BE][region]
    //
    // v1 was [1 version][4 region-len][region], with expiry living only in
    // the URL fragment. That made expiry advisory in the weakest possible
    // way: the recipient holds the URL, so deleting `&exp=` from it removed
    // the deadline entirely (SA-WEB-02).
    //
    // Carrying it in the blob means the recipient cannot edit it, and both
    // viewers plus the Worker can enforce it. It is deliberately PLAINTEXT
    // and outside the sealed region, because the Worker has no key and must
    // be able to read it. It reveals only when a link stops working, which
    // the sender chose and the recipient already knows.
    //
    // Honest about what this is not: someone who saved the direct cloud URL
    // can still fetch the blob past expiry and decrypt it with a key they
    // already hold. Real revocation is still deleting the blob, which the
    // sweep does. This closes casual bypass, not determined archiving.
    final expiryMs = expiresAt?.millisecondsSinceEpoch ?? 0;
    final shareHeader = BytesBuilder(copy: false)
      ..addByte(shareFormatV2)
      ..add((ByteData(8)..setUint64(0, expiryMs, Endian.big))
          .buffer
          .asUint8List())
      ..add((ByteData(4)..setUint32(0, region.length, Endian.big))
          .buffer
          .asUint8List())
      ..add(region);
    final headerBytes = shareHeader.toBytes();

    // 5. Build the share blob: new header + original encrypted body unchanged.
    final body = originalBytes.sublist(EncryptionService.headerSize);
    final shareBlob = Uint8List(headerBytes.length + body.length);
    shareBlob.setRange(0, headerBytes.length, headerBytes);
    shareBlob.setRange(headerBytes.length, shareBlob.length, body);

    // 6. Upload to public location.
    final shareId = const Uuid().v4();
    final cloudFilename = '$shareId.cnest';
    final uploaded = await CloudService().uploadPublicShare(
      filename: cloudFilename,
      bytes: shareBlob,
    );

    // 7. Construct magic link. Attach the file's display name so the
    // recipient's download preserves it (fragment stays client-side, so
    // the filename never reaches the server).
    final shareUrl = await _buildShareUrl(
      downloadUrl: uploaded.downloadUrl,
      shareKey: shareKey,
      salt: salt,
      expiresAt: expiresAt,
      filename: file.filename,
    );

    // 8. Persist locally.
    final share = CnestShare(
      id: shareId,
      fileId: file.id,
      cloudId: uploaded.cloudId,
      downloadUrl: uploaded.downloadUrl,
      shareUrl: shareUrl,
      hasPassword: password != null && password.isNotEmpty,
      expiresAt: expiresAt,
      createdAt: DateTime.now(),
      accountId: account.id,
    );
    await DatabaseService().addShare(share);

    return share;
  }

  Future<String> _buildShareUrl({
    required String downloadUrl,
    required SecretKey shareKey,
    required String filename,
    Uint8List? salt,
    DateTime? expiresAt,
  }) async {
    final encodedDl = base64Url.encode(utf8.encode(downloadUrl));

    final fragment = StringBuffer();
    if (salt != null) {
      // Password-protected: only embed the salt; recipient enters password
      fragment.write('p=${base64Url.encode(salt)}');
    } else {
      // Plain: embed the share key directly
      final keyBytes = await shareKey.extractBytes();
      fragment.write('k=${base64Url.encode(keyBytes)}');
    }
    if (expiresAt != null) {
      fragment.write('&exp=${expiresAt.millisecondsSinceEpoch}');
    }
    // Original filename, base64url-encoded so it survives special chars
    // (spaces, unicode). Recipient uses it as the `<a download=…>` value.
    //
    // NOT attached to a password-protected share. The whole premise of a
    // password link is that the link alone reveals nothing without the
    // password, and a filename is frequently the most telling thing about a
    // file. Sending "link + password separately" stops meaning anything if
    // the link already says `medical-results-2026.pdf` (SA-WEB-05).
    //
    // Plain shares keep it: there the key is in the fragment anyway, so the
    // name adds no disclosure, and the recipient gets a correctly named
    // download instead of `shared-file.jpg`.
    if (salt == null) {
      fragment.write('&n=${base64Url.encode(utf8.encode(filename))}');
    }

    return 'https://${AppConstants.shareHost}/s/$encodedDl#${fragment.toString()}';
  }

  /// Lists all shares created by the current account.
  Future<List<CnestShare>> listShares() async {
    return DatabaseService().getShares();
  }

  /// Revokes a share: deletes the cloud blob and removes the local record.
  /// The magic link will return 404/access-denied to recipients.
  Future<void> revokeShare(String shareId) async {
    final share = await DatabaseService().getShareById(shareId);
    if (share == null) return;
    try {
      await CloudService().deletePublicShare(share.cloudId);
    } catch (e) {
      debugPrint('revokeShare: cloud delete failed (continuing): $e');
    }
    await DatabaseService().deleteShare(shareId);
  }

  /// Cleans up expired shares. Best-effort — if cloud delete fails, we still
  /// remove the local record. Call from app startup or settings.
  Future<int> sweepExpired() async {
    final shares = await DatabaseService().getShares();
    int removed = 0;
    // Quiet janitor: sheet-only while running, surfaces only failures.
    final task = ActivityCenter().start(
        kind: ActivityKind.sweep,
        label: 'Cleaning up expired shares…',
        visibility: ActivityVisibility.quiet);
    try {
      for (final s in shares) {
        if (s.isExpired) {
          await revokeShare(s.id);
          removed++;
        }
      }
      if (removed > 0) {
        task.complete(
            '$removed expired share${removed == 1 ? '' : 's'} revoked');
      } else {
        task.discard();
      }
      return removed;
    } catch (e) {
      task.fail('Expired-share cleanup failed');
      rethrow;
    }
  }
}
