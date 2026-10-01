import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ciphernest/services/encryption_service.dart';

/// Pins the condition the Drive canary got wrong: fewer than headerSize bytes
/// must NOT be treated as a wrong-key verdict.
void main() {
  test('header parser rejects a short probe, and headerSize is 81', () async {
    expect(EncryptionService.headerSize, 81);
    // A first network chunk smaller than the header: what stream.first could
    // legitimately hand back, and what used to be reported to the user as
    // "That phrase doesn't match this vault."
    for (final n in [0, 1, 40, 80]) {
      await expectLater(
        EncryptionService.verifyKey(Uint8List(n)),
        throwsA(isA<Exception>()),
        reason: '$n bytes must throw, not read as a key verdict',
      );
    }
  });
}
