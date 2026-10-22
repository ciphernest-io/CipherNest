import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../config/theme.dart';
import '../../config/theme_controller.dart';
import '../../widgets/theme_icon.dart';

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
    // The editor is dark chrome in every theme, like the Samsung Gallery
    // editor. Two reasons. The package hard-codes white for the undo/redo
    // arrows in the tune, crop and paint bars, black/white for the text
    // editor's style chips and dark fills for its line-width and aspect
    // sheets; none of those read from the style objects, so a light bar
    // leaves them invisible. And a photo is judged against a dark surround.
    // The current pack still supplies the accent and the type, through its
    // own dark variant, so Burrow's editor is not Binary's.
    final theme = AppTheme.build(
      pack: ThemeController().pack,
      mode: Brightness.dark,
    );
    final cs = theme.colorScheme;

    // pro_image_editor's `theme` hook themes the Material widgets, so the
    // editor's TEXT buttons pick up the pack's textButtonTheme (the accent).
    // Every editor's ICON buttons take their own style's bar foreground,
    // which defaults to a fixed white, so they are tinted with the accent to
    // match the text; backgrounds and active-tool accents are bound to the
    // pack as well (the package's own default is a hardcoded blue,
    // 0xFF004C9E). Every sub-editor gets its backgrounds set explicitly:
    // left at the defaults they fell back to the package's black, which is
    // where a light pack's dark accent and dim grey vanished.
    final barBg = cs.surface; // app-bar / bottom-bar background
    final onBar = cs.primary; // icons + labels on the bars (match accent text)
    final onBarDim = cs.onSurface.withAlpha(140); // inactive tool items
    final accent = cs.primary; // active / selected accent
    final canvas = theme.scaffoldBackgroundColor; // editor canvas behind image

    // The package renders raw `Icon`s, so the pack's Material Symbol FILL /
    // WEIGHT / GRADE (what makes Burrow's icons filled-and-rounded, etc.)
    // have to arrive via the ThemeData's iconTheme — every editor re-applies
    // this theme through a Material `Theme`, which installs an IconTheme the
    // leaf Icons inherit. The cut still rides each themeIconData() below.
    final axes = themeIconAxes();
    final editorTheme = theme.copyWith(
      iconTheme: theme.iconTheme.merge(axes),
      appBarTheme: theme.appBarTheme.copyWith(
        iconTheme: (theme.appBarTheme.iconTheme ?? const IconThemeData())
            .merge(axes),
        actionsIconTheme:
            (theme.appBarTheme.actionsIconTheme ?? const IconThemeData())
                .merge(axes),
      ),
    );

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
        theme: editorTheme,
        // v1 scope per the plan: crop/rotate, tune, filter, paint, text.
        // Stickers, emoji, and blur are deferred.
        mainEditor: MainEditorConfigs(
          style: MainEditorStyle(
            background: canvas,
            appBarColor: onBar,
            appBarBackground: barBg,
            bottomBarColor: onBar,
            bottomBarBackground: barBg,
          ),
          // Swap the package's classic Material Icons for the app's Material
          // Symbols at the current pack's cut, so the editor's glyphs match
          // the roundedness/style used everywhere else in CipherNest.
          icons: MainEditorIcons(
            closeEditor: themeIconData('x'),
            doneIcon: themeIconData('check'),
            applyChanges: themeIconData('check'),
            backButton: themeIconData('arrowLeft'),
            undoAction: themeIconData('arrowCounterClockwise'),
            redoAction: themeIconData('redo'),
            removeElementZone: themeIconData('trash'),
          ),
        ),
        paintEditor: PaintEditorConfigs(
          style: PaintEditorStyle(
            background: canvas,
            appBarColor: onBar,
            appBarBackground: barBg,
            bottomBarBackground: barBg,
            bottomBarActiveItemColor: accent,
            bottomBarInactiveItemColor: onBarDim,
          ),
          icons: PaintEditorIcons(
            bottomNavBar: themeIconData('brush'),
            eraser: themeIconData('eraser'),
            applyChanges: themeIconData('check'),
            backButton: themeIconData('arrowLeft'),
            undoAction: themeIconData('arrowCounterClockwise'),
            redoAction: themeIconData('redo'),
          ),
        ),
        textEditor: TextEditorConfigs(
          style: TextEditorStyle(
            appBarColor: onBar,
            appBarBackground: barBg,
            bottomBarBackground: barBg,
            inputCursorColor: accent,
          ),
          icons: TextEditorIcons(
            bottomNavBar: themeIconData('textT'),
            applyChanges: themeIconData('check'),
            backButton: themeIconData('arrowLeft'),
          ),
        ),
        cropRotateEditor: CropRotateEditorConfigs(
          style: CropRotateEditorStyle(
            background: canvas,
            appBarColor: onBar,
            appBarBackground: barBg,
            bottomBarColor: onBar,
            bottomBarBackground: barBg,
            cropCornerColor: accent,
          ),
          icons: CropRotateEditorIcons(
            bottomNavBar: themeIconData('cropRotate'),
            rotate: themeIconData('rotateLeft'),
            aspectRatio: themeIconData('crop'),
            flip: themeIconData('flip'),
            reset: themeIconData('restore'),
            applyChanges: themeIconData('check'),
            backButton: themeIconData('arrowLeft'),
            undoAction: themeIconData('arrowCounterClockwise'),
            redoAction: themeIconData('redo'),
          ),
        ),
        filterEditor: FilterEditorConfigs(
          style: FilterEditorStyle(
            background: canvas,
            appBarColor: onBar,
            appBarBackground: barBg,
            previewTextColor: onBarDim,
            previewSelectedTextColor: accent,
          ),
          icons: FilterEditorIcons(
            bottomNavBar: themeIconData('photoFilter'),
            applyChanges: themeIconData('check'),
            backButton: themeIconData('arrowLeft'),
          ),
        ),
        tuneEditor: TuneEditorConfigs(
          style: TuneEditorStyle(
            background: canvas,
            appBarColor: onBar,
            appBarBackground: barBg,
            bottomBarBackground: barBg,
            bottomBarActiveItemColor: accent,
            bottomBarInactiveItemColor: onBarDim,
          ),
          icons: TuneEditorIcons(
            bottomNavBar: themeIconData('tune'),
            applyChanges: themeIconData('check'),
            backButton: themeIconData('arrowLeft'),
            undoAction: themeIconData('arrowCounterClockwise'),
            redoAction: themeIconData('redo'),
          ),
        ),
        emojiEditor: const EmojiEditorConfigs(enabled: false),
        stickerEditor: const StickerEditorConfigs(enabled: false),
        blurEditor: const BlurEditorConfigs(enabled: false),
      ),
    );
  }
}
