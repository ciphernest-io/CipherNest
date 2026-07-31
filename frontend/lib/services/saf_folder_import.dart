import 'package:flutter/services.dart';

/// One file inside a picked SAF tree. [dir] is the slash-joined relative
/// directory ('' = the tree root); the folder structure is derived from it.
class SafTreeEntry {
  final String name;
  final String dir;
  final int size;
  final String uri;
  const SafTreeEntry({
    required this.name,
    required this.dir,
    required this.size,
    required this.uri,
  });
}

class SafTree {
  final String name;
  final List<SafTreeEntry> entries;

  /// True when the native walk hit its file cap and stopped — the user
  /// must be told the import is partial, never left assuming coverage.
  final bool truncated;
  const SafTree(
      {required this.name, required this.entries, required this.truncated});
}

/// SAF folder import: ACTION_OPEN_DOCUMENT_TREE + DocumentFile traversal on
/// the Kotlin side, per-file copy-to-cache here so only ONE plaintext copy
/// exists on disk at a time (app-private cache; the upload pipeline deletes
/// it in its finally). Pre-authorized fallback if OEM pickers misbehave:
/// the callers degrade to multi-file selection.
class SafFolderImport {
  static const _channel = MethodChannel('ciphernest/platform');

  /// Opens the system folder picker and enumerates the tree. Null = user
  /// cancelled (or no documents UI). Throws [PlatformException] on a
  /// provider failure — callers surface that as "try selecting files".
  static Future<SafTree?> pickTree() async {
    final res = await _channel.invokeMethod<dynamic>('pickFolderTree');
    if (res == null) return null;
    final map = Map<Object?, Object?>.from(res as Map);
    final entries = (map['entries'] as List? ?? const [])
        .map((e) {
          final m = Map<Object?, Object?>.from(e as Map);
          return SafTreeEntry(
            name: m['name'] as String? ?? 'file',
            dir: m['dir'] as String? ?? '',
            size: (m['size'] as num?)?.toInt() ?? 0,
            uri: m['uri'] as String? ?? '',
          );
        })
        .where((e) => e.uri.isNotEmpty)
        .toList();
    return SafTree(
      name: map['name'] as String? ?? 'Imported folder',
      entries: entries,
      truncated: map['truncated'] as bool? ?? false,
    );
  }

  /// Copies one document into the app cache and returns its path, or null
  /// on failure (unreadable document — the caller counts it as a per-file
  /// failure and moves on).
  static Future<String?> copyToCache(SafTreeEntry entry) async {
    try {
      return await _channel.invokeMethod<String>('copyDocumentToCache', {
        'uri': entry.uri,
        'name': entry.name,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
