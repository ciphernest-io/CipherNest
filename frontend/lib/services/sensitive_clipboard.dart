import 'package:flutter/services.dart';

/// Clipboard writes for secrets: the recovery phrase and share links.
///
/// Flutter's [Clipboard] cannot mark a clip sensitive, so this goes through
/// a platform channel that sets `ClipDescription.EXTRA_IS_SENSITIVE` (Android
/// 13+, which hides the text from the clipboard preview overlay and from
/// clipboard history on OEMs that honour it). The clip is NOT cleared on a
/// timer: the user copied it to paste it somewhere, and wiping it behind
/// their back costs a phrase that was about to go into a password manager.
/// Android 13+ already expires clipboard contents after an hour (MASVS F-10).
class SensitiveClipboard {
  SensitiveClipboard._();

  static const MethodChannel _channel = MethodChannel('ciphernest/clipboard');

  static Future<void> copy(String text) async {
    try {
      await _channel.invokeMethod<void>('copySensitive', <String, Object>{
        'text': text,
      });
    } on MissingPluginException {
      // Tests and non-Android hosts: an ordinary copy is better than none.
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }
}
