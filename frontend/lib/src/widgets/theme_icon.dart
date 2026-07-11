import 'package:flutter/material.dart';
import 'package:material_symbols_icons/get.dart';

import '../config/theme_controller.dart';
import '../config/theme_packs.dart';

/// Theme-aware icon. Maps a Phosphor camelCase name (or a raw Material Symbol
/// snake_case name) to the right Material Symbol, then renders it with the
/// active theme pack's icon cut (Outlined / Rounded / Sharp) and weight.
///
/// Use [selected] for active/filled states — that flips the FILL axis on
/// fonts that support it, mirroring `<span class="mi fill">` in the CSS
/// design system.
///
/// Existing code migrates one-to-one:
///   Icon(PhosphorIcons.heart(PhosphorIconsStyle.thin), color: cs.primary)
/// →  ThemeIcon('heart', color: cs.primary)
///
///   Icon(PhosphorIcons.heart(PhosphorIconsStyle.fill), color: cs.primary)
/// →  ThemeIcon('heart', selected: true, color: cs.primary)
class ThemeIcon extends StatelessWidget {
  /// Phosphor camelCase name (e.g. `'arrowsClockwise'`) OR a Material Symbol
  /// snake_case name (e.g. `'refresh'`). Both forms resolve to the same glyph.
  final String name;
  final double? size;
  final Color? color;
  final bool selected;

