import 'package:flutter/material.dart';

import '../../../services/database_service.dart';
import '../../models/file_model.dart';
import 'image_viewer_screen.dart';
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final query = _queryCtrl.text.trim().toLowerCase();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: TextField(
          controller: _queryCtrl,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: 'Search photos',
            border: InputBorder.none,
            hintStyle:
                TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
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
            return Center(
              child: Text(
                'Search by file name.',
                style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            );
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
