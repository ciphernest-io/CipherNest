// Typed, user-facing error taxonomy.
//
// Every catchable pre-home-screen failure should be mapped into one of these
// at the throwing site (or in a `on <PlatformException>` wrapper close to
// it). Callers then either:
//   - `on NoActiveCloudError catch (_) { ... route to reconnect ... }`
//   - `catch (e) { showCnestError(context, e is CnestError ? e : UnexpectedError(...)); }`
//
// Raw `Exception.toString()` never reaches the UI.

sealed class CnestError implements Exception {
  const CnestError();

  /// Short headline for the error sheet.
  String get title;

  /// One or two sentences the user reads.
  String get message;

  /// Label of the primary button in the sheet. `null` means the sheet
  /// renders only a single "Dismiss" action.
  String? get primaryActionLabel;

  /// ThemeIcon name (Phosphor camelCase or Material snake_case) rendered
  /// at the top of the sheet.
  String get iconName;

  /// If false, the sheet no-ops silently. Used for user-initiated cancels
  /// (OAuth account-picker dismiss) that should never surface an error UI.
  bool get shouldSurface => true;
}

// ---------------------------------------------------------------------------
// Concrete cases
// ---------------------------------------------------------------------------

final class OfflineError extends CnestError {
  const OfflineError();
  @override String get title => "You're offline.";
  @override String get message =>
      "Check your Wi-Fi or mobile data, then try again.";
  @override String? get primaryActionLabel => 'Try again';
  @override String get iconName => 'wifiHigh';
}

/// User-initiated OAuth cancellation. Never renders — thrown so callers can
/// distinguish "user backed out" from "everything blew up".
final class AuthCancelledError extends CnestError {
  const AuthCancelledError();
  @override String get title => '';
  @override String get message => '';
  @override String? get primaryActionLabel => null;
  @override String get iconName => 'x';
  @override bool get shouldSurface => false;
}

final class AuthDeniedError extends CnestError {
  const AuthDeniedError({this.provider = 'Your provider'});
  final String provider;
  @override String get title => "$provider couldn't sign you in.";
  @override String get message =>
      "The provider rejected the sign-in. Try again, or check that your account is active.";
  @override String? get primaryActionLabel => 'Try again';
  @override String get iconName => 'shieldWarning';
}

/// Access token expired or invalidated. Callers should attempt a silent
/// refresh first; only surface this if that fails.
final class TokenExpiredError extends CnestError {
  const TokenExpiredError();
  @override String get title => 'Your session expired.';
  @override String get message =>
      "Sign back in to your cloud so we can pick up where you left off.";
  @override String? get primaryActionLabel => 'Reconnect';
  @override String get iconName => 'signIn';
}

/// The vault has no connected cloud right now. Callers typically route to
/// the reconnect screen instead of rendering a sheet.
final class NoActiveCloudError extends CnestError {
  const NoActiveCloudError();
  @override String get title => 'Your vault is missing its cloud.';
  @override String get message =>
      "You're in, but your cloud isn't. Reconnect it so we can sync your files.";
  @override String? get primaryActionLabel => 'Reconnect';
  @override String get iconName => 'cloudSlash';
}

enum WrongPhraseReason { wordlistOrChecksum, canary }

final class WrongPhraseForVaultError extends CnestError {
  const WrongPhraseForVaultError(this.reason);
  const WrongPhraseForVaultError.wordlistOrChecksum()
      : this(WrongPhraseReason.wordlistOrChecksum);
  const WrongPhraseForVaultError.canary() : this(WrongPhraseReason.canary);

  final WrongPhraseReason reason;

  @override
  String get title => switch (reason) {
        WrongPhraseReason.wordlistOrChecksum => 'Recovery phrase invalid.',
        WrongPhraseReason.canary => "That phrase doesn't match this vault.",
      };

  @override
  String get message => switch (reason) {
        WrongPhraseReason.wordlistOrChecksum =>
          "Either a word isn't in our wordlist or the checksum doesn't match. Check every word carefully.",
        WrongPhraseReason.canary =>
          "Either the phrase is wrong, or this is a different cloud account than the one you signed up with. Double-check your phrase word by word. If you're sure it's right, try a different cloud account.",
      };

  @override String? get primaryActionLabel => 'Try phrase again';
  @override String get iconName => 'lockKey';
}

