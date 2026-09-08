import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../../services/cloud/cloud_service.dart';
import '../../../services/cnest_errors.dart';
import '../../../services/database_service.dart';
import '../../../services/encryption_service.dart';
import '../../models/file_model.dart';
import '../../widgets/file_actions.dart';
import '../../widgets/theme_icon.dart';
import '../share/share_dialog.dart';

/// In-app, read-only viewer for the document types we can render natively —
/// PDF (via pdfx / the platform PDF renderer), plain text / Markdown, and
/// images. NO WebView and NO Office formats (docx/xlsx): the caller routes
/// those to the OS handler instead.
///
/// Zero-knowledge: the plaintext is decrypted into memory and rendered from
/// there — it never touches disk (unlike the external-open path, which must
/// write a temp file for another app to read).
enum _DocKind { pdf, text, image, unsupported }

_DocKind _docKindFor(String filename) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  if (ext == 'pdf') return _DocKind.pdf;
  if (const {
    'txt', 'md', 'markdown', 'csv', 'log', 'json', 'xml', 'yaml', 'yml', 'rtf'
  }.contains(ext)) {
    return _DocKind.text;
  }
  if (const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp', 'heic', 'heif'}
      .contains(ext)) {
    return _DocKind.image;
  }
  return _DocKind.unsupported;
}

/// Whether [filename] can be shown in the in-app viewer (vs. handed to the OS).
bool canViewInApp(String filename) => _docKindFor(filename) != _DocKind.unsupported;

class DocumentViewerScreen extends StatefulWidget {
  final CnestFile file;
  const DocumentViewerScreen({super.key, required this.file});

  @override
  State<DocumentViewerScreen> createState() => _DocumentViewerScreenState();
}

class _DocumentViewerScreenState extends State<DocumentViewerScreen> {
  late final _DocKind _kind = _docKindFor(widget.file.filename);
  bool _loading = true;
  CnestError? _error;
  String? _errText; // generic (non-typed) failure message
  Uint8List? _bytes; // image / text source
  String? _text; // decoded text
  PdfControllerPinch? _pdf;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pdf?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      if (await DatabaseService().isPriorKeyFile(widget.file.id)) {
        if (!mounted) return;
        setState(() {
          _error = const PriorKeyFileError();
          _loading = false;
        });
        return;
      }
      if (widget.file.cloudId == null) throw Exception('File not synced');
      final enc = await CloudService().downloadFile(widget.file.cloudId!);
      final dec = await EncryptionService.decryptFile(enc);
      if (!mounted) return;
      switch (_kind) {
        case _DocKind.pdf:
          _pdf = PdfControllerPinch(document: PdfDocument.openData(dec));
        case _DocKind.text:
          _text = utf8.decode(dec, allowMalformed: true);
        case _DocKind.image:
          _bytes = dec;
        case _DocKind.unsupported:
          break;
      }
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (isCryptoAuthFailure(e)) {
          _error = const PriorKeyFileError();
        } else if (e is CnestError) {
          _error = e;
        } else {
          _errText = 'Could not open this file.';
        }
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.file.filename,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<String>(
            icon: ThemeIcon('dotsThreeVertical'),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'send', child: Text('Send file')),
              PopupMenuItem(value: 'share', child: Text('Share secure link')),
              PopupMenuItem(value: 'save', child: Text('Save to device')),
            ],
            onSelected: (v) => switch (v) {
              'send' => sendFilesPlain(context, [widget.file]),
              'share' => ShareDialog.show(context, widget.file),
              'save' => saveFileToDevice(context, widget.file),
              _ => null,
            },
          ),
        ],
      ),
      backgroundColor: _kind == _DocKind.pdf || _kind == _DocKind.image
          ? Colors.black
          : cs.surface,
      body: _buildBody(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null || _errText != null) {
      final title = _error?.title ?? 'Could not open';
      final message = _error?.message ?? _errText ?? '';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ThemeIcon('warningCircle',
                  size: 48, color: cs.onSurface.withAlpha(140)),
              const SizedBox(height: 12),
              Text(title,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: cs.onSurface, fontWeight: FontWeight.w600)),
              if (message.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(message,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: cs.onSurface.withAlpha(160))),
              ],
            ],
          ),
        ),
      );
    }
    switch (_kind) {
      case _DocKind.pdf:
        return PdfViewPinch(controller: _pdf!);
      case _DocKind.image:
        return InteractiveViewer(
          maxScale: 6,
          child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
        );
      case _DocKind.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            _text ?? '',
            style: TextStyle(
                color: cs.onSurface, fontSize: 14, height: 1.4),
          ),
        );
      case _DocKind.unsupported:
        return Center(
          child: Text('This file type can\'t be previewed in the app.',
              style: TextStyle(color: cs.onSurface.withAlpha(160))),
        );
    }
  }
}
