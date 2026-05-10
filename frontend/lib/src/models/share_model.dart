/// A record of an outbound share created by this user.
/// Stored locally so the user can list and revoke their shares.
class CnestShare {
  final String id;
  final String fileId;        // local CnestFile.id
  final String cloudId;       // cloud blob ID of the SHARE copy (not the original)
  final String downloadUrl;   // public URL recipients fetch the encrypted blob from
  final String shareUrl;      // full magic link including fragment
  final bool hasPassword;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final String accountId;     // composite provider+email — same scoping as files

  CnestShare({
    required this.id,
    required this.fileId,
    required this.cloudId,
    required this.downloadUrl,
    required this.shareUrl,
    required this.hasPassword,
    this.expiresAt,
    required this.createdAt,
    required this.accountId,
  });

  bool get isExpired {
    if (expiresAt == null) return false;
    return DateTime.now().isAfter(expiresAt!);
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'file_id': fileId,
      'cloud_id': cloudId,
      'download_url': downloadUrl,
      'share_url': shareUrl,
      'has_password': hasPassword ? 1 : 0,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
      'created_at': createdAt.millisecondsSinceEpoch,
      'account_id': accountId,
    };
  }

  factory CnestShare.fromMap(Map<String, dynamic> map) {
    return CnestShare(
      id: map['id'] as String,
      fileId: map['file_id'] as String,
      cloudId: map['cloud_id'] as String,
      downloadUrl: map['download_url'] as String,
      shareUrl: map['share_url'] as String,
      hasPassword: (map['has_password'] as int) == 1,
      expiresAt: map['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['expires_at'] as int)
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      accountId: map['account_id'] as String,
    );
  }
}
