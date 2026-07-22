/// Duplicate-upload rename: "photo.jpg" → "photo (1).jpg", Samsung/Windows
/// style. Pure string logic so it unit-tests without a database.
library;

/// Splits [name] into (stem, extension-with-dot). A leading dot ("​.env")
/// counts as extension-less — renaming it to " (1).env" would be wrong.
(String, String) _splitExt(String name) {
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return (name, '');
  return (name.substring(0, dot), name.substring(dot));
}

/// The stem to query candidate collisions for: the base name with any
/// existing " (n)" counter stripped, so uploading "photo (1).jpg" fetches
/// the whole "photo…" family and counts up instead of nesting.
String dedupQueryPrefix(String desired) {
  final (stem, _) = _splitExt(desired);
  final m = RegExp(r'^(.*) \(\d+\)$').firstMatch(stem);
  return m != null ? m.group(1)! : stem;
}

/// Returns [desired] unchanged when free, else the first "base (k)" name
/// not present in [taken]. An existing " (n)" suffix continues counting
/// ("photo (1).jpg" → "photo (2).jpg", never "photo (1) (1).jpg").
String nextAvailableFilename(String desired, Set<String> taken) {
  if (!taken.contains(desired)) return desired;
  final (stem, ext) = _splitExt(desired);
  final m = RegExp(r'^(.*) \((\d+)\)$').firstMatch(stem);
  final base = m != null ? m.group(1)! : stem;
  var k = m != null ? int.parse(m.group(2)!) + 1 : 1;
  while (true) {
    final candidate = '$base ($k)$ext';
    if (!taken.contains(candidate)) return candidate;
    k++;
  }
}
