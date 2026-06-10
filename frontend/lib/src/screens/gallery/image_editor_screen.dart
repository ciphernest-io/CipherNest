import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

/// Wraps `ProImageEditor.memory` and returns the edited bytes (or null on
/// cancel) to the caller via `Navigator.pop`.
///
/// The editor runs entirely in memory — the input bytes are the decrypted
/// plaintext of a vault file, and the output bytes are passed straight back
/// to the caller without touching disk. The caller (the viewer) decides
/// whether to save as a new vault file or replace the original.
class ImageEditorScreen extends StatefulWidget {
  final Uint8List bytes;

  const ImageEditorScreen({super.key, required this.bytes});

  @override
  State<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends State<ImageEditorScreen> {
  Uint8List? _editedBytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ProImageEditor.memory(
      widget.bytes,
      callbacks: ProImageEditorCallbacks(
        onImageEditingComplete: (bytes) async {
          _editedBytes = bytes;
        },
        onCloseEditor: () {
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop(_editedBytes);
          }
        },
      ),
      configs: ProImageEditorConfigs(
        theme: theme,
        // v1 scope per the plan: crop/rotate, tune, filter, paint, text.
        // Stickers, emoji, and blur are deferred.
        emojiEditor: const EmojiEditorConfigs(enabled: false),
        stickerEditor: const StickerEditorConfigs(enabled: false),
        blurEditor: const BlurEditorConfigs(enabled: false),
      ),
    );
  }
}
