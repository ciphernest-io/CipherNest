/// Append-only enum: existing rows in the DB store the integer index, so new
/// values must be added at the END to preserve backward compatibility.
enum CnestFileType { image, document, other, audio }

/// Wire-format string used by cloud providers to round-trip the type through
/// Drive `appProperties` / OneDrive filename-encoded metadata. Keep stable —
/// changing these strings would orphan files that were uploaded earlier.
extension CnestFileTypeWire on CnestFileType {
  String get wireName {
    switch (this) {
      case CnestFileType.image:    return 'image';
      case CnestFileType.document: return 'document';
      case CnestFileType.audio:    return 'audio';
      case CnestFileType.other:    return 'other';
    }
  }

  static CnestFileType? fromWire(String? s) {
    switch (s) {
      case 'image':    return CnestFileType.image;
      case 'document': return CnestFileType.document;
      case 'audio':    return CnestFileType.audio;
      case 'other':    return CnestFileType.other;
      default:         return null;
    }
  }

  /// Best-effort inference from a filename's extension. Used when reconciling
  /// blobs uploaded by older app versions that only tagged image/document.
  static CnestFileType fromFilename(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return CnestFileType.other;
    final ext = filename.substring(dot + 1).toLowerCase();
    if (_imageExts.contains(ext) || _videoExts.contains(ext)) {
      return CnestFileType.image;
    }
    if (_audioExts.contains(ext)) return CnestFileType.audio;
    if (_documentExts.contains(ext)) return CnestFileType.document;
    return CnestFileType.other;
  }
}

const Set<String> _imageExts = {
  'jpg', 'jpeg', 'png', 'heic', 'heif', 'webp', 'gif', 'bmp', 'tiff'
};
const Set<String> _videoExts = {
  'mp4', 'mov', 'avi', 'mkv', 'webm', 'flv', 'wmv', '3gp'
};
const Set<String> _audioExts = {
  'mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus', 'wma'
};
const Set<String> _documentExts = {
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf', 'odt', 'csv'
};

class CnestFile {
  final String id;
  final String? cloudId;
  final String? thumbnailCloudId;
  final int provider; // 0=Google, 1=OneDrive, 2=Dropbox
  final String? accountId; // The email (e.g. user@gmail.com)
  final String filename;
  final int sizeBytes;
  final DateTime createdAt;
  final bool isUploaded;
  final String? localPath;
  final String? assetId;
  final bool isFavorite;
  final CnestFileType type;

  /// SHA-256 hex of the PLAINTEXT bytes — the file's true content identity.
  /// Null for legacy rows uploaded before hashing existed; verification
  /// falls back to size-only in that case.
  final String? contentHash;

  /// Pixel dimensions and playback length, captured at upload time while the
  /// plaintext is still in hand (v12). Null for legacy rows and for files
  /// whose source couldn't be parsed — the details sheet then falls back to
  /// the AssetEntity / local-file tiers exactly as before.
  final int? width;
  final int? height;
  final int? durationMs;

  /// Video codec / audio codec / frame rate (v13) — same capture-at-upload
  /// contract as the v12 fields. Device model for videos is deliberately
  /// absent: the MP4 parser reads no udta atoms and MediaStore stores none,
  /// so Samsung-style "Galaxy A55 5G" rows are unobtainable for videos.
  final String? videoCodec;
  final String? audioCodec;
  final int? fps;

  /// Recording device (v14) — from the video's udta vendor atoms; null for
  /// photos (their EXIF Model is read at display time) and for videos
  /// whose producer wrote none.
  final String? deviceModel;

  /// Wall-clock ms of the most recent upload ATTEMPT (v12). This — not
  /// [createdAt], which holds the media's capture time — is what the
  /// pending-upload heal grace compares, so an old photo picked today still
  /// gets its in-flight protection window.
  final int? uploadStartedAt;

  /// Virtual-tree location (v15): the live folder containing this file,
  /// null = root. Op-owned — applyMergedState keeps it normalized
  /// (live-or-root); typed tabs ignore it (lens ON) unless the user turns
  /// folder scoping on.
  final String? folderId;

