import 'dart:io';

import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../src/models/file_model.dart';
import 'mp4_metadata_parser.dart';

/// Everything the Samsung-Gallery-style info sheet renders. Fields left
/// `null` are simply not rendered — the sheet degrades gracefully when a
/// file doesn't carry EXIF (screenshots, downloads, older auto-syncs) or
/// isn't reachable on disk (cloud-only, master key unlocked).
class FileMetadata {
  final DateTime captured;
  final String filename;
  final String? path;
  final int sizeBytes;

  // Image
  final int? width;
  final int? height;
  final String? deviceModel;
  final int? iso;
  final double? focalLengthMm;
  final double? aperture;
  final String? shutterSpeed;
  final double? exposureBias;

  // Video
  final bool isVideo;
  final Duration? duration;
  final String? videoCodec;
  final String? audioCodec;
  final int? fps;

  const FileMetadata({
    required this.captured,
    required this.filename,
    required this.sizeBytes,
    this.path,
    this.width,
    this.height,
    this.deviceModel,
    this.iso,
    this.focalLengthMm,
    this.aperture,
    this.shutterSpeed,
    this.exposureBias,
    this.isVideo = false,
    this.duration,
    this.videoCodec,
    this.audioCodec,
    this.fps,
  });

  int? get megapixels {
    if (width == null || height == null) return null;
    return (width! * height! / 1000000).round();
  }

  /// FHD / HD / 4K / 8K label derived from the smaller dimension — matches
  /// Samsung Gallery's classification behaviour.
  String? get resolutionTier {
    if (width == null || height == null) return null;
    final short = width! < height! ? width! : height!;
    if (short >= 4320) return '8K';
    if (short >= 2160) return '4K';
    if (short >= 1080) return 'FHD';
    if (short >= 720) return 'HD';
    return 'SD';
  }
}

class FileMetadataService {
  FileMetadataService._();
  static final FileMetadataService _instance = FileMetadataService._();
  factory FileMetadataService() => _instance;

  /// The capture moment baked into an image's EXIF, as epoch ms — the
  /// device-independent key the gallery sorts by so every device agrees on
  /// order regardless of clock skew. Reads `EXIF DateTimeOriginal` (when the
  /// shutter fired), falling back to `Image DateTime` (last modified in-camera).
  ///
  /// EXIF timestamps carry no timezone; we interpret them in the ORIGIN
  /// device's local zone. That is harmless for ordering because the value is
  /// computed once here and then shipped verbatim in the createFile op — every
  /// device stores the identical integer. Returns null when there is no EXIF
  /// date (screenshots, downloads, PNGs, non-photos); the caller then falls
  /// back to the op's HLC wall, which is also identical across devices.
  static Future<int?> captureEpochFromImageBytes(Uint8List bytes) async {
    try {
      final tags = await readExifFromBytes(bytes);
      final raw = tags['EXIF DateTimeOriginal']?.printable ??
          tags['Image DateTime']?.printable;
      return _parseExifDate(raw);
    } catch (_) {
      return null;
    }
  }

  /// Parses the EXIF datetime shape `YYYY:MM:DD HH:MM:SS` into epoch ms, or
  /// null if absent/malformed/zeroed.
  static int? _parseExifDate(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    // The date portion uses ':' separators EXIF-style; the time uses ':' too.
    // Split on the space, then rebuild an ISO-ish string DateTime can parse.
    final parts = s.split(' ');
    if (parts.length != 2) return null;
    final date = parts[0].split(':'); // [YYYY, MM, DD]
    if (date.length != 3) return null;
    // A common "no date" sentinel some cameras write.
    if (date[0] == '0000') return null;
    final iso = '${date[0]}-${date[1]}-${date[2]} ${parts[1]}';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return null;
    final ms = dt.millisecondsSinceEpoch;
    return ms > 0 ? ms : null;
  }

