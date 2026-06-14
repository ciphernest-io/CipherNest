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
    };
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
    );
  }
}