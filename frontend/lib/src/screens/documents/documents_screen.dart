import 'package:flutter/material.dart';
import '../../models/file_model.dart';
import '../../../services/database_service.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  late Future<List<CnestFile>> _filesFuture;

  @override
  void initState() {
    super.initState();
    // In future: Filter by 'type' = document
    _filesFuture = DatabaseService().getFilesByType(CnestFileType.document);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Secure Documents')),
      body: FutureBuilder<List<CnestFile>>(
        future: _filesFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          
          final files = snapshot.data!;
          if (files.isEmpty) {
            return const Center(child: Text('No documents yet.'));
          }

          return ListView.builder(
            itemCount: files.length,
            itemBuilder: (context, index) {
              final file = files[index];
              return ListTile(
                leading: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                title: Text(file.filename, style: const TextStyle(color: Colors.white)),
                subtitle: Text('${(file.sizeBytes / 1024).toStringAsFixed(1)} KB'),
                trailing: const Icon(Icons.lock_outline, size: 16, color: Colors.grey),
                onTap: () {
                  // TODO: Download and Decrypt logic
                },
              );
            },
          );
        },
      ),
    );
  }
}