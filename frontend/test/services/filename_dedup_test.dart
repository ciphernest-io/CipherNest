/// nextAvailableFilename / dedupQueryPrefix: the "(1)" rename law.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/src/utils/filename_dedup.dart';

void main() {
  test('free name passes through unchanged', () {
    expect(nextAvailableFilename('photo.jpg', {}), 'photo.jpg');
  });

  test('collision appends (1)', () {
    expect(
      nextAvailableFilename('photo.jpg', {'photo.jpg'}),
      'photo (1).jpg',
    );
  });

  test('chained collisions count up', () {
    expect(
      nextAvailableFilename(
          'photo.jpg', {'photo.jpg', 'photo (1).jpg', 'photo (2).jpg'}),
      'photo (3).jpg',
    );
  });

  test('re-uploading an already-suffixed name continues the count', () {
    expect(
      nextAvailableFilename('photo (1).jpg', {'photo (1).jpg'}),
      'photo (2).jpg',
    );
  });

  test('no extension', () {
    expect(nextAvailableFilename('notes', {'notes'}), 'notes (1)');
  });

  test('multi-dot keeps only the last extension', () {
    expect(
      nextAvailableFilename('archive.tar.gz', {'archive.tar.gz'}),
      'archive.tar (1).gz',
    );
  });

  test('dotfile treated as extension-less', () {
    expect(nextAvailableFilename('.env', {'.env'}), '.env (1)');
  });

  test('dedupQueryPrefix strips an existing counter', () {
    expect(dedupQueryPrefix('photo.jpg'), 'photo');
    expect(dedupQueryPrefix('photo (3).jpg'), 'photo');
    expect(dedupQueryPrefix('notes'), 'notes');
  });
}
