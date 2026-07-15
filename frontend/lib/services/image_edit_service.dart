import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'database_backup_service.dart';
import 'database_service.dart';
import 'encryption_service.dart';

/// Orchestrates persisting an edited image back to the vault.
///
/// Pure in-memory until the encrypted bytes are handed to CloudService for
/// upload — the plaintext never touches disk along this path. Mirrors the
/// upload pattern in home_screen.dart's _handleUpload.
class ImageEditService {
  static final ImageEditService _instance = ImageEditService._internal();
  factory ImageEditService() => _instance;
  ImageEditService._internal();

  /// Saves [editedBytes] back to the vault.
  ///
  /// If [replaceOriginal] is true, the source's [CnestFile.id] is kept and
  /// the old cloud blob is best-effort deleted. If false, a new file is
  /// created (new uuid, no asset_id / local_path — edited images are
  /// vault-only artifacts).
  ///
  /// Returns the resulting [CnestFile] the viewer should now display.
  Future<CnestFile> saveEdit({
    required CnestFile source,
    required Uint8List editedBytes,
    required bool replaceOriginal,
    String copyLabel = 'edited',
  }) async {
    // 1. Thumbnail. Same parameters auto_sync_service.dart uses.
    final thumbBytes = await FlutterImageCompress.compressWithList(
      editedBytes,
      minHeight: 300,
      minWidth: 300,
      quality: 50,
    );

    // 2. Encrypt main + thumb in parallel.
    final encryptedMainFuture = EncryptionService.encryptFile(editedBytes);
    final encryptedThumbFuture = EncryptionService.encryptFile(thumbBytes);
    final encryptedMain = await encryptedMainFuture;
    final encryptedThumb = await encryptedThumbFuture;

    // 3. Determine the destination file id + filename.
    final fileId = replaceOriginal ? source.id : const Uuid().v4();
    final editedFilename = replaceOriginal
        ? source.filename
        : _copyFilename(source.filename, copyLabel);

    // For "save as copy" we must add the DB row BEFORE upload so the row
    // exists for markAsUploaded to update. For "replace original" the row
    // already exists.
    if (!replaceOriginal) {
      final row = CnestFile(
        id: fileId,
        filename: editedFilename,
        sizeBytes: editedBytes.length,
        createdAt: DateTime.now(),
        type: CnestFileType.image,
        provider: source.provider,
        accountId: source.accountId,
        // Vault-only artifact: no local path, no MediaStore link.
        localPath: null,
        assetId: null,
        isUploaded: false,
        isFavorite: false,
      );
      await DatabaseService().addFile(row);
    }

    // 4. Upload main + thumb concurrently.
    final mainUpload = CloudService().uploadEncryptedFile(
      filename: '$fileId.cnest',
      type: CnestFileType.image,
      originalName: editedFilename,
      bytes: encryptedMain,
    );
    final thumbUpload = CloudService().uploadEncryptedFile(
      filename: '${fileId}_thumb.cnest',
      type: CnestFileType.image,
      bytes: encryptedThumb,
    );
    final mainCloudId = await mainUpload;
    final thumbCloudId = await thumbUpload;

    if (mainCloudId == null) {
      throw Exception('Edit upload failed: main blob did not upload');
    }

    // 5. Mark uploaded (updates cloud_id + thumbnail_cloud_id for both
    // modes). Records the createFile sync op — for replace-original the
    // duplicate create (same uuid) is dead on arrival in replay, by design.
    await DatabaseService().markAsUploaded(fileId, mainCloudId, thumbCloudId,
        filename: editedFilename);

    // 6. Replace-mode cleanup: delete old cloud blobs and stale cache.
    if (replaceOriginal) {
      await _bestEffortReplaceCleanup(source);
      // For replace we also need to clear the filename / size update on the
      // existing row. markAsUploaded doesn't touch size — patch it here.
      await DatabaseService().updateSizeBytes(fileId, editedBytes.length);
    }

    DatabaseBackupService().scheduleBackup();

    // 7. Construct the updated CnestFile to hand back to the viewer.
    return CnestFile(
      id: fileId,
      filename: editedFilename,
      sizeBytes: editedBytes.length,
      createdAt: replaceOriginal ? source.createdAt : DateTime.now(),
      type: CnestFileType.image,
      provider: source.provider,
      accountId: source.accountId,
      localPath: null,
      assetId: null,
      cloudId: mainCloudId,
      thumbnailCloudId: thumbCloudId,
      isUploaded: true,
      // Preserve favorite status when replacing; new copies start unfavorited.
      isFavorite: replaceOriginal ? source.isFavorite : false,
    );
  }

  Future<void> _bestEffortReplaceCleanup(CnestFile source) async {
    final oldCloudId = source.cloudId;
    final oldThumbCloudId = source.thumbnailCloudId;

    try {
      if (oldCloudId != null) {
        await CloudService().deleteFile(oldCloudId);
      }
    } catch (e) {
      debugPrint('ImageEditService: old main delete failed: $e');
    }
    try {
      if (oldThumbCloudId != null) {
        await CloudService().deleteFile(oldThumbCloudId);
      }
    } catch (e) {
      debugPrint('ImageEditService: old thumb delete failed: $e');
    }

    // Wipe stale plaintext + thumb caches so the viewer doesn't pick them up.
    try {
      final tempDir = await getTemporaryDirectory();
      final stale = <File>[
        if (oldCloudId != null)
          File('${tempDir.path}/${oldCloudId}_decrypted.jpg'),
        if (oldCloudId != null)
          File('${tempDir.path}/thumb_$oldCloudId.jpg'),
      ];
      for (final f in stale) {
        if (await f.exists()) await f.delete();
      }
    } catch (e) {
      debugPrint('ImageEditService: cache wipe failed: $e');
    }
  }

  String _copyFilename(String original, String label) {
    final dot = original.lastIndexOf('.');
    final stem = dot < 0 ? original : original.substring(0, dot);
    // Copies are always re-encoded as JPG (editor output / captured video
    // frame), so force a .jpg extension regardless of source format.
    return '$stem ($label).jpg';
  }
}
