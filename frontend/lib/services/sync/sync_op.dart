/// The op vocabulary of the multi-device sync log.
///
/// An op is an immutable fact: "device D, at HLC time T, did K to target X".
/// `(deviceId, seq)` is the global idempotency key — replaying the same op
/// twice is a no-op by construction. Ops are NEVER edited or deleted once
/// written; state is derived by deterministic replay (op_replay.dart).
library;

import 'hlc.dart';

enum SyncOpKind {
  createFile,
  deleteFile,

  /// Un-deletes from the Recycle Bin. Discovered wiring 2d: without an
  /// explicit restore op, an un-deleted file re-tombstones on every replay.
  restoreFile,

  /// PERMANENT deletion — the 30-day Recycle Bin sweep. Terminal and
  /// order-independent (purge always wins): the blob is physically gone, so
  /// no later restore can bring it back. Makes the bin sweep converge across
  /// devices instead of one device silently keeping a row another purged.
  purgeFile,
  renameFile,
  moveFile,
  setFavorite,
  createFolder,
  moveFolder,
  renameFolder,
  deleteFolder,

  /// Un-deletes a folder from the Recycle Bin as a UNIT (Model A): restores
  /// the folder and exactly the items its own delete cascade binned — files
  /// individually deleted before the folder delete stay deleted.
  restoreFolder,

  /// PERMANENT deletion of the folder ENTITY. Terminal like [purgeFile].
  /// The bin's "Delete forever" on a folder records one purgeFile per
  /// cascade-binned file PLUS purgeFolder for each folder in the dead
  /// subtree — contents are purged by their own explicit ops, so the
  /// condemned-blob sweep / reconcile tombstone guard / Vault Health never
  /// need to understand tree semantics.
  purgeFolder,

  /// Toggles a folder's "hidden from specialized views" flag. LWW like
  /// [renameFolder]. The bool payload rides the EXISTING generic [SyncOp.favorite]
  /// field (wire key 'v') — NEVER add a new wire field for a new kind:
  /// toJson/_opToRow only serialize fields this build knows, so an older
  /// build compacting a segment would silently strip an unknown key, while
  /// known fields round-trip verbatim.
  setFolderHidden,
  registerDevice,

  /// FORWARD-COMPAT SENTINEL, never recorded locally: an op whose kind
  /// string this build doesn't know (written by a newer app version). It is
  /// preserved VERBATIM — [SyncOp.rawKind] keeps the original string, so
  /// the op round-trips through sync_ops rows, segment JSON, and compaction
  /// snapshots unchanged — and replay simply ignores it. The moment the app
  /// updates, the already-merged rows materialize with full meaning. This
  /// is what keeps one new op kind from turning a whole segment into a
  /// poison pill for not-yet-updated devices.
  unknown,
}

class SyncOp {
  final SyncOpKind kind;

  /// Creating device (per-install identity, see DeviceIdentityService).
  final String deviceId;

  /// Per-device monotonic sequence — with [deviceId], the idempotency key.
  final int seq;

  final Hlc hlc;

  /// File id, folder id, or device id (for registerDevice).
  final String targetId;

  final String? name;

  /// Destination folder / new parent (null = root).
  final String? folderId;

  final bool? favorite;

  /// createFile only: SHA-256 hex of the plaintext (content identity, for
  /// cross-device dedup / reinstall matching) and the plaintext byte size
  /// (so a peer knows the expected size immediately — fixes the 0-byte
  /// display before reconcile joins the blob). Additive & optional: older
  /// ops simply lack them, newer clients ignore their absence.
  final String? hash;
  final int? size;

  /// createFile only: the moment the media was CAPTURED (EXIF DateTimeOriginal
  /// for photos, MediaStore DATE_TAKEN for gallery picks), as epoch ms. It is
  /// computed ONCE on the origin from the plaintext and shipped verbatim, so
  /// every device derives an IDENTICAL gallery order independent of either
  /// device's wall clock. Null for files with no capture metadata (screenshots
  /// without EXIF, downloads, documents); those fall back to the create op's
  /// HLC wall, which is also identical on every device. Additive & optional.
  final int? captured;

