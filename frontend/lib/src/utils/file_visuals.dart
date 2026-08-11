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
  return switch (ext) {
    'pdf' => (icon: 'filePdf', color: t.danger),
    'doc' || 'docx' => (icon: 'fileText', color: t.info),
    'xls' || 'xlsx' => (icon: 'table', color: t.success),
    'csv' || 'tsv' => (icon: 'fileCsv', color: t.success),
    'ppt' || 'pptx' => (icon: 'presentation', color: t.warning),
    'txt' => (icon: 'textT', color: t.fgMuted),
    'zip' || 'rar' || '7z' || 'tar' || 'gz' => (
        icon: 'fileZip',
        color: t.warning
      ),
    'py' || 'js' || 'ts' || 'dart' || 'java' || 'c' || 'cpp' || 'rs' ||
    'go' =>
      (icon: 'fileCode', color: t.info),
    'ipynb' => (icon: 'notebook', color: t.info),
    'db' || 'sqlite' || 'sqlite3' => (icon: 'database', color: t.fgMuted),
    'mp3' || 'm4a' || 'wav' || 'flac' || 'aac' || 'ogg' || 'opus' ||
    'wma' =>
      (icon: 'musicNote', color: t.info),
    _ => (icon: 'file', color: t.fgMuted),
  };
}
