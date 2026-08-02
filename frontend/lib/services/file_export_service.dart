import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../src/models/file_model.dart';
import 'cloud/cloud_service.dart';
import 'encryption_service.dart';
import 'local_content_guard.dart';

/// Where a saved copy landed, for the caller's snackbar.
enum SaveOutcome { savedToGallery, savedToPicked, alreadyInGallery, cancelled }

/// Gets plaintext OUT of the vault on the user's explicit request — the two
/// deliberate exceptions to "decrypted bytes never touch public storage":
///
///  * [saveToDevice] — media into the phone gallery (MediaStore), other
///    types to a SAF location the user picks. Public storage, on purpose.
///  * [materializePlaintext] — a plaintext copy in the APP-PRIVATE temp dir
///    (the same artifact the documents "open" flow creates; the cache GC
///    reclaims it), used as the source for the system share sheet.
///
/// Both paths are user-initiated actions on their own files. Nothing here
/// runs implicitly.
class FileExportService {
  FileExportService._();

  static const _videoExts = {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'};

  static bool _isVideo(CnestFile f) {
    final dot = f.filename.lastIndexOf('.');
    if (dot < 0) return false;
    return _videoExts.contains(f.filename.substring(dot + 1).toLowerCase());
  }

  /// A readable plaintext [File] for [file], cheapest source first:
  ///
  ///  1. the verified local original (content-guard checked — an edited
  ///     vault file must not export its stale gallery twin);
  ///  2. an already-decrypted temp copy (documents-open leaves one);
  ///  3. download + decrypt into temp.
  ///
  /// Null when the file has no cloud blob yet (pending upload) and no
  /// verified local source. Memory note: path 3 holds ciphertext and
  /// plaintext together (~2x file size peak) — same profile as every other
  /// whole-file decrypt in the app.
  static Future<File?> materializePlaintext(CnestFile file) async {
    if (file.localPath != null) {
      final local = File(file.localPath!);
      if (await local.exists() &&
          await LocalContentGuard.matches(file, localFile: local)) {
        return local;
      }
    }

    final dir = await getTemporaryDirectory();
    final tmp = File('${dir.path}/${file.filename}');
    if (await tmp.exists()) return tmp;

    if (file.cloudId == null) return null;
    try {
      final encrypted = await CloudService().downloadFile(file.cloudId!);
      final decrypted = await EncryptionService.decryptFile(encrypted);
      await tmp.writeAsBytes(decrypted);
      return tmp;
    } catch (e) {
      debugPrint('materializePlaintext failed for ${file.id}: $e');
      return null;
    }
  }

  /// Saves a decrypted copy outside the vault. Media lands in the phone
  /// gallery; everything else goes wherever the user picks in the system
  /// save dialog. Throws on decrypt/IO failure — callers surface it.
  static Future<SaveOutcome> saveToDevice(CnestFile file) async {
    final isMedia = file.type == CnestFileType.image || _isVideo(file);

    // A gallery-bound file IS already on the device — saving would just
    // duplicate it in the user's own gallery.
    if (isMedia && file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(file.assetId!);
        if (asset != null && await asset.file != null) {
          return SaveOutcome.alreadyInGallery;
        }
      } catch (_) {
        // MediaStore entry gone — fall through and save a real copy.
      }
    }

    final plain = await materializePlaintext(file);
    if (plain == null) {
      throw Exception('File is not downloadable yet — sync and retry');
    }

    if (isMedia) {
      if (_isVideo(file)) {
        await PhotoManager.editor.saveVideo(plain, title: file.filename);
      } else {
        await PhotoManager.editor
            .saveImageWithPath(plain.path, title: file.filename);
      }
      return SaveOutcome.savedToGallery;
    }

    final savedPath = await FilePicker.platform.saveFile(
      fileName: file.filename,
      bytes: await plain.readAsBytes(),
    );
    return savedPath == null ? SaveOutcome.cancelled : SaveOutcome.savedToPicked;
  }
}
