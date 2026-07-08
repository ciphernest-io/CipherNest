import 'dart:io';

import 'package:flutter/foundation.dart';

/// What a video's container header can tell us without decoding a frame.
/// Every field is nullable so a partial parse (unusual codec, atom out of
/// place, non-mp4 container) still returns useful data — the info sheet
/// only renders non-null fields.
class Mp4Metadata {
  final String? videoCodec; // "H.264", "HEVC", "AV1", …
  final String? audioCodec; // "AAC", "Opus", …
  final int? fps;
  final int? width;
  final int? height;
  final Duration? duration;

  const Mp4Metadata({
    this.videoCodec,
    this.audioCodec,
    this.fps,
    this.width,
    this.height,
    this.duration,
  });
}

/// Minimal ISOBMFF (MP4 / MOV / M4V / 3GP) atom-walker.
///
/// It only reads what the info sheet actually renders — codec fourccs in
/// `stsd`, frame count in `stts`, timescale in `mdhd`, dimensions in
/// `tkhd`, handler kind in `hdlr`. Everything else is skipped by size.
///
/// The parser buffers the file lazily: it reads up to ~2 MB from the start,
/// which covers the moov atom in most modern-camera output (Samsung
/// included). Files where moov lives at the tail (fastStart=false) also
/// work — we look for a `moov` fourcc in a small tail chunk if the head
/// scan came up empty. Files larger than a couple of GB stream through
/// `RandomAccessFile` seek/read rather than being fully loaded.
///
/// Non-mp4 containers (`.mkv`, `.webm`, `.avi`) are detected by the
/// missing `ftyp` header and simply return null; the caller renders a
/// video info row without codec/fps.
class Mp4MetadataParser {
  Mp4MetadataParser._();

