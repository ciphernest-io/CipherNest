/// Append-only enum: existing rows in the DB store the integer index, so new
/// values must be added at the END to preserve backward compatibility.
enum CnestFileType { image, document, other, audio }

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
      type: CnestFileType.values[map['type'] ?? 0],
    );
  }
}