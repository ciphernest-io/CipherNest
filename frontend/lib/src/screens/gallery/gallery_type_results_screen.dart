import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../models/file_model.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/theme_icon.dart';
import 'image_viewer_screen.dart';
import 'pictures_tab.dart' show GalleryGridItem;

/// Results page for a search suggestion chip (one file type). The heading
/// is the type; no gallery search button, no bottom tab pill — this is a
/// results view, so the chrome is the back button, a rounded within-type
/// search bar at the bottom, and the same grid interactions as the main
/// gallery: pinch to resize, long-press (and drag) to select.
class GalleryTypeResultsScreen extends StatefulWidget {
  const GalleryTypeResultsScreen({
    super.key,
    required this.label,
    required this.files,
  });

  final String label;
  final List<CnestFile> files;

  @override
  State<GalleryTypeResultsScreen> createState() =>
      _GalleryTypeResultsScreenState();
}

class _GalleryTypeResultsScreenState extends State<GalleryTypeResultsScreen>
    with TickerProviderStateMixin {
  static const List<int> _cols = [6, 5, 4, 3, 2];
  int _colIndex = 2; // 4 per row, matching the gallery default

  final _queryCtrl = TextEditingController();
  final GlobalKey _gridKey = GlobalKey();

  // Selection (with long-press drag range sweep, same as the gallery).
  bool _selectionMode = false;
  final Set<String> _selected = {};
  int? _dragAnchor;
  Set<String>? _dragBase;

  // Pinch: live glide + settle, compact copy of the gallery mechanic.
  final Map<int, Offset> _pointers = {};
  bool _pinchActive = false;
  double? _spanBaseline;
  final ValueNotifier<double> _pinchScale = ValueNotifier(1.0);
  late final AnimationController _settleCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 280));
  double _settleFrom = 1.0;

  @override
  void initState() {
    super.initState();
    _queryCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _pinchScale.dispose();
    _settleCtrl.dispose();
    super.dispose();
  }

  List<CnestFile> get _visible {
    final q = _queryCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.files;
    return widget.files
        .where((f) => f.filename.toLowerCase().contains(q))
        .toList();
  }

  // ---- pinch ----

  double _span() {
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 2) {
      setState(() {
        _pinchActive = true;
        _spanBaseline = _span();
      });
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (!_pinchActive || _pointers.length < 2) return;
    final span = _span();
    final baseline = _spanBaseline;
    if (baseline == null || baseline <= 0) {
      _spanBaseline = span;
      return;
    }
    final relative = span / baseline;
    if (relative > 1.25 && _colIndex < _cols.length - 1) {
      _step(1, relative, span);
      return;
    }
    if (relative < 0.8 && _colIndex > 0) {
      _step(-1, relative, span);
      return;
    }
    final upper = _colIndex < _cols.length - 1 ? 1.32 : 1.0;
    final lower = _colIndex > 0 ? 0.78 : 1.0;
    _pinchScale.value = relative.clamp(lower, upper);
  }

  void _step(int direction, double relative, double span) {
    final oldCols = _cols[_colIndex].toDouble();
    final newIdx = _colIndex + direction;
    final newCols = _cols[newIdx].toDouble();
    setState(() => _colIndex = newIdx);
    _spanBaseline = span;
    _pinchScale.value = 1.0;
    _settleFrom = (relative * newCols / oldCols).clamp(0.6, 1.6);
    _settleCtrl.forward(from: 0);
  }

  void _onPointerEnd(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.length < 2) _spanBaseline = null;
    if (_pointers.isEmpty && _pinchActive) {
      setState(() => _pinchActive = false);
      if ((_pinchScale.value - 1).abs() > 0.01) {
        _settleFrom = _pinchScale.value;
        _pinchScale.value = 1.0;
        _settleCtrl.forward(from: 0);
      }
    }
  }

  // ---- selection ----

  void _beginDragSelect(String id, int index) {
    _dragAnchor = index;
    _dragBase = Set.of(_selected);
    setState(() {
      _selectionMode = true;
      _selected.add(id);
    });
  }

  void _updateDragSelect(Offset globalPos, List<CnestFile> flat) {
    final anchor = _dragAnchor;
    final base = _dragBase;
    if (anchor == null || base == null) return;
    final obj = _gridKey.currentContext?.findRenderObject();
    if (obj is! RenderBox) return;
    final result = BoxHitTestResult();
    obj.hitTest(result, position: obj.globalToLocal(globalPos));
    int? hit;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is int) {
        hit = target.metaData as int;
        break;
      }
    }
    if (hit == null) return;
    final next = Set.of(base);
    for (var i = math.min(anchor, hit);
        i <= math.max(anchor, hit) && i < flat.length;
        i++) {
      next.add(flat[i].id);
    }
    if (next.length != _selected.length || !next.containsAll(_selected)) {
      setState(() {
        _selected
          ..clear()
          ..addAll(next);
      });
    }
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  Future<void> _shareSelected(List<CnestFile> visible) async {
    final picked =
        visible.where((f) => _selected.contains(f.id)).toList();
    if (picked.isEmpty) return;
    await sendFilesPlain(context, picked);
    if (mounted) _exitSelection();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final files = _visible;
    final columns = _cols[_colIndex];

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              elevation: 0,
              scrolledUnderElevation: 0,
              leading: IconButton(
                icon: ThemeIcon('x'),
                onPressed: _exitSelection,
              ),
              title: Text('${_selected.length} selected'),
              actions: [
                IconButton(
                  icon: ThemeIcon('shareFat'),
                  onPressed: () => _shareSelected(files),
                ),
              ],
            )
          : AppBar(
              elevation: 0,
              scrolledUnderElevation: 0,
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.label,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    '${files.length} item${files.length == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
      body: Column(
        children: [
          Expanded(
            child: files.isEmpty
                ? Center(
                    child: Text(
                      'Nothing here.',
                      style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.5)),
                    ),
                  )
                : Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerEnd,
                    onPointerCancel: _onPointerEnd,
                    child: AnimatedBuilder(
                      animation:
                          Listenable.merge([_pinchScale, _settleCtrl]),
                      builder: (context, child) {
                        final settle = _settleFrom +
                            (1 - _settleFrom) *
                                Curves.easeOutCubic
                                    .transform(_settleCtrl.value);
                        final fade = 0.18 +
                            0.82 *
                                Curves.easeOut.transform(_settleCtrl.value);
                        return Opacity(
                          opacity:
                              _settleCtrl.isAnimating ? fade.clamp(0, 1) : 1,
                          child: Transform.scale(
                            scale: _pinchScale.value * settle,
                            alignment: Alignment.center,
                            child: child,
                          ),
                        );
                      },
                      child: GridView.builder(
                        key: _gridKey,
                        physics: _pinchActive
                            ? const NeverScrollableScrollPhysics()
                            : const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.only(top: 1.5, bottom: 8),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: 1.5,
                          mainAxisSpacing: 1.5,
                        ),
                        itemCount: files.length,
                        itemBuilder: (context, i) => MetaData(
                          metaData: i,
                          child: GestureDetector(
                            onTap: () {
                              if (_selectionMode) {
                                setState(() {
                                  final id = files[i].id;
                                  if (!_selected.remove(id)) {
                                    _selected.add(id);
                                  }
                                  if (_selected.isEmpty) {
                                    _selectionMode = false;
                                  }
                                });
                                return;
                              }
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ImageViewerScreen(
                                    files: files,
                                    initialIndex: i,
                                  ),
                                ),
                              );
                            },
                            onLongPressStart: (_) =>
                                _beginDragSelect(files[i].id, i),
                            onLongPressMoveUpdate: (d) =>
                                _updateDragSelect(d.globalPosition, files),
                            onLongPressEnd: (_) {
                              _dragAnchor = null;
                              _dragBase = null;
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                GalleryGridItem(
                                  key: ValueKey('type-${files[i].id}'),
                                  file: files[i],
                                  decodeWidth: columns >= 5 ? 160 : 200,
                                ),
                                if (_selectionMode)
                                  Container(
                                    color: _selected.contains(files[i].id)
                                        ? cs.primary.withValues(alpha: 0.35)
                                        : Colors.transparent,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          // Rounded within-type search, pinned to the bottom (rises with
          // the keyboard via the Scaffold's resize).
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: TextField(
                  controller: _queryCtrl,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    icon: ThemeIcon('magnifyingGlass',
                        size: 18,
                        color: cs.onSurface.withValues(alpha: 0.55)),
                    hintText: 'Search ${widget.label} files',
                    hintStyle: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.5)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
