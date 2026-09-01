import 'package:flutter/material.dart';

import '../../../services/database_service.dart';
import '../../models/file_model.dart';
import 'image_viewer_screen.dart';
import 'gallery_type_results_screen.dart';
import 'pictures_tab.dart' show GalleryGridItem;

/// Filename search over the encrypted gallery. In-memory filter of the
/// already-indexed rows (the index is local SQLite; nothing decrypts to
/// search) — plaintext content search is impossible by design.
class GallerySearchScreen extends StatefulWidget {
  const GallerySearchScreen({super.key});

  @override
  State<GallerySearchScreen> createState() => _GallerySearchScreenState();
}

class _GallerySearchScreenState extends State<GallerySearchScreen> {
  final _queryCtrl = TextEditingController();
  late final Future<List<CnestFile>> _allFuture =
      DatabaseService().getFilesByType(CnestFileType.image);

  @override
  void initState() {
    super.initState();
    _queryCtrl.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  /// The Samsung slot says "You might be looking for beaches, food…" —
  /// content-blind by design here, so suggest what we CAN know without
  /// decrypting anything: the file types actually in the vault.
  Widget _suggestions(List<CnestFile> all, ColorScheme cs) {
    final counts = <String, int>{};
    for (final f in all) {
      final name = f.filename;
      final dot = name.lastIndexOf('.');
      if (dot <= 0 || dot == name.length - 1) continue;
      final ext = name.substring(dot + 1).toLowerCase();
      if (ext.length > 4) continue;
      counts[ext] = (counts[ext] ?? 0) + 1;
    }
    final types = counts.keys.toList()
      ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
    final top = types.take(8).toList();
    if (top.isEmpty) {
      return Center(
        child: Text(
          'Search by file name.',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
        ),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOut,
      builder: (context, v, child) => Opacity(opacity: v, child: child),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        children: [
          Text(
            'You might be looking for',
            style: TextStyle(
              color: cs.onSurface.withValues(alpha: 0.6),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ext in top)
                ActionChip(
                  label: Text(
                      '${ext.toUpperCase()}  ·  ${counts[ext]}'),
                  onPressed: () {
                    final matches = all
                        .where((f) => f.filename
                            .toLowerCase()
                            .endsWith('.$ext'))
                        .toList();
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => GalleryTypeResultsScreen(
                          label: ext.toUpperCase(),
                          files: matches,
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final query = _queryCtrl.text.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(999),
          ),
          child: TextField(
          controller: _queryCtrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search photos',
            // The pack theme paints an OutlineInputBorder + fill on every
            // field; this one lives inside its own pill, so strip all of
            // it (border: none alone leaves enabled/focused outlines).
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            hintStyle:
                TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
          ),
          ),
        ),
      ),
      body: FutureBuilder<List<CnestFile>>(
        future: _allFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (query.isEmpty) {
            return _suggestions(snapshot.data!, cs);
          }
          final matches = snapshot.data!
              .where((f) => f.filename.toLowerCase().contains(query))
              .toList();
          if (matches.isEmpty) {
            return Center(
              child: Text(
                'Nothing matches "$query".',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.only(top: 1.5),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 4,
              crossAxisSpacing: 1.5,
              mainAxisSpacing: 1.5,
            ),
            itemCount: matches.length,
            itemBuilder: (context, i) => GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ImageViewerScreen(
                    files: matches,
                    initialIndex: i,
                  ),
                ),
              ),
              child: GalleryGridItem(
                key: ValueKey('search-${matches[i].id}'),
                file: matches[i],
                decodeWidth: 200,
              ),
            ),
          );
        },
      ),
    );
  }
}