  /// Extracts as much of the info sheet's payload as we can. Two layered
  /// sources, most-informative-first:
  ///
  ///   1. photo_manager AssetEntity — width, height, duration, mimeType.
  ///      Cheap, no I/O beyond a MediaStore lookup.
  ///
  ///   2. Local plaintext bytes — full EXIF (device, ISO, aperture, shutter,
  ///      focal, exposure bias). Only fires when the file is either a local
  ///      original (localPath is set) or a decrypted copy exists in cache.
  ///
  /// Cloud-encrypted bytes are DELIBERATELY skipped — fetching just to read
  /// EXIF would blow through the user's data / cache limit. Files that are
  /// cloud-only render "no EXIF" until the viewer's own caching writes a
  /// decrypted copy, at which point subsequent info-sheet opens pick it up.
  Future<FileMetadata> extract(CnestFile file) async {
    final ext = file.filename.split('.').last.toLowerCase();
    final isVideo = const {'mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v'}
        .contains(ext);

    int? width;
    int? height;
    Duration? duration;
    String? deviceModel;
    int? iso;
    double? focal;
    double? aperture;
    String? shutter;
    double? exposureBias;

    String? videoCodec;
    String? audioCodec;
    int? fps;

    // TIER 1 — AssetEntity for dimensions + duration.
    if (file.assetId != null) {
      try {
        final asset = await AssetEntity.fromId(file.assetId!);
        if (asset != null) {
          if (asset.width > 0) width = asset.width;
          if (asset.height > 0) height = asset.height;
          if (isVideo && asset.duration > 0) {
            duration = Duration(seconds: asset.duration);
          }
        }
      } catch (e) {
        debugPrint('FileMetadata AssetEntity lookup failed: $e');
      }
    }

    // TIER 1b — MP4 container parse for the video codec / audio codec / fps
    // row. Only fires when we have a local file to peek at; cloud-only
    // videos degrade to size · dimensions · FHD/HD tier only.
    if (isVideo) {
      final path = file.localPath;
      if (path != null) {
        try {
          final f = File(path);
          if (await f.exists()) {
            final mp4 = await Mp4MetadataParser.parse(f);
            if (mp4 != null) {
              videoCodec = mp4.videoCodec;
              audioCodec = mp4.audioCodec;
              fps = mp4.fps;
              width ??= mp4.width;
              height ??= mp4.height;
              duration ??= mp4.duration;
            }
          }
        } catch (e) {
          debugPrint('Mp4MetadataParser failed on $path: $e');
        }
      }
    }

    // TIER 2 — EXIF from local bytes. Skip for videos (JPEG EXIF only).
    if (!isVideo) {
      final bytes = await _tryReadLocalBytes(file);
      if (bytes != null) {
        try {
          final tags = await readExifFromBytes(bytes);
          deviceModel = tags['Image Model']?.printable.trim();
          iso = _intOf(tags['EXIF ISOSpeedRatings']);
          focal = _ratioOf(tags['EXIF FocalLength']);
          aperture = _ratioOf(tags['EXIF FNumber']);
          shutter = _formatShutter(tags['EXIF ExposureTime']);
          exposureBias = _ratioOf(tags['EXIF ExposureBiasValue']);
          // Fall back to EXIF dimensions if AssetEntity didn't fill them.
          width ??= _intOf(tags['EXIF ExifImageWidth']) ??
              _intOf(tags['Image ImageWidth']);
          height ??= _intOf(tags['EXIF ExifImageLength']) ??
              _intOf(tags['Image ImageLength']);
        } catch (e) {
          debugPrint('EXIF parse failed: $e');
        }
      }
    }

    // Only surface the path when the file is CURRENTLY on disk. A stale
    // `localPath` from a photo that was later deleted from the phone's
    // gallery would otherwise render "/Internal storage/DCIM/Camera" while
    // the vault is now serving from cloud+cache — misleading and awkward.
    String? livePath;
    if (file.localPath != null) {
      try {
        if (await File(file.localPath!).exists()) {
          livePath = _prettyPath(file.localPath);
        }
      } catch (_) {}
    }

    return FileMetadata(
      captured: file.createdAt,
      filename: file.filename,
      sizeBytes: file.sizeBytes,
      path: livePath,
      width: width,
      height: height,
      deviceModel: deviceModel,
      iso: iso,
      focalLengthMm: focal,
      aperture: aperture,
      shutterSpeed: shutter,
      exposureBias: exposureBias,
      isVideo: isVideo,
      duration: duration,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      fps: fps,
    );
  }

