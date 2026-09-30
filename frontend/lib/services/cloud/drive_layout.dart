/// Shared cloud-storage layout for CipherNest's visible vault. Both the
/// Google Drive and OneDrive providers create the same tree under the user's
/// normal storage:
///
/// ```
/// CipherNest/
///   README.txt        ← plaintext warning (below)
///   vault/            ← .cnest + _thumb.cnest blobs
///   backup/           ← ciphernest_db_backup.cnest
///   shares/           ← public share blobs (anyone-with-link)
/// ```
///
/// Visible (not a hidden app-data folder) on purpose: it matches Cryptomator,
/// supports data portability, and means a user's encrypted data never depends
/// on CipherNest continuing to exist. The cost — files the user could delete
/// in the Drive UI — is mitigated by the README and in-app warnings.
class DriveLayout {
  DriveLayout._();

  static const String rootFolder = 'CipherNest';
  static const String vaultFolder = 'vault';
  static const String backupFolder = 'backup';

  /// backup/log/ — append-only multi-device op-log segments + compaction
  /// snapshots. Objects here are immutable once written.
  static const String logFolder = 'log';
  static const String sharesFolder = 'shares';
  static const String readmeName = 'README.txt';

  /// Plaintext README dropped into the vault root so anyone browsing their
  /// Drive understands what these opaque files are and why not to touch them.
  static const String readmeContents = '''
CipherNest Vault. Please do not delete, move, or rename anything in this folder.

This folder holds your photos, videos, documents, and music, encrypted on your
device before they were uploaded. CipherNest cannot read them, and neither can
Google or Microsoft. Only your recovery phrase can. The random filenames and
unreadable contents are normal and by design.

Deleting, moving, or renaming files here permanently loses that data. No one,
including us, can recover it. To remove files, use the CipherNest app's Recycle
Bin, not your cloud storage's web interface.

  vault/   your encrypted files
  backup/  an encrypted copy of your vault index (for multi-device / recovery)
  shares/  files you have shared by link (each is separately encrypted)

Learn more inside the app: Settings > Security.
''';
}
