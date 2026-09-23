# CipherNest

Zero-knowledge cloud storage for Android. Files are encrypted on your device before they are uploaded, so no server, including ours, can read them.

[Website](https://ciphernest.io) · [Security policy](https://ciphernest.io/security) · [Security self-assessment](docs/MASVS_REPORT.md)

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

The full assessment, including every open finding, is in [`docs/MASVS_REPORT.md`](docs/MASVS_REPORT.md). It is published unedited, including the findings that are not yet fixed.

## Status

Pre-release, preparing for a closed track on Google Play. Current version: **1.0.0**.

## Verifying a release

Each entry on the [Releases](../../releases) page publishes a SHA-256 checksum beside its APK. After downloading, compute the checksum locally and compare it to the published value before installing:

```
sha256sum ciphernest-<version>.apk
```

On Windows: `Get-FileHash ciphernest-<version>.apk -Algorithm SHA256`

If the values do not match, do not install the file, and report it to security@ciphernest.io.

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
| Minimum supported Android | 7.0, API 24 |
| Target SDK | 36 |

Builds are signed with the upload key only when `frontend/android/key.properties` is present. Without it, Gradle falls back to the debug signing key, so a build you produce yourself will not carry the release signature and is not interchangeable with a published artifact.

## Security

Found a vulnerability? Please do not open a public issue. Email **security@ciphernest.io** or use the Report a vulnerability button on the Security tab. Full policy, including scope, response times, and safe harbour: https://ciphernest.io/security

## Contributing

Issues and pull requests are welcome. Contributions are accepted under GPL-3.0-or-later. Please read the security policy before reporting anything that touches cryptography or key handling, and open an issue before starting work on anything that changes a file format, a key derivation, or a stored blob layout: those are frozen once a real vault exists, and changing one orphans user data.

## Licence

GPL-3.0-or-later; the CipherNest name and mark are not covered.
