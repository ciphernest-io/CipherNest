import 'package:flutter/material.dart';

import '../../models/file_model.dart';
import '../../widgets/theme_icon.dart';
import 'gallery_chrome.dart';
import 'pictures_tab.dart';

/// Results page for a search suggestion chip (one file type). The heading
/// is the type; no gallery search button, no bottom tab pill. The grid IS
/// the real gallery grid (embedded PicturesTab), so everything carries
/// over: date sections, the full zoom ladder down to the masonry level,
/// long-press drag-select with auto-scroll, and the selection actions.
/// A rounded within-type search bar sits at the bottom.
class GalleryTypeResultsScreen extends StatefulWidget {
  const GalleryTypeResultsScreen({
    super.key,
    required this.label,
    required this.files,
    this.showDateHeaders = true,
    this.searchHint,
  });

  final String label;
  final List<CnestFile> files;

  /// False for grids that are one flat run sorted by date (Favorites).
  final bool showDateHeaders;

  /// Placeholder for the bottom search field; defaults to the type wording.
  final String? searchHint;

  @override
  State<GalleryTypeResultsScreen> createState() =>
      _GalleryTypeResultsScreenState();
}

class _GalleryTypeResultsScreenState extends State<GalleryTypeResultsScreen> {
  final _queryCtrl = TextEditingController();
  final _tabKey = GlobalKey<PicturesTabState>();
  final _chrome = GalleryChrome();

  List<CnestFile>? _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = widget.files;
    _queryCtrl.addListener(() {
      final q = _queryCtrl.text.trim().toLowerCase();
      setState(() {
        _filtered = q.isEmpty
            ? widget.files
            : widget.files
                .where((f) => f.filename.toLowerCase().contains(q))
                .toList();
      });
    });
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    _chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final files = _filtered ?? widget.files;

    // Back during selection deselects instead of leaving the results.
    return ValueListenableBuilder<bool>(
      valueListenable: _chrome.selectionActive,
      builder: (context, selection, child) => PopScope(
        canPop: !selection,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _tabKey.currentState?.exitSelection();
        },
        child: child!,
      ),
      child: Scaffold(
        appBar: AppBar(
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
              child: PicturesTab(
                key: _tabKey,
                chrome: _chrome,
                embedded: true,
                showDateHeaders: widget.showDateHeaders,
                filesOverride: files,
              ),
            ),
            // Rounded within-type search; rises with the keyboard.
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color:
                        cs.surfaceContainerHighest.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: TextField(
                    controller: _queryCtrl,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      // Strip the pack theme's outline + fill: this field
                      // draws its own pill.
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      icon: ThemeIcon('magnifyingGlass',
                          size: 18,
                          color: cs.onSurface.withValues(alpha: 0.55)),
                      hintText:
                          widget.searchHint ?? 'Search ${widget.label} files',
                      hintStyle: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.5)),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