  /// Set ONLY when [kind] is [SyncOpKind.unknown]: the original kind string
  /// from a newer app version, preserved for verbatim round-tripping.
  final String? rawKind;

  const SyncOp({
    required this.kind,
    required this.deviceId,
    required this.seq,
    required this.hlc,
    required this.targetId,
    this.name,
    this.folderId,
    this.favorite,
    this.hash,
    this.size,
    this.captured,
    this.rawKind,
  });

  /// Idempotency key.
  String get opKey => '$deviceId:$seq';

  /// The wire/storage kind string — the ORIGINAL one for unknown ops, so
  /// verbatim folding stays verbatim across app versions.
  String get kindName => rawKind ?? kind.name;

  Map<String, dynamic> toJson() => {
        'k': kindName,
        'd': deviceId,
        's': seq,
        'h': hlc.toJson(),
        't': targetId,
        if (name != null) 'n': name,
        if (folderId != null) 'f': folderId,
        if (favorite != null) 'v': favorite,
        if (hash != null) 'ch': hash,
        if (size != null) 'sz': size,
        if (captured != null) 'ca': captured,
      };

  /// Resolves a kind string; null for strings this build doesn't know
  /// (including the sentinel's own name — 'unknown' is never a wire kind).
  static SyncOpKind? kindFromName(String? name) {
    for (final k in SyncOpKind.values) {
      if (k != SyncOpKind.unknown && k.name == name) return k;
    }
    return null;
  }

  /// TOLERANT by design: an unrecognized kind becomes [SyncOpKind.unknown]
  /// with [rawKind] preserved, instead of throwing — one new op kind from a
  /// newer app version must never make a whole segment unreadable.
  factory SyncOp.fromJson(Map<String, dynamic> json) {
    final raw = json['k'] as String;
    final kind = kindFromName(raw);
    return SyncOp(
      kind: kind ?? SyncOpKind.unknown,
      rawKind: kind == null ? raw : null,
      deviceId: json['d'] as String,
      seq: json['s'] as int,
      hlc: Hlc.fromJson(json['h'] as Map<String, dynamic>),
      targetId: json['t'] as String,
      name: json['n'] as String?,
      folderId: json['f'] as String?,
      favorite: json['v'] as bool?,
      hash: json['ch'] as String?,
      size: json['sz'] as int?,
      captured: json['ca'] as int?,
    );
  }

  /// The ONE sync_ops-row -> op mapping, shared by every reader (the
  /// engine, Vault Health, the device registry) so the three copies that
  /// used to drift cannot. Same tolerance as [SyncOp.fromJson].
  factory SyncOp.fromRow(Map<String, Object?> row) {
    final raw = row['kind'] as String;
    final kind = kindFromName(raw);
    return SyncOp(
      kind: kind ?? SyncOpKind.unknown,
      rawKind: kind == null ? raw : null,
      deviceId: row['device_id'] as String,
      seq: row['seq'] as int,
      hlc: Hlc(row['hlc_wall'] as int, row['hlc_counter'] as int),
      targetId: row['target_id'] as String,
      name: row['name'] as String?,
      folderId: row['folder_id'] as String?,
      favorite:
          row['favorite'] == null ? null : (row['favorite'] as int) == 1,
      hash: row['content_hash'] as String?,
      size: row['size_bytes'] as int?,
      captured: row['captured_at'] as int?,
    );
  }

  @override
  String toString() =>
      'SyncOp(${kind.name} $targetId by $deviceId#$seq @ $hlc)';

  /// The global total order: HLC, then deviceId, then seq. Identical on
  /// every device for every pair of ops — this is what makes replay
  /// deterministic and convergence possible.
  static int compare(SyncOp a, SyncOp b) {
    final h = a.hlc.compareTo(b.hlc);
    if (h != 0) return h;
    final d = a.deviceId.compareTo(b.deviceId);
    if (d != 0) return d;
    return a.seq.compareTo(b.seq);
  }
}