/// The connected cloud account already has CipherNest files. Thrown from
/// the existing-vault probe during signup so the caller can show the
/// "Restore instead / Start over" dialog described in the plan.
final class ExistingVaultDetectedError extends CnestError {
  const ExistingVaultDetectedError();
  @override String get title => 'This account already has a CipherNest vault.';
  @override String get message =>
      "Good news: your files are safe. To read them, tap Restore and enter the recovery phrase from when you first signed up.";
  @override String? get primaryActionLabel => 'Restore instead';
  @override String get iconName => 'vault';
}

/// The restore flow connected to a cloud account with no `.cnest` files.
final class EmptyVaultForRestoreError extends CnestError {
  const EmptyVaultForRestoreError();
  @override String get title => 'This account has no CipherNest files.';
  @override String get message =>
      "If you signed up on a different Google or Microsoft account, sign out and try that one.";
  @override String? get primaryActionLabel => 'Try a different account';
  @override String get iconName => 'warningCircle';
}

final class CorruptedVaultError extends CnestError {
  const CorruptedVaultError();
  @override String get title => "Some files can't be decrypted.";
  @override String get message =>
      "This usually means the file was modified outside of CipherNest, or the encryption header is damaged. Your other files are safe.";
  @override String? get primaryActionLabel => 'Show details';
  @override String get iconName => 'shieldWarning';
}

final class RateLimitError extends CnestError {
  const RateLimitError();
  @override String get title => 'Cloud provider is asking us to slow down.';
  @override String get message =>
      "Wait a minute or two and try again. Nothing is broken.";
  @override String? get primaryActionLabel => 'Try again';
  @override String get iconName => 'clock';
}

/// The user's cloud storage account is full. Reported by Drive with
/// `storageQuotaExceeded` and by OneDrive with `quotaLimitReached`. Not our
/// bug and not fixable in-app; user has to free space or upgrade.
final class StorageFullError extends CnestError {
  const StorageFullError({this.provider = 'Your cloud'});
  final String provider;
  @override String get title => '$provider is full.';
  @override String get message =>
      "You've hit your cloud storage quota. Free up some space, or upgrade your Google One or Microsoft 365 plan, then try again. CipherNest can't fix this for you — the limit is on your cloud account.";
  @override String? get primaryActionLabel => 'Try again';
  @override String get iconName => 'cloudSlash';
}

/// A transfer that was underway died mid-stream (wifi dropped, socket
/// reset). Distinct from [OfflineError]: the connection existed and then
/// went away, so the copy reassures that nothing partial was saved.
final class UploadInterruptedError extends CnestError {
  const UploadInterruptedError();
  @override String get title => 'Upload interrupted.';
  @override String get message =>
      "The connection dropped mid-transfer. Nothing was saved — try again "
      "once you're on a stable connection.";
  @override String? get primaryActionLabel => 'Try again';
  @override String get iconName => 'wifiSlash';
}

/// Maps a raw exception to a network-class [CnestError], or null when the
/// error isn't network-shaped. Classification is by ERROR SHAPE, never by
/// probing live connectivity — a wifi-drop socket error often surfaces only
/// after the user reconnects, so a point-in-time connectivity check lies.
CnestError? classifyNetworkError(Object e) {
  final msg = e.toString().toLowerCase();
  // Never-connected class: DNS resolution failed outright.
  if (msg.contains('failed host lookup') ||
      msg.contains('no address associated') ||
      msg.contains('network is unreachable')) {
    return const OfflineError();
  }
  // Died-mid-transfer class: the socket existed and then broke.
  const interrupted = [
    'socketexception',
    'clientexception',
    'connection closed',
    'connection reset',
    'connection abort',
    'software caused connection',
    'broken pipe',
    'timed out',
    'timeoutexception',
    'handshake',
  ];
  for (final needle in interrupted) {
    if (msg.contains(needle)) return const UploadInterruptedError();
  }
  return null;
}

/// Fallback. Carries a short code (surfaced to the user, used in bug
/// reports) and an optional debug detail (log-only, never shown).
final class UnexpectedError extends CnestError {
  const UnexpectedError({this.code, this.debugDetail});
  final String? code;
  final String? debugDetail;

  @override
  String get title => 'Something went sideways.';

  @override
  String get message {
    final suffix = code != null ? "\n\nCode: $code" : '';
    return "This wasn't supposed to happen. Try the action again; if it keeps failing, get in touch and quote the code below.$suffix";
  }

  @override String? get primaryActionLabel => 'Try again';
  @override String get iconName => 'warningCircle';
}
