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

  /// The recording device, from `moov/udta` vendor atoms. Samsung Camera
  /// writes the model into `@mod` (newer One UI: the marketing name, e.g.
  /// "Galaxy A55 5G" — the same string Samsung Gallery shows). Null when
  /// the producer wrote no such atom (most non-camera videos).
  final String? deviceModel;

  const Mp4Metadata({
    this.videoCodec,
    this.audioCodec,
    this.fps,
    this.width,
    this.height,
    this.duration,
    this.deviceModel,
  });
}

/// Minimal ISOBMFF (MP4 / MOV / M4V / 3GP) atom-walker.
///
/// It only reads what the info sheet actually renders — codec fourccs in
/// `stsd`, frame count in `stts`, timescale in `mdhd`, dimensions in
/// `tkhd`, handler kind in `hdlr`. Everything else is skipped by size.
///
/// moov is located by walking TOP-LEVEL atoms with RandomAccessFile seeks:
/// read each 8/16-byte atom header, skip the atom by its declared size,
/// stop at `moov` and read just its payload. This is layout-agnostic —
/// camera output (Samsung included) writes `ftyp, mdat, moov` with moov at
/// the TAIL, and a fixed-size head/tail buffer scan cannot find it (a tail
/// window is not atom-aligned, so scanning it walks mdat garbage). Total IO
/// is a handful of header reads plus the moov payload itself.
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

      // ftyp atom must open any ISOBMFF file.
      final head = await raf.read(16);
      if (!_looksLikeIsobmff(head)) return null;

      final moovBytes = await _readMoov(raf, size);
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
        deviceModel: _udtaDeviceModel(moovBytes),
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

  /// Upper bound on how much moov we load. Real moov atoms are tens of KB
  /// to a few MB (sample tables grow with clip length); 32 MB is far past
  /// any camera output and just guards against a corrupt size field.
  static const int _maxMoovBytes = 32 * 1024 * 1024;

  static bool _looksLikeIsobmff(Uint8List buf) {
    if (buf.length < 8) return false;
    // The first atom in every ISOBMFF file is `ftyp`, always.
    return String.fromCharCodes(buf.sublist(4, 8)) == 'ftyp';
  }

  /// Walks top-level atoms by seeking (never reading atom bodies) and
  /// returns the moov payload, wherever in the file it lives. Null when
  /// absent or the structure is corrupt.
  static Future<Uint8List?> _readMoov(RandomAccessFile raf, int size) async {
    int offset = 0;
    while (offset + 8 <= size) {
      await raf.setPosition(offset);
      final hdr = await raf.read(16);
      if (hdr.length < 8) return null;
      int atomSize = _readUint32(hdr, 0);
      int headerSize = 8;
      final type = String.fromCharCodes(hdr.sublist(4, 8));
      if (atomSize == 1) {
        // 64-bit extended size (large mdat).
        if (hdr.length < 16) return null;
        atomSize = _readUint64(hdr, 8);
        headerSize = 16;
      } else if (atomSize == 0) {
        atomSize = size - offset; // extends to EOF
      }
      if (atomSize < headerSize) return null;
      if (type == 'moov') {
        final payloadLen =
            (atomSize - headerSize).clamp(0, _maxMoovBytes).toInt();
        await raf.setPosition(offset + headerSize);
        return raf.read(payloadLen);
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

  /// Device model from `moov/udta`. Vendor-specific: Samsung writes `@mod`
  /// (and `@man` for the make), some producers use QuickTime's `©mod` or
  /// 3GPP's `auth`/`modl`. Payloads may carry version/lang prefix bytes, so
  /// extraction is tolerant: skip leading control bytes, take the printable
  /// run.
  static String? _udtaDeviceModel(Uint8List moov) {
    final udta = _childOf(moov, 'udta');
    if (udta == null) return null;
    for (final name in const ['@mod', '©mod', 'modl', 'auth']) {
      final payload = _childOf(udta, name);
      if (payload == null) continue;
      final s = _printableString(payload);
      if (s != null) return s;
    }
    return null;
  }

  /// Extracts the model string from a vendor atom payload.
  ///
  /// Samsung writes its model atom in the 3GPP FullBox layout: 4 bytes
  /// version/flags, then a 2-byte PACKED ISO-639 language code, then the
  /// string. The language's second byte is usually a printable high byte
  /// ("eng" packs to 0x15C7), so skipping only control bytes leaked it
  /// into the name — "ÇGalaxy A55 5G" on a real Galaxy A55. Bytes 4-5 are
  /// only treated as a language when they actually decode as one, so raw
  /// string payloads are unaffected.
  static String? _printableString(Uint8List payload) {
    if (payload.length > 6 &&
        payload[0] == 0 &&
        _isPackedIsoLanguage(payload[4], payload[5])) {
      final s = _printableRun(payload, 6);
      if (s != null) return s;
    }
    return _printableRun(payload, 0);
  }

  /// ISO-639-2/T packed language: three 5-bit letters, each 1..26.
  static bool _isPackedIsoLanguage(int hi, int lo) {
    final packed = (hi << 8) | lo;
    for (final c in [
      (packed >> 10) & 0x1F,
      (packed >> 5) & 0x1F,
      packed & 0x1F,
    ]) {
      if (c < 1 || c > 26) return false;
    }
    return true;
  }

  /// Skips leading non-ASCII-printable bytes from [from], returns the first
  /// ASCII-printable run when it looks like a real model string (2..64
  /// chars, contains a letter). ASCII-only on purpose: device model
  /// strings are ASCII, and high bytes here are always layout leakage.
  static String? _printableRun(Uint8List payload, int from) {
    var start = from;
    while (start < payload.length &&
        (payload[start] < 0x20 || payload[start] >= 0x7F)) {
      start++;
    }
    var end = start;
    while (end < payload.length &&
        payload[end] >= 0x20 &&
        payload[end] < 0x7F) {
      end++;
    }
    if (end - start < 2 || end - start > 64) return null;
    final s = String.fromCharCodes(payload.sublist(start, end)).trim();
    if (s.length < 2 || !RegExp(r'[A-Za-z]').hasMatch(s)) return null;
    return s;
  }

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
  ///
  /// Phone cameras record sensor-native LANDSCAPE (e.g. 1920x1080) and mark
  /// portrait clips with a ±90° matrix in the same atom — the size the user
  /// sees (and Samsung Gallery shows) is the rotated one, so a quarter-turn
  /// matrix swaps the reported dimensions (1920x1080 → 1080x1920).
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

    // The 3x3 transform matrix (nine 32-bit fields) sits immediately before
    // width. A quarter turn has zero scale terms and nonzero rotation terms:
    // matrix rows are [a b u][c d v][x y w]; 90°/270° ⇒ a=d=0, b,c≠0.
    final mOff = wOff - 36;
    final a = _readUint32(tkhd, mOff);
    final b = _readUint32(tkhd, mOff + 4);
    final c = _readUint32(tkhd, mOff + 12);
    final d = _readUint32(tkhd, mOff + 16);
    if (a == 0 && d == 0 && b != 0 && c != 0) return (h, w);

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
