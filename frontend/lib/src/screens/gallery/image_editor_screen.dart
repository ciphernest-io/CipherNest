import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // The editor follows the app's current brightness: a light-mode app gets
    // a light editor, dark gets dark. Every bar foreground, background and
    // canvas below is bound to the pack's tokens (primary / surface /
    // scaffold), which flip with the brightness, so the chrome stays legible
    // in both. The pack and its light/dark variant still supply the accent
    // and type, so Burrow's editor is not Binary's.
    final theme = AppTheme.build(
      pack: ThemeController().pack,
      mode: Theme.of(context).brightness,
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
    // The OS bars follow the editor's brightness too: in a light-mode app the
    // status bar (clock, wifi, battery) and the bottom gesture/navigation bar
    // get dark icons on a light surface, in dark mode light icons on a dark
    // surface. Each sub-editor wraps itself in an AnnotatedRegion built from
    // its own style's `uiOverlayStyle`, but every sub-editor ALSO builds a
    // Material `AppBar`, and an AppBar injects its OWN deeper AnnotatedRegion
    // from `appBarTheme.systemOverlayStyle`. That inner region wins, and the
    // app's default value is the const `SystemUiOverlayStyle.dark/.light`,
    // which hardcodes a black nav bar with light icons. So the real lever is
    // the editor theme's `appBarTheme.systemOverlayStyle`; the per-style
    // `uiOverlayStyle` below is the matching outer layer.
    final isLight = Theme.of(context).brightness == Brightness.light;
    final barIcons = isLight ? Brightness.dark : Brightness.light;
    final overlay = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: barIcons,
      statusBarBrightness: isLight ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: barBg,
      systemNavigationBarDividerColor: barBg,
      systemNavigationBarIconBrightness: barIcons,
    );

    final axes = themeIconAxes();
    final editorTheme = theme.copyWith(
      iconTheme: theme.iconTheme.merge(axes),
      appBarTheme: theme.appBarTheme.copyWith(
        systemOverlayStyle: overlay,
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
            uiOverlayStyle: overlay,
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
            uiOverlayStyle: overlay,
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
            uiOverlayStyle: overlay,
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
            uiOverlayStyle: overlay,
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
            uiOverlayStyle: overlay,
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
