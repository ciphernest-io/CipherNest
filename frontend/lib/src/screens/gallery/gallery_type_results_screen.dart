import 'package:flutter/material.dart';

import '../../models/file_model.dart';
import 'image_viewer_screen.dart';
import 'pictures_tab.dart' show GalleryGridItem;

/// Results page for a search suggestion chip (one file type). The heading
/// is the type; no search button, no bottom tab pill — this is a results
/// view, so the only chrome is the back button.
class GalleryTypeResultsScreen extends StatelessWidget {
  const GalleryTypeResultsScreen({
    super.key,
    required this.label,
    required this.files,
  });

  final String label;
  final List<CnestFile> files;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
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
      body: files.isEmpty
          ? Center(
              child: Text(
                'Nothing of this type.',
                style:
                    TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
              ),
            )
          : GridView.builder(
              padding: const EdgeInsets.only(top: 1.5),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 1.5,
                mainAxisSpacing: 1.5,
              ),
              itemCount: files.length,
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ImageViewerScreen(
                      files: files,
                      initialIndex: i,
                    ),
                  ),
                ),
                child: GalleryGridItem(
                  key: ValueKey('type-${files[i].id}'),
                  file: files[i],
                  decodeWidth: 200,
                ),
              ),
            ),
    );
  }
}
