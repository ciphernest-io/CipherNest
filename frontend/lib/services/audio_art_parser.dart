import 'dart:convert';
import 'dart:typed_data';

/// The human-readable tags Samsung Music surfaces. Any field may be null when
/// the container doesn't carry it.
class AudioTags {
  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
  });

  bool get isEmpty =>
      title == null &&
      artist == null &&
      album == null &&
      albumArtist == null &&
      genre == null;
}

/// Embedded cover art, extracted from the plaintext bytes at upload time —
/// the only moment they're free. Pure, allocation-light readers for the two
/// containers CipherNest ingests:
///
///   mp3          → ID3v2.3 / v2.4 `APIC` frame
///   m4a/aac/mp4  → `moov/udta/meta/ilst/covr/data` (the `meta` atom is a
///                  FULL atom — 4 version/flags bytes after its header —
///                  which is why this is a focused reader instead of an
///                  Mp4MetadataParser extension)
///
/// NEGATIVE CONTRACT: returns null on ANYTHING unexpected — v2.2 tags,
/// unsynchronised tags, truncation, absent art, unknown containers. A
/// missing thumbnail is a placeholder, never a crash and never a bad
/// decrypt.
class AudioArtParser {
  AudioArtParser._();

  static Uint8List? extract(Uint8List bytes, String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    try {
      return switch (ext) {
        'mp3' => _id3v2Apic(bytes),
        'm4a' || 'aac' || 'mp4' => _mp4Covr(bytes),
        _ => null,
      };
    } catch (_) {
      return null; // Belt: a malformed file must never throw out of here.
    }
  }