  static Future<Mp4Metadata?> parse(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final size = await raf.length();
      if (size < 16) return null;

      // ftyp atom must appear near the start of any ISOBMFF file.
      final headBuf = await raf.read(_headScanBytes.clamp(0, size));
      if (!_looksLikeIsobmff(headBuf)) return null;

      Uint8List? moovBytes = _findAtomInBuffer(headBuf, 'moov');
      if (moovBytes == null && size > _headScanBytes) {
        // Faststart=false layout — moov lives after mdat. Read the tail.
        final tailStart = (size - _tailScanBytes).clamp(0, size);
        await raf.setPosition(tailStart);
        final tailBuf = await raf.read(size - tailStart);
        moovBytes = _findAtomInBuffer(tailBuf, 'moov');
      }
      if (moovBytes == null) return null;

      String? videoCodec;
      String? audioCodec;
      int? fps;
      int? width;
      int? height;
      Duration? duration;

      // Walk each trak inside moov.
      for (final trak in _childrenOf(moovBytes, 'trak')) {
        final tkhd = _childOf(trak, 'tkhd');
        final mdia = _childOf(trak, 'mdia');
        if (mdia == null) continue;
        final hdlr = _childOf(mdia, 'hdlr');
        final mdhd = _childOf(mdia, 'mdhd');
        final minf = _childOf(mdia, 'minf');
        final stbl = minf == null ? null : _childOf(minf, 'stbl');
        final stsd = stbl == null ? null : _childOf(stbl, 'stsd');
        final stts = stbl == null ? null : _childOf(stbl, 'stts');

        final handler = hdlr == null ? null : _hdlrType(hdlr);

        if (handler == 'vide' && stsd != null) {
          final fourcc = _sampleEntryFourcc(stsd);
          videoCodec = _mapVideoCodec(fourcc);

          // Dimensions: prefer tkhd's post-transform width/height, which
          // are the values Samsung Gallery renders. Falls back to
          // sample-entry visual-width/height if tkhd is unreadable.
          final tkDim = tkhd == null ? null : _tkhdDimensions(tkhd);
          if (tkDim != null) {
            width = tkDim.$1;
            height = tkDim.$2;
          }

          // Duration + FPS from mdhd (timescale, duration) and stts
          // (sum of sample counts). fps = samples * timescale / duration.
          if (mdhd != null && stts != null) {
            final ts = _mdhdTimescale(mdhd);
            final durUnits = _mdhdDuration(mdhd);
            final sampleCount = _sttsSampleCount(stts);
            if (ts != null && durUnits != null && sampleCount != null) {
              if (durUnits > 0) {
                duration =
                    Duration(milliseconds: (durUnits * 1000 ~/ ts));
                fps = (sampleCount * ts / durUnits).round();
              }
            }
          }
        } else if (handler == 'soun' && stsd != null) {
          final fourcc = _sampleEntryFourcc(stsd);
          audioCodec = _mapAudioCodec(fourcc);
        }
      }

      return Mp4Metadata(
        videoCodec: videoCodec,
        audioCodec: audioCodec,
        fps: fps,
        width: width,
        height: height,
        duration: duration,
      );
    } catch (e) {
      debugPrint('Mp4MetadataParser: $e');
      return null;
    } finally {
      await raf?.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Atom navigation
  // ---------------------------------------------------------------------------

  /// How much of the file to load up front looking for moov. 2 MB is enough
  /// for a faststart-optimized moov even on a 4K 60 fps clip.
  static const int _headScanBytes = 2 * 1024 * 1024;

  /// Tail scan window when moov is at the end of the file. Same 2 MB gets
  /// us covered for videos up to a few hours long.
  static const int _tailScanBytes = 2 * 1024 * 1024;

  static bool _looksLikeIsobmff(Uint8List buf) {
    if (buf.length < 8) return false;
    // The first atom in every ISOBMFF file is `ftyp`, always.
    return String.fromCharCodes(buf.sublist(4, 8)) == 'ftyp';
  }

  /// Scans a buffer for the first occurrence of a top-level atom with the
  /// given fourcc and returns its payload (excluding the 8-byte header).
  static Uint8List? _findAtomInBuffer(Uint8List buf, String fourcc) {
    int offset = 0;
    while (offset + 8 <= buf.length) {
      final size = _readUint32(buf, offset);
      final type = String.fromCharCodes(buf.sublist(offset + 4, offset + 8));
      int atomSize = size;
      int headerSize = 8;
      if (size == 1) {
        // 64-bit extended size
        if (offset + 16 > buf.length) return null;
        atomSize = _readUint64(buf, offset + 8);
        headerSize = 16;
      } else if (size == 0) {
        atomSize = buf.length - offset; // extends to EOF
      }
      if (atomSize < headerSize) return null;
      if (type == fourcc) {
        final payloadStart = offset + headerSize;
        final payloadEnd =
            (offset + atomSize).clamp(payloadStart, buf.length);
        return Uint8List.sublistView(buf, payloadStart, payloadEnd);
      }
      offset += atomSize;
    }
    return null;
  }

  /// Yields all direct children of a container atom's payload with the
  /// given fourcc. Used to walk repeated atoms like `trak`.
  static Iterable<Uint8List> _childrenOf(
    Uint8List payload,
    String fourcc,
  ) sync* {
    int offset = 0;
    while (offset + 8 <= payload.length) {
      final size = _readUint32(payload, offset);
      final type = String.fromCharCodes(payload.sublist(offset + 4, offset + 8));
      int atomSize = size;
      int headerSize = 8;
      if (size == 1) {
        if (offset + 16 > payload.length) return;
        atomSize = _readUint64(payload, offset + 8);
        headerSize = 16;
      } else if (size == 0) {
        atomSize = payload.length - offset;
      }
      if (atomSize < headerSize) return;
      final payloadStart = offset + headerSize;
      final payloadEnd =
          (offset + atomSize).clamp(payloadStart, payload.length);
      if (type == fourcc) {
        yield Uint8List.sublistView(payload, payloadStart, payloadEnd);
      }
      offset += atomSize;
    }
  }

  /// First child of a container with the given fourcc.
  static Uint8List? _childOf(Uint8List payload, String fourcc) {
    for (final c in _childrenOf(payload, fourcc)) {
      return c;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Field extractors for the specific atoms we care about
  // ---------------------------------------------------------------------------

  /// hdlr atom layout: 4 flags + 4 pre_defined + 4 handler_type + rest.
  /// The handler_type is a 4-char fourcc like `vide`, `soun`, `hint`.
  static String? _hdlrType(Uint8List hdlrPayload) {
    if (hdlrPayload.length < 12) return null;
    return String.fromCharCodes(hdlrPayload.sublist(8, 12));
  }

  /// mdhd atom's timescale field. v0 layout: 4 flags + 4 ctime + 4 mtime
  /// + 4 timescale + 4 duration + …. v1 doubles the ctime/mtime/duration
  /// fields to 8 bytes each.
  static int? _mdhdTimescale(Uint8List mdhd) {
    if (mdhd.length < 4) return null;
    final version = mdhd[0];
    final off = version == 1 ? 4 + 8 + 8 : 4 + 4 + 4;
    if (mdhd.length < off + 4) return null;
    return _readUint32(mdhd, off);
  }

  /// mdhd atom's duration in timescale units.
  static int? _mdhdDuration(Uint8List mdhd) {
    if (mdhd.length < 4) return null;
    final version = mdhd[0];
    if (version == 1) {
      final off = 4 + 8 + 8 + 4;
      if (mdhd.length < off + 8) return null;
      return _readUint64(mdhd, off);
    }
    final off = 4 + 4 + 4 + 4;
    if (mdhd.length < off + 4) return null;
    return _readUint32(mdhd, off);
  }

  /// stts sums all sample counts to get the total video-track sample count
  /// (which equals the frame count for video). Layout: 4 flags + 4 entry
  /// count + entries × (4 count + 4 delta).
  static int? _sttsSampleCount(Uint8List stts) {
    if (stts.length < 8) return null;
    final entries = _readUint32(stts, 4);
    int total = 0;
    for (int i = 0; i < entries; i++) {
      final off = 8 + i * 8;
      if (stts.length < off + 8) break;
      total += _readUint32(stts, off);
    }
    return total;
  }

  /// stsd layout: 4 flags + 4 entry_count + entries. Each entry begins with
  /// 4-byte size + 4-byte fourcc — the fourcc IS the codec.
  static String? _sampleEntryFourcc(Uint8List stsd) {
    if (stsd.length < 8 + 8) return null;
    // Skip the header (4+4) then read the first entry's fourcc.
    return String.fromCharCodes(stsd.sublist(8 + 4, 8 + 8));
  }

  /// tkhd width / height are 16.16 fixed-point at offsets that depend on
  /// version. v0: header ends at offset 74 (post-transform 4-byte width,
  /// 4-byte height at 76 and 80). v1: 12 bytes longer for the extended
  /// times, so those fields shift.
  static (int, int)? _tkhdDimensions(Uint8List tkhd) {
    if (tkhd.length < 4) return null;
    final version = tkhd[0];
    final base = version == 1 ? 96 : 84;
    if (tkhd.length < base - 8 + 8) return null;
    final wOff = base - 8;
    final hOff = base - 4;
    if (tkhd.length < hOff + 4) return null;
    final w = _readUint32(tkhd, wOff) >> 16;
    final h = _readUint32(tkhd, hOff) >> 16;
    if (w == 0 || h == 0) return null;
    return (w, h);
  }

  // ---------------------------------------------------------------------------
  // Codec fourcc → friendly names
  // ---------------------------------------------------------------------------

  static String? _mapVideoCodec(String? fourcc) {
    if (fourcc == null) return null;
    switch (fourcc.toLowerCase()) {
      case 'avc1':
      case 'avc3':
        return 'H.264';
      case 'hvc1':
      case 'hev1':
        return 'HEVC';
      case 'vp08':
        return 'VP8';
      case 'vp09':
        return 'VP9';
      case 'av01':
        return 'AV1';
      case 'mp4v':
        return 'MPEG-4';
      default:
        return fourcc.toUpperCase();
    }
  }

  static String? _mapAudioCodec(String? fourcc) {
    if (fourcc == null) return null;
    switch (fourcc.toLowerCase()) {
      case 'mp4a':
        return 'AAC';
      case 'opus':
        return 'Opus';
      case 'ac-3':
      case 'ac3 ':
        return 'AC-3';
      case 'ec-3':
        return 'E-AC-3';
      case 'alac':
        return 'ALAC';
      case 'twos':
      case 'sowt':
        return 'PCM';
      default:
        return fourcc.toUpperCase();
    }
  }

  // ---------------------------------------------------------------------------
  // Byte reads (all MP4 fields are big-endian)
  // ---------------------------------------------------------------------------

  static int _readUint32(Uint8List buf, int off) {
    return (buf[off] << 24) |
        (buf[off + 1] << 16) |
        (buf[off + 2] << 8) |
        buf[off + 3];
  }

  static int _readUint64(Uint8List buf, int off) {
    return (_readUint32(buf, off) << 32) | _readUint32(buf, off + 4);
  }
}