  /// Cascade cause (v15): the deleted folder whose delete binned this file;
  /// null = live, or individually deleted. The bin's type tabs exclude
  /// cause-carrying rows (they belong to the folder's single entry) and
  /// search uses it for the `Restore '<folder>'` CTA.
  final String? deletedByFolderId;

  CnestFile({
    required this.id,
    this.cloudId,
    this.thumbnailCloudId,
    this.provider = 0, // Default to Google for now
    this.accountId,
    required this.filename,
    required this.sizeBytes,
    required this.createdAt,
    this.isUploaded = false,
    this.localPath,
    this.assetId,
    this.isFavorite = false,
    required this.type,
    this.contentHash,
    this.width,
    this.height,
    this.durationMs,
    this.videoCodec,
    this.audioCodec,
    this.fps,
    this.deviceModel,
    this.uploadStartedAt,
    this.folderId,
    this.deletedByFolderId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'cloud_id': cloudId,
      'thumbnail_cloud_id': thumbnailCloudId,
      'provider': provider,
      'account_id': accountId,
      'filename': filename,
      'size_bytes': sizeBytes,
      'created_at': createdAt.millisecondsSinceEpoch,
      'is_uploaded': isUploaded ? 1 : 0,
      'local_path': localPath,
      'asset_id': assetId,
      'is_favorite': isFavorite ? 1 : 0,
      'type': type.index,
      'content_hash': contentHash,
      'width': width,
      'height': height,
      'duration_ms': durationMs,
      'video_codec': videoCodec,
      'audio_codec': audioCodec,
      'fps': fps,
      'device_model': deviceModel,
      'upload_started_at': uploadStartedAt,
      'folder_id': folderId,
      'deleted_by_folder_id': deletedByFolderId,
    };
  }

  /// Non-null overrides only — a null argument keeps the current value
  /// (clearing a nullable field is not supported; no caller needs it).
  /// Every field is enumerated in the constructor call below so an in-memory
  /// copy can never silently drop columns the way hand-rebuilt literals did.
  CnestFile copyWith({
    String? filename,
    DateTime? createdAt,
    bool? isFavorite,
    bool? isUploaded,
    String? cloudId,
    String? thumbnailCloudId,
    String? localPath,
    String? contentHash,
    int? sizeBytes,
  }) {
    return CnestFile(
      id: id,
      cloudId: cloudId ?? this.cloudId,
      thumbnailCloudId: thumbnailCloudId ?? this.thumbnailCloudId,
      provider: provider,
      accountId: accountId,
      filename: filename ?? this.filename,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt ?? this.createdAt,
      isUploaded: isUploaded ?? this.isUploaded,
      localPath: localPath ?? this.localPath,
      assetId: assetId,
      isFavorite: isFavorite ?? this.isFavorite,
      type: type,
      contentHash: contentHash ?? this.contentHash,
      width: width,
      height: height,
      durationMs: durationMs,
      videoCodec: videoCodec,
      audioCodec: audioCodec,
      fps: fps,
      deviceModel: deviceModel,
      uploadStartedAt: uploadStartedAt,
      folderId: folderId,
      deletedByFolderId: deletedByFolderId,
    );
  }

  factory CnestFile.fromMap(Map<String, dynamic> map) {
    return CnestFile(
      id: map['id'],
      cloudId: map['cloud_id'],
      thumbnailCloudId: map['thumbnail_cloud_id'],
      provider: map['provider'] ?? 0,
      accountId: map['account_id'],
      filename: map['filename'],
      sizeBytes: map['size_bytes'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']),
      isUploaded: map['is_uploaded'] == 1,
      localPath: map['local_path'],
      assetId: map['asset_id'],
      isFavorite: (map['is_favorite'] as int? ?? 0) == 1,
      type: CnestFileType.values[map['type'] ?? 0],
      contentHash: map['content_hash'] as String?,
      width: map['width'] as int?,
      height: map['height'] as int?,
      durationMs: map['duration_ms'] as int?,
      videoCodec: map['video_codec'] as String?,
      audioCodec: map['audio_codec'] as String?,
      fps: map['fps'] as int?,
      deviceModel: map['device_model'] as String?,
      uploadStartedAt: map['upload_started_at'] as int?,
      folderId: map['folder_id'] as String?,
      deletedByFolderId: map['deleted_by_folder_id'] as String?,
    );
  }
}