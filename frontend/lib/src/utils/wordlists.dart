import 'package:flutter/services.dart' show rootBundle;

/// Lazily-loaded asset-backed wordlist. Loads exactly once per process and
/// is held in memory thereafter.
///
/// Assets registered in pubspec.yaml under `assets/wordlists/`.

class Bip39Wordlist {
  static List<String>? _list;
  static Set<String>? _set;

  /// The 2048-word BIP-39 English wordlist as an ordered list. Preserve
  /// order for anyone who needs indexed lookup by wordlist position.
  static Future<List<String>> load() async {
    if (_list != null) return _list!;
    final raw = await rootBundle
        .loadString('assets/wordlists/bip39_english.txt');
    _list = raw
        .split(RegExp(r'\r?\n'))
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return _list!;
  }

  /// Membership-test set. Same 2048 words as [load], hashed for O(1)
  /// lookup during autocomplete and per-word validation.
  static Future<Set<String>> loadSet() async {
    if (_set != null) return _set!;
    _set = (await load()).toSet();
    return _set!;
  }

  /// Filtered autocomplete candidates for [prefix]. Case-insensitive,
  /// trimmed. Returns at most [limit] entries. Empty prefix returns empty
  /// so a bare-focused field doesn't dump 2048 rows on the user.
  static Future<List<String>> autocomplete(
    String prefix, {
    int limit = 8,
  }) async {
    final p = prefix.trim().toLowerCase();
    if (p.isEmpty) return const [];
    final list = await load();
    final out = <String>[];
    for (final w in list) {
      if (w.startsWith(p)) {
        out.add(w);
        if (out.length >= limit) break;
      }
    }
    return out;
  }
}
