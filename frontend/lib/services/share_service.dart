import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../src/config/constants.dart';
import '../src/models/file_model.dart';
import '../src/models/share_model.dart';
import 'cloud/account_registry.dart';
import 'cloud/cloud_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';

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

    // 1. Download original encrypted blob (we need to swap its header).
    final originalBytes = await CloudService().downloadFile(file.cloudId!);

    // 2. Recover the file's per-file key from the original header (master key).
    final headerLen = ByteData.sublistView(originalBytes.sublist(0, 4))
        .getUint32(0, Endian.big);
    final headerSize = 4 + headerLen;
    final fileKey = await EncryptionService.decryptFileKeyFromHeader(
      originalBytes.sublist(0, headerSize),
    );

    // 3. Generate share key (random) or derive from password.
    SecretKey shareKey;
    Uint8List? salt;
    if (password != null && password.isNotEmpty) {
      salt = EncryptionService.generatePasswordSalt();
      shareKey = await EncryptionService.derivePasswordKey(password, salt);
    } else {
      shareKey = await EncryptionService.generateShareKey();
    }

    // 4. Re-wrap the file key with the share key → new header.
    final newHeaderCore = await EncryptionService.wrapFileKeyForShare(
      fileKey,
      shareKey,
    );
    // For password mode, prepend the salt INSIDE the header.
    // Format: [4-byte len of (salt? + wrapped)] [salt? (16 bytes)] [wrapped (60 bytes)]
    Uint8List shareHeader;
    if (salt != null) {
      // newHeaderCore = [4-byte len][60-byte wrapped]; we re-format with salt
      final wrapped = newHeaderCore.sublist(4); // 60 bytes
      final combined = Uint8List(salt.length + wrapped.length);
      combined.setRange(0, salt.length, salt);
      combined.setRange(salt.length, combined.length, wrapped);
      final lenPrefix = ByteData(4)..setUint32(0, combined.length, Endian.big);
      shareHeader = Uint8List.fromList(
        lenPrefix.buffer.asUint8List() + combined,
      );
    } else {
      shareHeader = newHeaderCore;
    }

    // 5. Build the share blob: new header + original encrypted body unchanged.
    final body = originalBytes.sublist(headerSize);
    final shareBlob = Uint8List(shareHeader.length + body.length);
    shareBlob.setRange(0, shareHeader.length, shareHeader);
    shareBlob.setRange(shareHeader.length, shareBlob.length, body);

    // 6. Upload to public location.
    final shareId = const Uuid().v4();
    final cloudFilename = '$shareId.cnest';
    final uploaded = await CloudService().uploadPublicShare(
      filename: cloudFilename,
      bytes: shareBlob,
    );

    // 7. Construct magic link.
    final expiresAt = expiry == null ? null : DateTime.now().add(expiry);
    final shareUrl = await _buildShareUrl(
      downloadUrl: uploaded.downloadUrl,
      shareKey: shareKey,
      salt: salt,
      expiresAt: expiresAt,
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
    for (final s in shares) {
      if (s.isExpired) {
        await revokeShare(s.id);
        removed++;
      }
    }
    return removed;
  }
}
