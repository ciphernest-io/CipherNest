import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:ciphernest/services/key_manager_service.dart';

/// Frozen-mnemonic derivation guard.
///
/// The HKDF info strings ("ciphernest/x25519/v1", "ciphernest/local/v1") are
/// load-bearing forever: once a real vault exists, any drift here permanently
/// orphans it. This pins a fixed mnemonic to its exact derived vault public
/// key and k_local. If the derivation changes for ANY reason, this fails.
///
/// Mnemonic: the standard all-zero-entropy BIP-39 test vector.
void main() {
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon '
      'abandon abandon abandon about';

  // Frozen expected outputs (computed from the current, correct derivation).
  const expectedPublicKey =
      '46512b8c656ead502b4ed0697e01af18542fbfde0667feba5a2232c08b5a9072';
  const expectedKLocal =
      'ff202c7903560d109161ce64bda5920521957492ac3be147f164ea8db762e382';

  test('fixed mnemonic derives fixed vault public key and k_local', () async {
    final seed = bip39.mnemonicToSeed(mnemonic);
    final keys = await KeyManagerService.deriveVaultKeysForTest(seed);

    expect(_hex(keys.publicKey), expectedPublicKey, reason: 'vault public key');
    expect(_hex(keys.kLocal), expectedKLocal, reason: 'k_local');
  });

  test('derivation is deterministic', () async {
    final seed = bip39.mnemonicToSeed(mnemonic);
    final a = await KeyManagerService.deriveVaultKeysForTest(seed);
    final b = await KeyManagerService.deriveVaultKeysForTest(seed);
    expect(_hex(a.publicKey), _hex(b.publicKey));
    expect(_hex(a.kLocal), _hex(b.kLocal));
  });
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
