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
  registerDevice,
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
  });

  /// Idempotency key.
  String get opKey => '$deviceId:$seq';

  Map<String, dynamic> toJson() => {
        'k': kind.name,
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

  factory SyncOp.fromJson(Map<String, dynamic> json) => SyncOp(
        kind: SyncOpKind.values.firstWhere((k) => k.name == json['k']),
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