  /// Returns raw JPEG bytes if we can read them without hitting the cloud.
  /// Prefers `localPath` (the original in the phone's gallery), falls back
  /// to any already-decrypted plaintext the viewer previously wrote to
  /// temp. Returns null when neither exists — the caller degrades to
  /// "no EXIF" instead of triggering a download.
  Future<Uint8List?> _tryReadLocalBytes(CnestFile file) async {
    if (file.localPath != null) {
      try {
        final f = File(file.localPath!);
        if (await f.exists()) return await f.readAsBytes();
      } catch (_) {}
    }
    if (file.cloudId != null) {
      try {
        final cacheDir = await getTemporaryDirectory();
        final f = File('${cacheDir.path}/${file.cloudId}_decrypted.jpg');
        if (await f.exists()) return await f.readAsBytes();
      } catch (_) {}
    }
    return null;
  }

  // ---- EXIF parsing helpers ------------------------------------------------

  /// Reads the first int out of an EXIF tag. Tags can be `IfdInts`,
  /// `IfdShorts`, or occasionally a printable string — walk them via the
  /// `.toList()` accessor so we don't care which concrete subtype the
  /// package returned.
  int? _intOf(IfdTag? tag) {
    if (tag == null) return null;
    final list = tag.values.toList();
    if (list.isEmpty) return null;
    final first = list.first;
    if (first is int) return first;
    return int.tryParse(tag.printable);
  }

  /// Parses a rational EXIF tag (e.g. focal=23/1, aperture=180/100) into a
  /// double. Falls back to `double.tryParse` for the rare camera that
  /// writes plain floats instead of ratios.
  double? _ratioOf(IfdTag? tag) {
    if (tag == null) return null;
    final list = tag.values.toList();
    if (list.isNotEmpty) {
      final first = list.first;
      if (first is Ratio) {
        if (first.denominator == 0) return null;
        return first.numerator / first.denominator;
      }
      if (first is num) return first.toDouble();
    }
    return double.tryParse(tag.printable);
  }

  /// EXIF shutter speed comes as a Ratio (e.g. 1/13). We display it in the
  /// same "1/13 s" fractional form Samsung Gallery uses when the exposure
  /// is under a second, and as "1.5 s" for longer exposures.
  String? _formatShutter(IfdTag? tag) {
    if (tag == null) return null;
    final list = tag.values.toList();
    if (list.isNotEmpty) {
      final first = list.first;
      if (first is Ratio) {
        if (first.denominator == 0) return null;
        final seconds = first.numerator / first.denominator;
        if (seconds >= 1) return '${seconds.toStringAsFixed(1)} s';
        // Reduce the fraction to keep the display tidy (1/13 not 100/1300).
        final denom = (first.denominator / first.numerator).round();
        return '1/$denom s';
      }
    }
    return tag.printable;
  }
}

/// Samsung shows `/Internal storage/DCIM/Camera` — collapse the raw Android
/// path so we render the same friendly stub. Only the two most common
/// prefixes are transformed; anything else stays verbatim so power users
/// still get a truthful reading.
String? _prettyPath(String? absolutePath) {
  if (absolutePath == null) return null;
  const emu = '/storage/emulated/0/';
  const sd = '/sdcard/';
  String rel;
  if (absolutePath.startsWith(emu)) {
    rel = absolutePath.substring(emu.length);
  } else if (absolutePath.startsWith(sd)) {
    rel = absolutePath.substring(sd.length);
  } else {
    final dirEnd = absolutePath.lastIndexOf('/');
    return dirEnd > 0 ? absolutePath.substring(0, dirEnd) : absolutePath;
  }
  final dirEnd = rel.lastIndexOf('/');
  if (dirEnd < 0) return '/Internal storage';
  return '/Internal storage/${rel.substring(0, dirEnd)}';
}
