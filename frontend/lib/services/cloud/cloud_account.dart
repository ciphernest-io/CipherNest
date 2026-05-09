/// Represents a single cloud account a user has signed into.
/// One CipherNest user can have many accounts (e.g. work Gmail + personal Outlook).
/// At any moment exactly one is "active" (managed by AccountRegistry).
class CloudAccount {
  static const int providerGoogle = 0;
  static const int providerOneDrive = 1;
  static const int providerDropbox = 2;

  final int providerType;
  final String email;

  /// Cached short-lived access token. Refreshed on demand by the provider.
  final String? accessToken;

  /// Long-lived refresh token. Used to get a new access token when expired.
  /// Some providers (Google via google_sign_in) don't expose this — null is fine.
  final String? refreshToken;

  /// Absolute timestamp when the access token expires.
  final DateTime? expiresAt;

  CloudAccount({
    required this.providerType,
    required this.email,
    this.accessToken,
    this.refreshToken,
    this.expiresAt,
  });

  /// Composite key — uniquely identifies one (provider, account) pair.
  String get id => '${providerType}_$email';

  String get providerName {
    switch (providerType) {
      case providerGoogle:
        return 'Google';
      case providerOneDrive:
        return 'OneDrive';
      case providerDropbox:
        return 'Dropbox';
      default:
        return 'Unknown';
    }
  }

  bool get isAccessTokenExpired {
    if (expiresAt == null) return true;
    return DateTime.now().isAfter(expiresAt!.subtract(const Duration(seconds: 60)));
  }

  CloudAccount copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
  }) {
    return CloudAccount(
      providerType: providerType,
      email: email,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt: expiresAt ?? this.expiresAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'provider_type': providerType,
      'email': email,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
    };
  }

  factory CloudAccount.fromMap(Map<String, dynamic> map) {
    return CloudAccount(
      providerType: map['provider_type'] as int,
      email: map['email'] as String,
      accessToken: map['access_token'] as String?,
      refreshToken: map['refresh_token'] as String?,
      expiresAt: map['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['expires_at'] as int)
          : null,
    );
  }
}
