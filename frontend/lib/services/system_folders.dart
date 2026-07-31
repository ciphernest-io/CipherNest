import 'package:uuid/uuid.dart';

/// Deterministic ids for the auto-sync system folders ("Phone Backup" and
/// its per-bucket children). Two rules make the whole feature converge with
/// ZERO wire or replay changes:
///
///  1. Ids are UUIDv5 of the normalized bucket name, so every device mints
///     the SAME id independently — replay's first-create-wins guard folds
///     the duplicate createFolder ops into one folder.
///  2. Ids carry a `sys-` prefix, so `is_system` is a pure function of the
///     id. The column is stamped in applyMergedState's derived map — it can
///     never diverge across devices because the id itself is synced. It
///     also survives rename: a renamed system folder stays a system folder.
///
/// User-created folders get plain UUIDv4 ids, so no false positives.
class SystemFolders {
  SystemFolders._();

  /// Fixed private namespace for the v5 derivation. FROZEN — changing it
  /// changes every system folder id and orphans existing trees.
  static const String _namespace = '8f6a1c2e-4b7d-4f3a-9e15-c0d2a6b83e51';

  static const String idPrefix = 'sys-';

  /// Display name of the root system folder shown at the vault root.
  static const String rootName = 'Phone Backup';

  /// The single root all bucket folders nest under.
  static final String rootId =
      idPrefix + const Uuid().v5(_namespace, 'phone-backup-root');

  /// Bucket names are matched case- and whitespace-insensitively so
  /// "WhatsApp Images" and "whatsapp  images" (OEM quirks) map to one
  /// folder.
  static String normalizeBucket(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static String bucketId(String bucketName) =>
      idPrefix +
      const Uuid().v5(_namespace, 'bucket:${normalizeBucket(bucketName)}');

  static bool isSystemId(String id) => id.startsWith(idPrefix);
}
