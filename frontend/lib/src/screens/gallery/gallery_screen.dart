import 'package:flutter/material.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';
import '../../../services/drive_service.dart';
import 'image_viewer_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  late Future<List<CnestFile>> _filesFuture;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _filesFuture = DatabaseService().getFilesByType(CnestFileType.image);
    });
  }

  /// Syncs local database with Google Drive
  Future<void> _handleSync() async {
    try {
      // 1. Get FULL file objects
      final cloudFiles = await DriveService.listCloudFiles();

      // 2. Reconcile (Add missing, Remove ghosts)
      await DatabaseService().reconcile(cloudFiles);

      // 3. Refresh UI
      _refresh();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Sync complete')));
      }
    } catch (e) {
      // debugPrint(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Encrypted Gallery')),
      body: FutureBuilder<List<CnestFile>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final files = snapshot.data!;

          return RefreshIndicator(
            onRefresh: _handleSync,
            child: files.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      SizedBox(height: 300),
                      Center(
                        child: Text(
                          'No encrypted photos yet.\nPull to sync.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54),
                        ),
                      ),
                    ],
                  )
                : GridView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: files.length,
                    itemBuilder: (context, index) {
                      final file = files[index];
                      return GestureDetector(
                        onTap: () async {
                          // AWAIT the result from the viewer
                          final result = await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ImageViewerScreen(
                                files: files,
                                initialIndex: index,
                              ),
                            ),
                          );

                          // If result is true, a file was deleted. Refresh the grid.
                          if (result == true) {
                            _refresh(); // This re-queries the DB, and the deleted photo vanishes.
                          }
                        },
                        child: Container(
                          color: Colors.grey[900],
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.lock, color: Colors.white54),
                              const SizedBox(height: 4),
                              Text(
                                file.filename,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white70,
                                ),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          );
        },
      ),
    );
  }
}
