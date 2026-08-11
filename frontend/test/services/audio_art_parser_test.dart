/// AudioArtParser: synthetic ID3v2.3 / v2.4 and m4a fixtures. The parser's
/// contract is null-on-anything-odd — a missing thumb is a placeholder,
/// never a crash.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/services/audio_art_parser.dart';

final _art = Uint8List.fromList([0xDE, 0xAD, 0xBE, 0xEF]);

List<int> _syncsafe(int v) =>
    [(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F];

List<int> _uint32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

/// APIC frame body: latin1 encoding, 'image/jpeg' mime, type 3 (front
/// cover), empty description, then the art bytes.
List<int> _apicBody() => [
      0x00, // encoding: latin-1
      ...'image/jpeg'.codeUnits, 0x00,
      0x03, // picture type
      0x00, // empty description terminator
      ..._art,
    ];

Uint8List _id3(int major, {List<List<int>>? frames, int flags = 0}) {
  final body = (frames ?? const []).expand((f) => f).toList();
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    major, 0x00, // version major, revision
    flags,
    ..._syncsafe(body.length),
    ...body,
  ]);
}

List<int> _frame(String id, List<int> body, {required bool syncsafeSize}) => [
      ...id.codeUnits,
      ...(syncsafeSize ? _syncsafe(body.length) : _uint32(body.length)),
      0x00, 0x00, // frame flags
      ...body,
    ];

List<int> _atom(String type, List<int> body) => [
      ..._uint32(8 + body.length),
      ...type.codeUnits,
      ...body,
    ];

void main() {
  test('ID3v2.3: APIC art extracted (plain uint32 frame sizes)', () {
    final tag = _id3(3, frames: [
      _frame('TIT2', [0x00, ...'Song'.codeUnits], syncsafeSize: false),
      _frame('APIC', _apicBody(), syncsafeSize: false),
    ]);
    expect(AudioArtParser.extract(tag, 'song.mp3'), _art);
  });

  test('ID3v2.4: APIC art extracted (syncsafe frame sizes)', () {
    final tag = _id3(4, frames: [
      _frame('APIC', _apicBody(), syncsafeSize: true),
    ]);
    expect(AudioArtParser.extract(tag, 'song.mp3'), _art);
  });

  test('no APIC / v2.2 / unsync flag / truncated / non-ID3 -> null', () {
    final noArt = _id3(3, frames: [
      _frame('TIT2', [0x00, ...'Song'.codeUnits], syncsafeSize: false),
    ]);
    expect(AudioArtParser.extract(noArt, 'song.mp3'), isNull);

    expect(AudioArtParser.extract(_id3(2), 'song.mp3'), isNull,
        reason: 'v2.2 is out of contract');

    final unsync = _id3(3,
        frames: [_frame('APIC', _apicBody(), syncsafeSize: false)],
        flags: 0x80);
    expect(AudioArtParser.extract(unsync, 'song.mp3'), isNull,
        reason: 'unsynchronised tags bail, never mis-parse');

    final whole = _id3(3,
        frames: [_frame('APIC', _apicBody(), syncsafeSize: false)]);
    final truncated = Uint8List.sublistView(whole, 0, whole.length - 6);
    expect(AudioArtParser.extract(truncated, 'song.mp3'), isNull);

    expect(
        AudioArtParser.extract(
            Uint8List.fromList('not an mp3 at all'.codeUnits), 'song.mp3'),
        isNull);
  });

  test('m4a: covr art behind the meta full-atom quirk', () {
    final m4a = Uint8List.fromList(_atom(
      'moov',
      _atom(
        'udta',
        _atom('meta', [
          0x00, 0x00, 0x00, 0x00, // meta version/flags — THE quirk
          ..._atom(
            'ilst',
            _atom(
              'covr',
              _atom('data', [
                0x00, 0x00, 0x00, 0x0D, // type (13 = jpeg)
                0x00, 0x00, 0x00, 0x00, // locale
                ..._art,
              ]),
            ),
          ),
        ]),
      ),
    ));
    expect(AudioArtParser.extract(m4a, 'song.m4a'), _art);
  });

  test('m4a without the meta version/flags prefix degrades to null', () {
    final broken = Uint8List.fromList(_atom(
      'moov',
      _atom(
        'udta',
        _atom(
          'meta',
          // No 4-byte prefix — the parser reads 4 junk bytes and the child
          // walk fails cleanly.
          _atom(
            'ilst',
            _atom('covr', _atom('data', [0, 0, 0, 0, 0, 0, 0, 0, ..._art])),
          ),
        ),
      ),
    ));
    expect(AudioArtParser.extract(broken, 'song.m4a'), isNull);
  });

  test('unknown extensions never parse', () {
    final tag = _id3(3, frames: [
      _frame('APIC', _apicBody(), syncsafeSize: false),
    ]);
    expect(AudioArtParser.extract(tag, 'song.wav'), isNull);
  });
}
