import 'package:uuid/uuid.dart';

/// Deterministic ids for the auto-sync system tree:
/// `Phone Backup / <Device> / <real MediaStore path>` (pCloud-style, e.g.
/// Phone Backup / Samsung SM-A556E / DCIM / Camera). Two rules make the
/// whole feature converge with ZERO wire or replay changes:
///
///  1. Ids are UUIDv5 of a normalized derivation key, so a device mints the
///     SAME id for the same place every run — replay's first-create-wins
///     guard folds the duplicate createFolder ops into one folder. The
///     device level is keyed on the MODEL string (reinstall-stable), which
///     deliberately splits two phones into two subtrees — and, accepted
///     trade-off, merges two physically distinct handsets of the same model.
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

  /// The single root every device's subtree nests under.
  static final String rootId =
      idPrefix + const Uuid().v5(_namespace, 'phone-backup-root');

  /// Derivation keys are matched case- and whitespace-insensitively so
  /// OEM quirks ("WhatsApp Images" vs "whatsapp  images") map to one
  /// folder.
  static String normalize(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Stable per phone MODEL (reinstall-proof): 'samsung sm-a556e'.
  static String deviceKey(String manufacturer, String model) =>
      normalize('$manufacturer $model');

  /// The device-level folder under Phone Backup.
  static String deviceId(String deviceKey) =>
      idPrefix + const Uuid().v5(_namespace, 'device:$deviceKey');

  /// 'Samsung SM-A556E' — manufacturer capitalized, model verbatim.
  static String deviceDisplayName(String manufacturer, String model) {
    final m = manufacturer.trim();
    final cap = m.isEmpty ? '' : m[0].toUpperCase() + m.substring(1);
    return [cap, model.trim()].where((s) => s.isNotEmpty).join(' ');
  }

  /// Deterministic id for one CUMULATIVE path prefix under one device —
  /// ['DCIM'] and ['DCIM', 'Camera'] are two folders, parent and child.
  static String pathSegmentId(String deviceKey, List<String> segments) =>
      idPrefix +
      const Uuid().v5(
          _namespace, 'path:$deviceKey/${segments.map(normalize).join('/')}');

  static bool isSystemId(String id) => id.startsWith(idPrefix);
}
