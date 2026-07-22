/// Mp4MetadataParser against realistic container layouts.
///
/// The regression that matters: real camera output (Samsung included)
/// writes `ftyp, mdat, moov` — moov at the TAIL. The old buffer-scan
/// parser could not find it (a fixed tail window isn't atom-aligned), so
/// every on-device clip parsed to null and the video info sheet lost
/// codec / audio / fps / device model on every upload path at once.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/mp4_metadata_parser.dart';

Uint8List atom(String fourcc, List<int> payload) {
  final size = 8 + payload.length;
  return Uint8List.fromList([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...fourcc.codeUnits,
    ...payload,
  ]);
}

/// Atom with the 64-bit extended-size header (size field = 1), as large
/// mdat atoms use.
Uint8List atom64(String fourcc, List<int> payload) {
  final size = 16 + payload.length;
  return Uint8List.fromList([
    0, 0, 0, 1,
    ...fourcc.codeUnits,
    0, 0, 0, 0,
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...payload,
  ]);
}

List<int> _u32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// tkhd v0 payload: 84 bytes, 16.16 fixed-point width/height at 76/80,
/// 3x3 transform matrix at 40..76. [rotate90] writes the quarter-turn
/// matrix phone cameras use for portrait clips.
List<int> _tkhd(int w, int h, {bool rotate90 = false}) {
  final p = List<int>.filled(84, 0);
  if (rotate90) {
    p.setRange(44, 48, _u32(0x00010000)); // b = 1.0
    p.setRange(52, 56, _u32(0xFFFF0000)); // c = -1.0
    p.setRange(72, 76, _u32(0x40000000)); // w = 1.0 (2.30 fixed)
  }
  p.setRange(76, 80, _u32(w << 16));
  p.setRange(80, 84, _u32(h << 16));
  return p;
}

/// mdhd v0 payload: flags + ctime + mtime + timescale@12 + duration@16.
List<int> _mdhd(int timescale, int duration) => [
      ...List.filled(12, 0),
      ..._u32(timescale),
      ..._u32(duration),
    ];

List<int> _hdlr(String kind) =>
    [...List.filled(8, 0), ...kind.codeUnits];

/// stsd payload: flags + entry_count(1) + one entry whose fourcc IS the
/// codec.
List<int> _stsd(String codecFourcc) => [
      ...List.filled(4, 0),
      ..._u32(1),
      ..._u32(16),
      ...codecFourcc.codeUnits,
      ...List.filled(8, 0),
    ];

/// stts payload: flags + entry_count(1) + (sampleCount, delta).
List<int> _stts(int sampleCount) => [
      ...List.filled(4, 0),
      ..._u32(1),
      ..._u32(sampleCount),
      ..._u32(1000),
    ];

/// A moov equivalent to a 3-second portrait 30fps H.264/AAC Samsung clip:
/// sensor-native 1920x1080 + 90° rotation matrix (displayed 1080x1920),
/// device model in udta/@mod behind the 3GPP version/flags + packed
/// language prefix ("eng" = 0x15C7) — the layout that leaked "Ç" into the
/// name on a real Galaxy A55.
Uint8List samsungMoov() {
  final videoTrak = atom('trak', [
    ...atom('tkhd', _tkhd(1920, 1080, rotate90: true)),
    ...atom('mdia', [
      ...atom('hdlr', _hdlr('vide')),
      ...atom('mdhd', _mdhd(30000, 90000)),
      ...atom('minf', [
        ...atom('stbl', [
          ...atom('stsd', _stsd('avc1')),
          ...atom('stts', _stts(90)),
        ]),
      ]),
    ]),
  ]);
  final audioTrak = atom('trak', [
    ...atom('mdia', [
      ...atom('hdlr', _hdlr('soun')),
      ...atom('minf', [
        ...atom('stbl', [...atom('stsd', _stsd('mp4a'))]),
      ]),
    ]),
  ]);
  final udta = atom('udta', [
    ...atom('@mod', [0, 0, 0, 0, 0x15, 0xC7, ...'Galaxy A55 5G'.codeUnits]),
  ]);
  return atom('moov', [...videoTrak, ...audioTrak, ...udta]);
}