  /// Human-readable tags (title/artist/album/album-artist/genre). Same
  /// negative contract as [extract]: null on anything unexpected.
  static AudioTags? tags(Uint8List bytes, String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    try {
      return switch (ext) {
        'mp3' => _id3v2Tags(bytes),
        'm4a' || 'aac' || 'mp4' => _mp4Tags(bytes),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  // ---- ID3v2 ------------------------------------------------------------

  static AudioTags? _id3v2Tags(Uint8List b) {
    if (b.length < 10) return null;
    if (b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) return null; // 'ID3'
    final major = b[3];
    if (major != 3 && major != 4) return null;
    final flags = b[5];
    if (flags & 0x80 != 0) return null; // unsynchronised: bail
    final tagSize = _syncsafe(b, 6);
    if (tagSize == null) return null;
    var pos = 10;
    final tagEnd = 10 + tagSize;
    if (tagEnd > b.length) return null;

    if (flags & 0x40 != 0) {
      if (pos + 4 > tagEnd) return null;
      if (major == 3) {
        pos += 4 + _uint32(b, pos);
      } else {
        final extSize = _syncsafe(b, pos);
        if (extSize == null || extSize < 4) return null;
        pos += extSize;
      }
      if (pos > tagEnd) return null;
    }

    String? title, artist, album, albumArtist, genre;
    while (pos + 10 <= tagEnd) {
      if (b[pos] == 0) break; // padding
      final id = String.fromCharCodes(b, pos, pos + 4);
      final frameSize =
          major == 4 ? _syncsafe(b, pos + 4) : _uint32(b, pos + 4);
      if (frameSize == null || frameSize <= 0) break;
      final dataStart = pos + 10;
      final dataEnd = dataStart + frameSize;
      if (dataEnd > tagEnd) break;
      switch (id) {
        case 'TIT2':
          title ??= _id3Text(b, dataStart, dataEnd);
        case 'TPE1':
          artist ??= _id3Text(b, dataStart, dataEnd);
        case 'TALB':
          album ??= _id3Text(b, dataStart, dataEnd);
        case 'TPE2':
          albumArtist ??= _id3Text(b, dataStart, dataEnd);
        case 'TCON':
          genre ??= _cleanGenre(_id3Text(b, dataStart, dataEnd));
      }
      pos = dataEnd;
    }
    final t = AudioTags(
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      genre: genre,
    );
    return t.isEmpty ? null : t;
  }

  /// Decodes an ID3v2 text frame body (leading encoding byte + text).
  static String? _id3Text(Uint8List b, int start, int end) {
    if (start >= end) return null;
    final enc = b[start];
    final body = Uint8List.sublistView(b, start + 1, end);
    String out;
    switch (enc) {
      case 3:
        out = utf8.decode(body, allowMalformed: true);
      case 1:
        out = _utf16(body, hasBom: true);
      case 2:
        out = _utf16(body, hasBom: false, bigEndian: true);
      default:
        out = latin1.decode(body, allowInvalid: true);
    }
    out = String.fromCharCodes(out.codeUnits.where((c) => c != 0)).trim();
    return out.isEmpty ? null : out;
  }

  static String _utf16(Uint8List b, {required bool hasBom, bool bigEndian = false}) {
    var i = 0;
    var be = bigEndian;
    if (hasBom && b.length >= 2) {
      if (b[0] == 0xFF && b[1] == 0xFE) {
        be = false;
        i = 2;
      } else if (b[0] == 0xFE && b[1] == 0xFF) {
        be = true;
        i = 2;
      }
    }
    final units = <int>[];
    for (; i + 1 < b.length; i += 2) {
      units.add(be ? (b[i] << 8) | b[i + 1] : (b[i + 1] << 8) | b[i]);
    }
    return String.fromCharCodes(units);
  }

  /// TCON can be a raw name, an ID3v1 index like "(17)", or "(17)Rock".
  /// Keep the readable name; drop a bare numeric reference.
  static String? _cleanGenre(String? g) {
    if (g == null) return null;
    var s = g;
    final m = RegExp(r'^\((\d+)\)').firstMatch(s);
    if (m != null) s = s.substring(m.end);
    s = s.trim();
    return s.isEmpty ? null : s;
  }

  static Uint8List? _id3v2Apic(Uint8List b) {
    if (b.length < 10) return null;
    if (b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) return null; // 'ID3'
    final major = b[3];
    if (major != 3 && major != 4) return null; // v2.2 (and exotics) → null
    final flags = b[5];
    if (flags & 0x80 != 0) return null; // unsynchronisation: bail, not de-sync
    final tagSize = _syncsafe(b, 6);
    if (tagSize == null) return null;
    var pos = 10;
    final tagEnd = 10 + tagSize;
    if (tagEnd > b.length) return null;

    // Extended header: v2.3 size EXCLUDES its own 4 size bytes (plain
    // uint32); v2.4 size INCLUDES itself (syncsafe).
    if (flags & 0x40 != 0) {
      if (pos + 4 > tagEnd) return null;
      if (major == 3) {
        pos += 4 + _uint32(b, pos);
      } else {
        final extSize = _syncsafe(b, pos);
        if (extSize == null || extSize < 4) return null;
        pos += extSize;
      }
      if (pos > tagEnd) return null;
    }

    while (pos + 10 <= tagEnd) {
      // Padding (zeroed id) ends the frame list.
      if (b[pos] == 0) return null;
      final id = String.fromCharCodes(b, pos, pos + 4);
      final frameSize = major == 4 ? _syncsafe(b, pos + 4) : _uint32(b, pos + 4);
      if (frameSize == null || frameSize <= 0) return null;
      final dataStart = pos + 10;
      final dataEnd = dataStart + frameSize;
      if (dataEnd > tagEnd) return null;

      if (id == 'APIC') {
        return _apicPayload(b, dataStart, dataEnd);
      }
      pos = dataEnd;
    }
    return null;
  }

  static Uint8List? _apicPayload(Uint8List b, int start, int end) {
    var p = start;
    if (p >= end) return null;
    final encoding = b[p++]; // 0 latin1, 1 utf16, 2 utf16be, 3 utf8
    // MIME: latin-1, null-terminated.
    while (p < end && b[p] != 0) {
      p++;
    }
    if (p >= end) return null;
    p++; // past mime null
    if (p >= end) return null;
    p++; // picture-type byte
    // Description: single-null for encodings 0/3, double-null for 1/2.
    if (encoding == 1 || encoding == 2) {
      while (p + 1 < end && !(b[p] == 0 && b[p + 1] == 0)) {
        p += 2;
      }
      if (p + 1 >= end) return null;
      p += 2;
    } else {
      while (p < end && b[p] != 0) {
        p++;
      }
      if (p >= end) return null;
      p++;
    }
    if (p >= end) return null;
    return Uint8List.sublistView(b, p, end);
  }

  static int? _syncsafe(Uint8List b, int at) {
    if (at + 4 > b.length) return null;
    if ((b[at] | b[at + 1] | b[at + 2] | b[at + 3]) & 0x80 != 0) return null;
    return (b[at] << 21) | (b[at + 1] << 14) | (b[at + 2] << 7) | b[at + 3];
  }

  static int _uint32(Uint8List b, int at) =>
      (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

  // ---- MP4 / M4A --------------------------------------------------------

  static AudioTags? _mp4Tags(Uint8List b) {
    final moov = _child(b, 0, b.length, 'moov');
    if (moov == null) return null;
    final udta = _child(b, moov.$1, moov.$2, 'udta');
    if (udta == null) return null;
    final meta = _child(b, udta.$1, udta.$2, 'meta');
    if (meta == null) return null;
    final metaStart = meta.$1 + 4; // meta is a FULL atom
    if (metaStart > meta.$2) return null;
    final ilst = _child(b, metaStart, meta.$2, 'ilst');
    if (ilst == null) return null;

    String? read(String atom) {
      final a = _child(b, ilst.$1, ilst.$2, atom);
      if (a == null) return null;
      final data = _child(b, a.$1, a.$2, 'data');
      if (data == null) return null;
      final s = data.$1 + 8; // 4 type + 4 locale bytes precede the value
      if (s >= data.$2) return null;
      final out = utf8
          .decode(Uint8List.sublistView(b, s, data.$2), allowMalformed: true)
          .trim();
      return out.isEmpty ? null : out;
    }

    // Names begin with the © byte (0xA9).
    final t = AudioTags(
      title: read('©nam'),
      artist: read('©ART'),
      album: read('©alb'),
      albumArtist: read('aART'),
      genre: read('©gen'),
    );
    return t.isEmpty ? null : t;
  }

  static Uint8List? _mp4Covr(Uint8List b) {
    final moov = _child(b, 0, b.length, 'moov');
    if (moov == null) return null;
    final udta = _child(b, moov.$1, moov.$2, 'udta');
    if (udta == null) return null;
    final meta = _child(b, udta.$1, udta.$2, 'meta');
    if (meta == null) return null;
    // meta is a FULL atom: 4 version/flags bytes precede its children.
    final metaStart = meta.$1 + 4;
    if (metaStart > meta.$2) return null;
    final ilst = _child(b, metaStart, meta.$2, 'ilst');
    if (ilst == null) return null;
    final covr = _child(b, ilst.$1, ilst.$2, 'covr');
    if (covr == null) return null;
    final data = _child(b, covr.$1, covr.$2, 'data');
    if (data == null) return null;
    // data payload: 4 bytes type + 4 bytes locale, then the image.
    final imgStart = data.$1 + 8;
    if (imgStart >= data.$2) return null;
    return Uint8List.sublistView(b, imgStart, data.$2);
  }

  /// First child atom named [type] inside [start, end): returns its
  /// (payloadStart, payloadEnd). 64-bit/to-end sizes bail null.
  static (int, int)? _child(Uint8List b, int start, int end, String type) {
    var pos = start;
    while (pos + 8 <= end) {
      final size = _uint32(b, pos);
      if (size < 8) return null; // incl. size==0 (to-end) and size==1 (64-bit)
      final atomEnd = pos + size;
      if (atomEnd > end) return null;
      final name = String.fromCharCodes(b, pos + 4, pos + 8);
      if (name == type) return (pos + 8, atomEnd);
      pos = atomEnd;
    }
    return null;
  }
}
