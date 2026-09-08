import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';

import '../../services/cloud/cloud_service.dart';
import '../../services/encryption_service.dart';
import '../config/theme_controller.dart';
import '../models/file_model.dart';
import '../utils/file_visuals.dart';
import 'theme_icon.dart';

/// Encrypted-thumbnail renderer for any file carrying a thumbnailCloudId
/// (PDF covers, audio album art…). Cache key `thumb_<cloudId>.jpg` in the
/// app-private temp dir — the SAME file the gallery ladder and the media
/// session use, so one decrypt serves every surface and the cache GC
/// already knows the name. Falls back to the shared type icon (or the
/// caller-supplied [fallback]) when no thumb exists or loading fails.
class DocThumbnail extends StatefulWidget {
  final CnestFile file;
  final double? width;
  final double? height;
  final BorderRadius borderRadius;
  final double iconSize;
  final Widget? fallback;

  const DocThumbnail({
    super.key,
    required this.file,
    this.width,
    this.height,
    this.borderRadius = BorderRadius.zero,
    this.iconSize = 36,
    this.fallback,
  });

  @override
  State<DocThumbnail> createState() => _DocThumbnailState();
}

class _DocThumbnailState extends State<DocThumbnail> {
  Uint8List? _thumbBytes;

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  @override
  void didUpdateWidget(DocThumbnail old) {
    super.didUpdateWidget(old);
    if (old.file.id != widget.file.id ||
        old.file.thumbnailCloudId != widget.file.thumbnailCloudId) {
      _thumbBytes = null;
      _loadThumb();
    }
  }

  Future<void> _loadThumb() async {
    final f = widget.file;
    if (f.cloudId == null) return;
    try {
      final cacheDir = await getTemporaryDirectory();
      final cacheFile = File('${cacheDir.path}/thumb_${f.cloudId}.jpg');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (mounted) setState(() => _thumbBytes = bytes);
        return;
      }

      // Preferred: the encrypted thumbnail generated at upload (PDF covers,
      // album art…).
      if (f.thumbnailCloudId != null) {
        final encBytes = await CloudService().downloadFile(f.thumbnailCloudId!);
        final decBytes = await EncryptionService.decryptFile(encBytes);
        await cacheFile.writeAsBytes(decBytes);
        if (mounted) setState(() => _thumbBytes = decBytes);
        return;
      }

      // Best-effort fallback for PDFs that never got a stored thumb: render
      // page 1 on the fly (decrypt in memory, cache the JPEG under the same
      // key so it's a one-time cost per file).
      if (_isPdf(f.filename)) {
        final cover = await _renderPdfCover(f.cloudId!);
        if (cover != null) {
          await cacheFile.writeAsBytes(cover);
          if (mounted) setState(() => _thumbBytes = cover);
        }
      }
    } catch (_) {
      // Fail silently — the icon fallback is fine.
    }
  }

  bool _isPdf(String name) => name.toLowerCase().endsWith('.pdf');

  Future<Uint8List?> _renderPdfCover(String cloudId) async {
    final enc = await CloudService().downloadFile(cloudId);
    final dec = await EncryptionService.decryptFile(enc);
    final doc = await PdfDocument.openData(dec);
    try {
      final page = await doc.getPage(1);
      try {
        const target = 320.0;
        final scale = page.width == 0 ? 1.0 : target / page.width;
        final img = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
        );
        return img?.bytes;
      } finally {
        await page.close();
      }
    } finally {
      await doc.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _thumbBytes;
    if (bytes != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.memory(
          bytes,
          width: widget.width ?? double.infinity,
          height: widget.height ?? double.infinity,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
        ),
      );
    }
    if (widget.fallback != null) {
      return SizedBox(
          width: widget.width, height: widget.height, child: widget.fallback);
    }
    final v =
        fileVisual(widget.file.filename, ThemeController().tokens);
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Center(
        child: ThemeIcon(v.icon,
            color: v.color.withAlpha(204), size: widget.iconSize),
      ),
    );
  }
}
