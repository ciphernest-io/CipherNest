/// MASVS F-07 (2026-10-17): a vault filename becomes exactly one path
/// component under the cache directory, whatever it contains.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/src/utils/safe_filename.dart';

void main() {
  test('ordinary names pass through', () {
    expect(safeFilename('IMG_2041.jpg'), 'IMG_2041.jpg');
    expect(safeFilename('tax return 2025 (final).pdf'),
        'tax return 2025 (final).pdf');
  });

  test('path separators are reduced to the last component', () {
    expect(safeFilename('../../shared_prefs/x.xml'), 'x.xml');
    expect(safeFilename('..\\..\\databases\\vault.db'), 'vault.db');
    expect(safeFilename('/etc/passwd'), 'passwd');
  });

  test('reserved and control characters are replaced', () {
    expect(safeFilename('a:b*c?d"e<f>g|h.txt'), 'a_b_c_d_e_f_g_h.txt');
    expect(safeFilename('x\u0000y\n.jpg'), 'x_y_.jpg');
  });

  test('empty and dot names get a placeholder', () {
    expect(safeFilename(''), 'file');
    expect(safeFilename('.'), 'file');
    expect(safeFilename('..'), 'file');
    expect(safeFilename('/'), 'file');
  });
}
