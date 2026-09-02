import 'package:flutter_test/flutter_test.dart';

import 'package:ciphernest/src/models/file_model.dart';
import 'package:ciphernest/src/screens/gallery/gallery_layout.dart';
import 'package:ciphernest/src/utils/date_grouper.dart';

CnestFile _file(int i, DateTime created) => CnestFile(
      id: 'f$i',
      filename: 'p$i.jpg',
      sizeBytes: 1,
      createdAt: created,
      type: CnestFileType.image,
    );

void main() {
  // 23 photos across 3 days, newest first (the grid's invariant).
  final base = DateTime(2026, 5, 20, 12);
  final files = <CnestFile>[
    for (var i = 0; i < 9; i++) _file(i, base.subtract(Duration(minutes: i))),
    for (var i = 9; i < 16; i++)
      _file(i, base.subtract(Duration(days: 40, minutes: i))),
    for (var i = 16; i < 23; i++)
      _file(i, base.subtract(Duration(days: 400, minutes: i))),
  ];

  double ratioOf(CnestFile f) => 1.0;

  test('fixed rung matches the legacy sliver math exactly', () {
    const width = 411.0;
    const cols = 4;
    final oracle = GalleryLayoutOracle.obtain(
      files: files,
      columns: cols,
      grouping: GalleryGrouping.day,
      width: width,
      ratioOf: ratioOf,
    );
    final sections = groupByDate(files);
    expect(oracle.headers.length, sections.length);

    // Legacy math (the old _tileGeometry): 36dp headers, 1.5 spacing,
    // square tiles.
    const spacing = 1.5;
    final tile = (width - (cols - 1) * spacing) / cols;
    var y = 0.0;
    var flat = 0;
    for (var s = 0; s < sections.length; s++) {
      expect(oracle.headers[s].y, closeTo(y, 0.001));
      expect(oracle.headers[s].label, sections[s].label);
      y += 36;
      final n = sections[s].files.length;
      for (var i = 0; i < n; i++) {
        final r = oracle.rectFor(flat + i);
        expect(r.left, closeTo((i % cols) * (tile + spacing), 0.001));
        expect(r.top, closeTo(y + (i ~/ cols) * (tile + spacing), 0.001));
        expect(r.width, closeTo(tile, 0.001));
        expect(r.height, closeTo(tile, 0.001));
      }
      final rows = (n / cols).ceil();
      y += rows * tile + (rows - 1) * spacing;
      flat += n;
    }
    expect(oracle.totalHeight, closeTo(y, 0.001));
  });

  test('justified rung: rows fill the width, ys are monotone, all tiles '
      'covered', () {
    const width = 411.0;
    double mixedRatio(CnestFile f) {
      final n = int.parse(f.id.substring(1));
      return const [1.0, 4 / 3, 3 / 4, 16 / 9][n % 4];
    }

    final oracle = GalleryLayoutOracle.obtain(
      files: files,
      columns: 0,
      grouping: GalleryGrouping.day,
      width: width,
      ratioOf: mixedRatio,
      ratioEpoch: 1,
    );
    expect(oracle.isJustified, isTrue);

    var lastTop = -1.0;
    for (var i = 0; i < files.length; i++) {
      final r = oracle.rectFor(i);
      expect(r.width, greaterThan(0));
      expect(r.height, greaterThan(0));
      expect(r.right, lessThanOrEqualTo(width + 0.01));
      expect(r.top + 0.01, greaterThanOrEqualTo(lastTop));
      lastTop = r.top;
      expect(r.bottom, lessThanOrEqualTo(oracle.totalHeight));
    }

    // Full (non-underfull) rows span the width exactly.
    final rows = packJustified(groupByDate(files).first.files, width, mixedRatio);
    for (final row in rows.where((r) => !r.underfull)) {
      final total = row.widths.fold(0.0, (a, w) => a + w) +
          1.5 * (row.widths.length - 1);
      expect(total, closeTo(width, 0.01));
    }
  });

  test('memoization returns the identical oracle for identical inputs', () {
    final a = GalleryLayoutOracle.obtain(
      files: files,
      columns: 3,
      grouping: GalleryGrouping.day,
      width: 411,
      ratioOf: ratioOf,
    );
    final b = GalleryLayoutOracle.obtain(
      files: files,
      columns: 3,
      grouping: GalleryGrouping.day,
      width: 411,
      ratioOf: ratioOf,
    );
    expect(identical(a, b), isTrue);
    final c = GalleryLayoutOracle.obtain(
      files: files,
      columns: 4,
      grouping: GalleryGrouping.day,
      width: 411,
      ratioOf: ratioOf,
    );
    expect(identical(a, c), isFalse);
  });
}
