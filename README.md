# CipherNest

Zero-knowledge cloud storage for Android. Files are encrypted on your device before they are uploaded, so no server, including ours, can read them.

[Website](https://ciphernest.io) · [Threat model](THREAT_MODEL.md) · [Security policy](SECURITY.md) · [Security self-assessment](docs/MASVS_REPORT.md) · [Changelog](CHANGELOG.md)

## Why

Cloud storage is convenient because the provider can read your files: that is what powers search, categorisation, and the AI features layered on top. Privacy-focused alternatives exist, but they usually ask you to give up either convenience or the ecosystem you already use. CipherNest is built on the opposite premise: encryption happens on the device, the server stores ciphertext it cannot interpret, and the experience stays close to an ordinary gallery and file app.

Your files live in your own Google Drive or OneDrive. CipherNest operates no file server.

## How it works

- **Client-side encryption.** Every file is encrypted on the device before it leaves it. Keys are derived on-device from a BIP-39 recovery phrase and never sent anywhere.
- **Chunked authenticated encryption.** File bodies are AES-256-GCM in 512 KiB chunks. Each chunk uses a counter nonce and additional authenticated data binding it to the file's content id, its index, and the total chunk count, so reordering, truncation, duplication, and splicing between files all fail authentication rather than decrypting to something plausible.
- **Per-file keys sealed with HPKE.** Each file gets a fresh AES-256 key, sealed to the vault's long-term X25519 public key using HPKE (RFC 9180) with the ciphersuite DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, AES-128-GCM, checked against the RFC's own Appendix A.1 test vectors. Sealing needs only the public key, which is what lets background upload encrypt while the vault is locked.
- **Password KDF.** Where a password is used, it is stretched with Argon2id at 64 MiB, two passes, 32-byte output, with a fresh random salt.
- **Zero-knowledge by construction.** A compromise of the storage backend yields ciphertext and nothing else.

## What this does not protect against

Stated plainly, because a vault that oversells itself is worse than one that does not.

- **A compromised device.** If an attacker has root on your unlocked phone, or a forensic extraction of it while it is powered on and has been unlocked since boot, the local metadata database is currently readable. Filenames, folder names and timestamps are exposed in that scenario. File contents remain encrypted.
- **Share links are bearer tokens.** Anyone holding a share link can decrypt that file. Expiry is enforced by the viewer and the relay, but a recipient who downloaded within the window keeps their copy.
- **A forgotten recovery phrase.** There is no password reset. That is the cost of the server holding no keys.
- **Traffic analysis.** File sizes and upload timing are visible to the storage provider.

The full threat model is in [THREAT_MODEL.md](THREAT_MODEL.md). The OWASP MASVS self-assessment, including every open finding and its disposition, is in [`docs/MASVS_REPORT.md`](docs/MASVS_REPORT.md).

## Status

Current version: **1.0.0**, on [Google Play](https://play.google.com/store/apps/details?id=io.ciphernest.vault). Release history is in [CHANGELOG.md](CHANGELOG.md).

## Verifying a release

Every entry on the [Releases](../../releases) page lists the SHA-256 of its APK. Two checks, for two different questions.

**Is the file I downloaded the one that was published?** Compute the checksum and compare it with the one on the release:

```
sha256sum ciphernest-<version>.apk
```

On Windows: `Get-FileHash ciphernest-<version>.apk -Algorithm SHA256`

**Was it signed by us, rather than copied intact from somewhere else?** A checksum next to the file it checks only proves the download was not corrupted. The signing certificate proves who built it, and it does not change between releases. Print it with `apksigner` from the Android SDK build tools:

```
apksigner verify --print-certs ciphernest-<version>.apk
```

Compare the `Signer #1 certificate SHA-256 digest` with the fingerprint published at https://ciphernest.io/security. It is published there, on a different host from the download, so that replacing the APK on GitHub is not enough to pass the check.

That fingerprint belongs to the key we sign GitHub releases with. Builds installed from Google Play are re-signed by Play App Signing and carry a different certificate; verify those through Play itself.

If either check fails, do not install the file, and report it to security@ciphernest.io.

## Building from source

CipherNest is a Flutter application. The Android project lives under `frontend/`.

```
git clone https://github.com/ciphernest-io/CipherNest.git
cd CipherNest/frontend
flutter pub get
flutter build apk --release --no-tree-shake-icons
```

`--no-tree-shake-icons` is required: one of the icon packages uses non-constant `IconData`, which makes tree shaking fail.

For the Play Store bundle, substitute `flutter build appbundle --release --no-tree-shake-icons`.

Requirements:

| | |
|---|---|
| Flutter | 3.38.5 stable (Dart SDK ^3.10.4) |
| JDK | 17 |
| Android compile SDK | 36 |
| Minimum supported Android | 9.0, API 28 |
| Target SDK | 36 |

A release build requires `frontend/android/key.properties` pointing at a signing keystore and fails without one; it never falls back to the debug key. To build for yourself, create your own keystore and properties file, or build a debug variant. A build signed with your key is not interchangeable with a published artifact.

## Security

Found a vulnerability? Please do not open a public issue. Email **security@ciphernest.io** or use the Report a vulnerability button on the Security tab. Scope, response times and safe harbour are in [SECURITY.md](SECURITY.md). What the app does and does not protect against is in [THREAT_MODEL.md](THREAT_MODEL.md).

## Contributing

Issues and pull requests are welcome. Contributions are accepted under GPL-3.0-or-later with a DCO sign-off; see [CONTRIBUTING.md](CONTRIBUTING.md). Open an issue before starting work on anything that changes a file format, a key derivation, or a stored blob layout: those are frozen once a real vault exists, and changing one orphans user data.

## Licence

[GPL-3.0-or-later](LICENSE). The CipherNest name and logo are not covered by the licence. Licences of the packages the app is built on are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
