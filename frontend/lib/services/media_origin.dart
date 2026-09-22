import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';

/// Reads a gallery asset's ORIGINAL bytes, location metadata included.
///
/// Why this exists. Android redacts GPS EXIF from anything MediaStore hands
/// back unless the caller holds ACCESS_MEDIA_LOCATION. Every upload path used
/// `asset.file`, which is the redacted copy, so a geotagged photo was silently
/// stripped of its location on the way into the vault. The file picker route
/// did not go through MediaStore and kept it, so the same photo landed
/// differently depending on how it was added, and nothing told the user.
///
/// That is data loss, not privacy protection. The files are encrypted before
/// they leave the device and CipherNest never reads, indexes or transmits
/// location, so there is nothing to protect the user FROM by destroying it.
/// What it does cost them is that a photo restored from the vault is no longer
/// the photo they took (MASVS finding F-30).
///
/// The permission is requested lazily, on the first upload that needs it, and
/// a refusal is not an error: the redacted copy still uploads, just without
/// the geotag. Nothing here ever surfaces a coordinate outside the file.
class MediaOrigin {
  MediaOrigin._();

  static bool _asked = false;
  static bool _granted = false;

  /// Asks for ACCESS_MEDIA_LOCATION once per process.
  ///
  /// Deliberately not requested during onboarding. It only matters at the
  /// moment a gallery photo is being ingested, and asking then is the only
  /// point where the reason would make sense to the user.
  static Future<bool> ensurePermission() async {
    if (_asked) return _granted;
    _asked = true;
    try {
      final status = await Permission.accessMediaLocation.request();
      _granted = status.isGranted;
    } catch (e) {
      // Older platforms have no such permission; the read still works, it
      // simply has nothing to redact.
      _granted = false;
      if (kDebugMode) debugPrint('MediaOrigin: permission request failed: $e');
    }
    return _granted;
  }

  /// The asset's file with metadata intact where the platform allows it.
  ///
  /// Falls back to the redacted copy on any failure, because a photo that
  /// uploads without its geotag is strictly better than one that does not
  /// upload at all.
  static Future<File?> fileWithMetadata(AssetEntity asset) async {
    await ensurePermission();
    try {
      final origin = await asset.originFile;
      if (origin != null && await origin.exists()) return origin;
    } catch (e) {
      if (kDebugMode) debugPrint('MediaOrigin: originFile failed: $e');
    }
    return asset.file;
  }
}
