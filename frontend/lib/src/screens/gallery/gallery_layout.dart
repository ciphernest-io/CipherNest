import 'dart:ui';

import '../../models/file_model.dart';
import '../../utils/date_grouper.dart';

/// Which date decomposition a zoom rung uses (public mirror of the
/// pictures tab's private grouping).
enum GalleryGrouping {
  year,
  month,
  day,

  /// One section, no header row: album pages, the Favorites grid and other
  /// embedded grids that show no dates. The morph layer draws whatever the
  /// oracle emits, so these grids must not get date headers mid-pinch.
  none,
}

/// One packed row of the justified (masonry) layout — the exact greedy
/// algorithm the justified sliver renders, factored out so the layout
/// oracle and the sliver can never drift apart.
class JustifiedRow {
  const JustifiedRow({
    required this.start,
    required this.files,
    required this.height,
    required this.underfull,
    required this.widths,
  });

  /// Flat index (within the SECTION) of the first tile of this row.
  final int start;
  final List<CnestFile> files;
  final double height;
  final bool underfull;
  final List<double> widths;
}

/// Greedy fill: append until the row would render below targetH; a full
/// row scales to exactly fill the width, a trailing underfull row keeps
/// targetH and leaves the remainder empty. Mirrors _justifiedSliver.
List<JustifiedRow> packJustified(
  List<CnestFile> sectionFiles,
  double width,
  double Function(CnestFile) ratioOf, {
  double spacing = 1.5,
  double targetH = 220.0,
}) {
  final rows = <List<CnestFile>>[];
  var row = <CnestFile>[];
  var ratioSum = 0.0;
  for (final file in sectionFiles) {
    row.add(file);
    ratioSum += ratioOf(file);
    if (ratioSum * targetH >= width - spacing * (row.length - 1)) {
      rows.add(row);
      row = [];
      ratioSum = 0.0;
    }
  }
  if (row.isNotEmpty) rows.add(row);

  final out = <JustifiedRow>[];
  var start = 0;
  for (final rowFiles in rows) {
    final innerWidth = width - spacing * (rowFiles.length - 1);
    final sum = rowFiles.fold(0.0, (a, f) => a + ratioOf(f));
    final exactH = innerWidth / sum;
    final underfull = exactH > targetH * 1.6;
    final rowH = underfull ? targetH : exactH;
    final widths = [
      for (final f in rowFiles)
        underfull ? ratioOf(f) * rowH : innerWidth * ratioOf(f) / sum,
    ];
    out.add(JustifiedRow(
      start: start,
      files: rowFiles,
      height: rowH,
      underfull: underfull,
      widths: widths,
    ));
    start += rowFiles.length;
  }
  return out;
}

class _SectionGeo {
  _SectionGeo(this.start, this.count, this.tilesTop);
  final int start;
  final int count;
  final double tilesTop;
}

class _RowGeo {
  _RowGeo(this.start, this.count, this.top, this.height, this.xs, this.widths);
  final int start; // FLAT index of first tile
  final int count;
  final double top;
  final double height;
  final List<double> xs;
  final List<double> widths;
}

/// Pure, memoized layout function for the photo grid: given the file list
/// and a rung's shape, answers `rectFor(flatIndex)`, `totalHeight`, and
/// the date-header positions — in CONTENT space (y = 0 is the top of the
/// first date header; callers add the chrome offset). This is what lets
/// the continuous zoom morph lerp a tile between two rungs' rects, and it
/// replaces the old `_tileGeometry` (which regrouped the whole list per
/// call and could not handle the justified rung).
class GalleryLayoutOracle {
  GalleryLayoutOracle._();

  static const double spacing = 1.5;
  static const double headerExtent = 36.0;

  static final List<(List<CnestFile>, int, GalleryGrouping, double, int)>
      _keys = [];
  static final List<GalleryLayoutOracle> _cache = [];