  const ThemeIcon(
    this.name, {
    super.key,
    this.size,
    this.color,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final pack = ThemeController().pack;
    final mat = _resolveMaterialName(name);
    final cut = _cutFor(pack);
    final iconData = SymbolsGet.get(mat, cut);
    final fontWeight = _weightFor(pack, selected: selected);

    return Icon(
      iconData,
      size: size,
      color: color,
      fill: selected ? 1.0 : _fillFor(pack),
      weight: fontWeight,
      grade: _gradeFor(pack),
    );
  }
}

/// Static helper for places that need an `IconData` (not a Widget) — e.g.
/// `BottomNavigationBarItem(icon: Icon(...))`. Returns a Material Symbol
/// IconData with the right cut for the current pack.
IconData themeIconData(String name, {bool selected = false}) {
  final pack = ThemeController().pack;
  final mat = _resolveMaterialName(name);
  return SymbolsGet.get(mat, _cutFor(pack));
}

// ===========================================================================
// PHOSPHOR (camelCase) → MATERIAL SYMBOL (snake_case) name resolution
// ===========================================================================

/// Returns the Material Symbol snake_case name for [input]. If [input] is
/// already a Material Symbol name (or not in our map), it's returned
/// unchanged so callers can also pass Material names directly.
String _resolveMaterialName(String input) {
  return _phosphorToMaterial[input] ?? input;
}

/// Single source of truth for the rename. Built from the design system's
/// `fonts/_icon_map.json`, with extras for Phosphor names not in the JSON
/// (Material Symbols doesn't ship vendor logos; those collapse to
/// generic equivalents).
const Map<String, String> _phosphorToMaterial = {
  // From _icon_map.json (kebab → camel translation):
  'arrowsClockwise': 'refresh',
  'arrowsCounterClockwise': 'refresh',
  'arrowCounterClockwise': 'undo',
  'arrowLeft': 'arrow_back',
  'arrowSquareOut': 'open_in_new',
  'broom': 'cleaning_services',
  'calendar': 'calendar_today',
  'camera': 'photo_camera',
  'caretDown': 'expand_more',
  'caretRight': 'chevron_right',
  'check': 'check',
  'checkCircle': 'check_circle',
  'clipboardText': 'content_paste',
  'clock': 'schedule',
  'clockCountdown': 'hourglass_empty',
  'clockCounterClockwise': 'history',
  'cloud': 'cloud',
  'cloudArrowDown': 'cloud_download',
  'cloudArrowUp': 'cloud_upload',
  'cloudCheck': 'cloud_done',
  'cloudSlash': 'cloud_off',
  'copy': 'content_copy',
  'cornersOut': 'fullscreen',
  'database': 'database',
  'devices': 'devices',
  'dotsThreeVertical': 'more_vert',
  'downloadSimple': 'download',
  'dropboxLogo': 'cloud',
  'fastForward': 'fast_forward',
  'file': 'insert_drive_file',
  'fileCode': 'code',
  'fileCsv': 'csv',
  'fileDoc': 'description',
  'filePdf': 'picture_as_pdf',
  'filePpt': 'slideshow',
  'fileText': 'description',
  'fileX': 'unknown_document',
  'fileXls': 'table_chart',
  'fileZip': 'folder_zip',
  'fingerprint': 'fingerprint',
  'folder': 'folder',
  'folderOpen': 'folder_open',
  'folderSimple': 'folder',
  'gear': 'settings',
  'gearSix': 'settings',
  'globe': 'public',
  'googleDriveLogo': 'add_to_drive',
  'googleLogo': 'account_circle',
  'handTap': 'touch_app',
  'hardDrive': 'storage',
  'heart': 'favorite',
  'house': 'home',
  'image': 'image',
  'imageBroken': 'broken_image',
  'imageSquare': 'image',
  'images': 'photo_library',
  'infinity': 'all_inclusive',
  'info': 'info',
  'key': 'key',
  'link': 'link',
  'linkSimple': 'link',
  'list': 'list',
  'lock': 'lock',
  'lockKey': 'lock',
  'lockKeyOpen': 'lock_open',
  'lockSimple': 'lock',
  'magnifyingGlass': 'search',
  'microphone': 'mic',
  'microsoftOutlookLogo': 'mail',
  'minusCircle': 'remove_circle',
  'moon': 'dark_mode',
  'mountains': 'landscape',
  'musicNote': 'music_note',
  'musicNotes': 'music_note',
  'notebook': 'menu_book',
  'password': 'password',
  'pause': 'pause',
  'pauseCircle': 'pause_circle',
  'pencilSimple': 'edit',
  'play': 'play_arrow',
  'playCircle': 'play_circle',
  'playlist': 'queue_music',
  'plus': 'add',
  'presentation': 'present_to_all',
  'printer': 'print',
  'rewind': 'fast_rewind',
  'screencast': 'cast',
  'screenshotFrame': 'screenshot_frame',
  'sealCheck': 'verified',
  'shareFat': 'share',
  'shareNetwork': 'share',
  'shieldCheck': 'verified_user',
  'shieldWarning': 'gpp_maybe',
  'signIn': 'login',
  'signOut': 'logout',
  'skipBack': 'skip_previous',
  'skipForward': 'skip_next',
  'sortAscending': 'sort',
  'sparkle': 'auto_awesome',
  'speakerHigh': 'volume_up',
  'speakerSlash': 'volume_off',
  'squaresFour': 'grid_view',
  'star': 'star',
  'stop': 'stop',
  'sun': 'light_mode',
  'table': 'table_chart',
  'textT': 'text_fields',
  'timer': 'timer',
  'trash': 'delete',
  'trashSimple': 'delete',
  'uploadSimple': 'upload',
  'vault': 'encrypted',
  'videoCamera': 'videocam',
  'warning': 'warning',
  'warningCircle': 'error',
  'waveform': 'graphic_eq',
  'wifiHigh': 'wifi',
  'x': 'close',
  'xCircle': 'cancel',
};

// ===========================================================================
// PER-PACK ICON AXIS RULES — mirrors the `--icon-font` / `--icon-fill` /
// `--icon-wght` / `--icon-grad` tokens in themes.css.
// ===========================================================================

SymbolStyle _cutFor(ThemePack pack) {
  switch (pack) {
    case ThemePack.binary: return SymbolStyle.outlined;
    case ThemePack.burrow: return SymbolStyle.rounded;
    case ThemePack.corporate: return SymbolStyle.sharp;
    case ThemePack.alien: return SymbolStyle.rounded;
    case ThemePack.paper: return SymbolStyle.outlined;
    case ThemePack.garnet: return SymbolStyle.sharp;
    case ThemePack.hackerman: return SymbolStyle.sharp;
  }
}

double _fillFor(ThemePack pack) {
  // `selected: true` always overrides this with 1.0. Only Burrow/Alien start
  // pre-filled (their `--icon-fill` is 1 by default in themes.css).
  switch (pack) {
    case ThemePack.burrow: return 1.0;
    case ThemePack.alien: return 1.0;
    default: return 0.0;
  }
}

double _weightFor(ThemePack pack, {required bool selected}) {
  switch (pack) {
    // Raised from the design system's 100 — hairline glyphs were barely
    // visible on device, so Binary matches Corporate's weight.
    case ThemePack.binary: return 300;
    case ThemePack.burrow: return 300;
    case ThemePack.corporate: return 300;
    case ThemePack.alien: return 700;
    case ThemePack.paper: return 200;
    case ThemePack.garnet: return 400;
    case ThemePack.hackerman: return selected ? 500 : 400;
  }
}

double _gradeFor(ThemePack pack) {
  switch (pack) {
    case ThemePack.burrow: return 200;
    case ThemePack.alien: return 200;
    default: return 0;
  }
}
