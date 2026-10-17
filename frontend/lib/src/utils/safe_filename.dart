/// Reduces a vault filename to one safe path component for use under the
/// app's cache directory (MASVS F-07).
///
/// Vault filenames come from the user's own uploads, but also from the sync
/// log written by any device holding the phrase, so they are treated as
/// untrusted when they are turned into a local path: separators are dropped,
/// control and reserved characters replaced, and `.`/`..` refused.
String safeFilename(String name) {
  var base = name.replaceAll('\\', '/');
  base = base.substring(base.lastIndexOf('/') + 1);
  base = base.replaceAll(RegExp(r'[\x00-\x1f:*?"<>|]'), '_').trim();
  if (base.isEmpty || base == '.' || base == '..') return 'file';
  return base;
}