Uint8List _ftyp() =>
    atom('ftyp', [...'isom'.codeUnits, ...List.filled(8, 0)]);

/// mdat body with a decoy "moov" header embedded mid-payload — a correct
/// walker skips mdat whole and must never see it.
List<int> _mdatBodyWithDecoy(int len) {
  final body = List<int>.filled(len, 0x11);
  body.setRange(100, 108, [0, 0, 0, 16, ...'moov'.codeUnits]);
  return body;
}

void _expectSamsungClip(Mp4Metadata? meta) {
  expect(meta, isNotNull);
  expect(meta!.videoCodec, 'H.264');
  expect(meta.audioCodec, 'AAC');
  expect(meta.fps, 30);
  expect(meta.width, 1080);
  expect(meta.height, 1920);
  expect(meta.duration, const Duration(seconds: 3));
  expect(meta.deviceModel, 'Galaxy A55 5G');
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mp4_parser_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> write(String name, List<int> bytes) async {
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(bytes);
    return f;
  }

  test('faststart layout (ftyp, moov, mdat)', () async {
    final f = await write('faststart.mp4', [
      ..._ftyp(),
      ...samsungMoov(),
      ...atom('mdat', List.filled(4096, 0x22)),
    ]);
    _expectSamsungClip(await Mp4MetadataParser.parse(f));
  });

  test('REGRESSION camera layout (ftyp, mdat, moov at tail)', () async {
    // mdat must exceed 2 MB: the old parser only scanned a fixed 2 MB head
    // window (plus a non-atom-aligned tail window that walked mdat garbage),
    // so a smaller file would pass under the old code and prove nothing.
    final f = await write('camera.mp4', [
      ..._ftyp(),
      ...atom('mdat', _mdatBodyWithDecoy(3 * 1024 * 1024)),
      ...samsungMoov(),
    ]);
    _expectSamsungClip(await Mp4MetadataParser.parse(f));
  });

  test('camera layout with 64-bit-size mdat', () async {
    final f = await write('large.mp4', [
      ..._ftyp(),
      ...atom64('mdat', _mdatBodyWithDecoy(64 * 1024)),
      ...samsungMoov(),
    ]);
    _expectSamsungClip(await Mp4MetadataParser.parse(f));
  });

  test('no moov anywhere -> null, no crash', () async {
    final f = await write('truncated.mp4', [
      ..._ftyp(),
      ...atom('mdat', List.filled(1024, 0x33)),
    ]);
    expect(await Mp4MetadataParser.parse(f), isNull);
  });

  test('non-ISOBMFF bytes -> null', () async {
    final f = await write('not_an_mp4.mkv', List.filled(4096, 0x1A));
    expect(await Mp4MetadataParser.parse(f), isNull);
  });

  test('moov without udta -> metadata minus device model', () async {
    final moov = atom('moov', [
      ...atom('trak', [
        ...atom('tkhd', _tkhd(1920, 1080)),
        ...atom('mdia', [
          ...atom('hdlr', _hdlr('vide')),
          ...atom('mdhd', _mdhd(30000, 90000)),
          ...atom('minf', [
            ...atom('stbl', [
              ...atom('stsd', _stsd('hvc1')),
              ...atom('stts', _stts(90)),
            ]),
          ]),
        ]),
      ]),
    ]);
    final f = await write('no_udta.mp4', [
      ..._ftyp(),
      ...atom('mdat', List.filled(512, 0)),
      ...moov,
    ]);
    final meta = await Mp4MetadataParser.parse(f);
    expect(meta!.videoCodec, 'HEVC');
    expect(meta.deviceModel, isNull);
    // Identity matrix (no rotation) — dimensions stay as stored.
    expect(meta.width, 1920);
    expect(meta.height, 1080);
  });

  test('raw @mod payload (no 3GPP language prefix) still parses', () async {
    final moov = atom('moov', [
      ...atom('udta', [
        ...atom('@mod', 'SM-A556E'.codeUnits),
      ]),
    ]);
    final f = await write('raw_mod.mp4', [..._ftyp(), ...moov]);
    final meta = await Mp4MetadataParser.parse(f);
    expect(meta!.deviceModel, 'SM-A556E');
  });
}
