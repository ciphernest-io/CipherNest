import 'dart:ui' show Color;

import '../config/theme_packs.dart';

/// The ONE extension → (icon, color) mapping for non-media file rows —
/// browser, Documents tab fallback, Other Files tab. Union of the three
/// private maps that used to disagree (csv resolved to 'fileCsv').
({String icon, Color color}) fileVisual(String filename, ThemePackTokens t) {
  final dot = filename.lastIndexOf('.');
  final ext = dot < 0 || dot == filename.length - 1
      ? ''
      : filename.substring(dot + 1).toLowerCase().trim();
  // File-type marks keep their real, recognizable colours on EVERY theme
  // (a PDF is red even in the monochrome Binary pack). Mid-tone brand colours,
  // legible on both light and dark grounds. Only truly generic files fall back
  // to the theme's muted foreground.
  return switch (ext) {
    'pdf' => (icon: 'filePdf', color: const Color(0xFFE53935)), // red
    'doc' || 'docx' => (icon: 'fileText', color: const Color(0xFF4285F4)), // blue
    'xls' || 'xlsx' => (icon: 'table', color: const Color(0xFF21A366)), // green
    'csv' || 'tsv' => (icon: 'fileCsv', color: const Color(0xFF21A366)), // green
    'ppt' || 'pptx' => (icon: 'presentation', color: const Color(0xFFED6C47)), // orange
    'txt' => (icon: 'textT', color: const Color(0xFF78909C)), // blue-grey
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => (
        icon: 'fileZip',
        color: const Color(0xFFF9A825), // amber
      ),
    'py' || 'js' || 'ts' || 'dart' || 'java' || 'c' || 'cpp' || 'rs' ||
    'go' =>
      (icon: 'fileCode', color: const Color(0xFF42A5F5)), // blue
    'ipynb' => (icon: 'notebook', color: const Color(0xFFF37726)), // jupyter orange
    'db' || 'sqlite' || 'sqlite3' => (icon: 'database', color: const Color(0xFF7E8AA0)), // slate
    'mp3' || 'm4a' || 'wav' || 'flac' || 'aac' || 'ogg' || 'opus' ||
    'wma' =>
      (icon: 'musicNote', color: const Color(0xFF7E57C2)), // purple
    _ => (icon: 'file', color: t.fgMuted),
  };
}
