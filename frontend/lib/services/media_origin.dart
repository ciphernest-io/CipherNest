import 'dart:io';

import 'package:flutter/foundation.dart';
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
/// ACCESS_MEDIA_LOCATION is deliberately not declared. Reading the ORIGINAL
/// file rather than the MediaStore copy is what preserves the tag, and a
/// device test on Android 16 confirmed a full GPS round trip with that
/// permission absent and denied. Declaring it would add a sensitive
/// permission to the Play listing for no observable gain. The fallback below
/// means a device that does redact loses the tag rather than the upload.
class MediaOrigin {
  MediaOrigin._();

  /// The asset's file with metadata intact where the platform allows it.
  ///
  /// Falls back to the redacted copy on any failure, because a photo that
  /// uploads without its geotag is strictly better than one that does not
  /// upload at all.
  static Future<File?> fileWithMetadata(AssetEntity asset) async {
    try {
      final origin = await asset.originFile;
      if (origin != null && await origin.exists()) return origin;
    } catch (e) {
      if (kDebugMode) debugPrint('MediaOrigin: originFile failed: $e');
    }
    return asset.file;
  }
}
