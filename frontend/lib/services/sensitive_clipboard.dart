import 'package:flutter/services.dart';

/// Clipboard writes for secrets: the recovery phrase and share links.
///
/// Flutter's [Clipboard] cannot mark a clip sensitive, so this goes through
/// a platform channel that sets `ClipDescription.EXTRA_IS_SENSITIVE` (Android
/// 13+, which hides the text from the clipboard preview overlay and from
/// clipboard history on OEMs that honour it) and clears the clip again after
/// [defaultClearAfter] (MASVS F-10).
class SensitiveClipboard {
  SensitiveClipboard._();

  static const MethodChannel _channel = MethodChannel('ciphernest/clipboard');

  /// How long a secret stays on the clipboard before it is wiped.
  static const Duration defaultClearAfter = Duration(seconds: 60);

  static Future<void> copy(
    String text, {
    Duration clearAfter = defaultClearAfter,
  }) async {
    try {
      await _channel.invokeMethod<void>('copySensitive', <String, Object>{
        'text': text,
        'clearAfterMs': clearAfter.inMilliseconds,
      });
    } on MissingPluginException {
      // Tests and non-Android hosts: an ordinary copy is better than none.
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }
}