  /// [columns] == 0 selects the justified layout ([ratioOf] then matters,
  /// with [ratioEpoch] invalidating the memo as ratios resolve).
  static GalleryLayoutOracle obtain({
    required List<CnestFile> files,
    required int columns,
    required GalleryGrouping grouping,
    required double width,
    required double Function(CnestFile) ratioOf,
    int ratioEpoch = 0,
  }) {
    final epoch = columns == 0 ? ratioEpoch : 0;
    for (var i = 0; i < _keys.length; i++) {
      final k = _keys[i];
      if (identical(k.$1, files) &&
          k.$2 == columns &&
          k.$3 == grouping &&
          k.$4 == width &&
          k.$5 == epoch) {
        return _cache[i];
      }
    }
    final o = GalleryLayoutOracle._()
      .._compute(files, columns, grouping, width, ratioOf);
    _keys.add((files, columns, grouping, width, epoch));
    _cache.add(o);
    if (_cache.length > 4) {
      _keys.removeAt(0);
      _cache.removeAt(0);
    }
    return o;
  }

  double totalHeight = 0;
  final List<({double y, String label})> headers = [];

  int _cols = 0;
  double _tileW = 0;
  final List<_SectionGeo> _sections = [];
  final List<_RowGeo> _rows = []; // justified only

  bool get isJustified => _cols == 0;

  void _compute(
    List<CnestFile> files,
    int columns,
    GalleryGrouping grouping,
    double width,
    double Function(CnestFile) ratioOf,
  ) {
    _cols = columns;
    final sections = switch (grouping) {
      GalleryGrouping.year => groupByYear(files),
      GalleryGrouping.month => groupByMonth(files),
      GalleryGrouping.day => groupByDate(files),
      GalleryGrouping.none => [DateSection(label: '', files: files)],
    };
    final withHeaders = grouping != GalleryGrouping.none;
    var y = 0.0;
    var start = 0;
    if (columns > 0) {
      _tileW = (width - (columns - 1) * spacing) / columns;
      for (final section in sections) {
        if (withHeaders) {
          headers.add((y: y, label: section.label));
          y += headerExtent;
        }
        final n = section.files.length;
        _sections.add(_SectionGeo(start, n, y));
        final rows = (n / columns).ceil();
        y += rows * _tileW + (rows - 1) * spacing;
        start += n;
      }
    } else {
      for (final section in sections) {
        if (withHeaders) {
          headers.add((y: y, label: section.label));
          y += headerExtent;
        }
        for (final row in packJustified(section.files, width, ratioOf)) {
          final xs = <double>[];
          var x = 0.0;
          for (final w in row.widths) {
            xs.add(x);
            x += w + spacing;
          }
          _rows.add(_RowGeo(start + row.start, row.files.length, y,
              row.height, xs, row.widths));
          // The sliver pads 1.5 below EVERY row (trailing included).
          y += row.height + spacing;
        }
        start += section.files.length;
      }
    }
    totalHeight = y;
  }

  /// Content-space rect of the tile at [flatIndex].
  Rect rectFor(int flatIndex) {
    if (_cols > 0) {
      final s = _sectionOf(flatIndex);
      final local = flatIndex - s.start;
      final row = local ~/ _cols;
      final col = local % _cols;
      return Rect.fromLTWH(
        col * (_tileW + spacing),
        s.tilesTop + row * (_tileW + spacing),
        _tileW,
        _tileW,
      );
    }
    final r = _rowOf(flatIndex);
    final local = flatIndex - r.start;
    return Rect.fromLTWH(r.xs[local], r.top, r.widths[local], r.height);
  }

  _SectionGeo _sectionOf(int flatIndex) {
    var lo = 0, hi = _sections.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_sections[mid].start <= flatIndex) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _sections[lo];
  }

  _RowGeo _rowOf(int flatIndex) {
    var lo = 0, hi = _rows.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_rows[mid].start <= flatIndex) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return _rows[lo];
  }
}
