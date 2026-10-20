# Changelog

All notable changes to CipherNest are recorded here. Versions follow the Play Store release; the number in brackets is the Android `versionCode`.

## 1.0.0 (9), October 2026

First public release.

- Client-side encryption of photos, videos and documents into the user's own Google Drive or OneDrive. AES-256-GCM in 512 KiB chunks, per-file keys sealed with HPKE (RFC 9180).
- Twelve-word BIP-39 recovery phrase as the root of trust, with an optional local password (Argon2id) and optional biometric unlock. A vault can also be created with no password.
- Gallery with folders and albums, image viewer, in-app video playback over a loopback streaming server, in-app image editor.
- Encrypted metadata index synced across devices through the cloud account.
- Zero-knowledge share links: the file key stays in the URL fragment and decryption happens in the recipient's browser.
- Free tier up to 1,000 files. CipherNest Plus (monthly, yearly or lifetime) lifts the upload cap and nothing else. Files in the Recycle Bin count until the bin is emptied. Home shows the count against the limit, warns from 90%, and the upload buttons open the Plus sheet at the cap. A batch uploads what fits and reports the rest; album backup stops at the cap and resumes after an upgrade instead of skipping photos.
- Uploads retry rate limits and transient cloud errors with backoff, hold the foreground service during album backup, and clean up any blob left by a failed attempt. Files never appear at the vault root because of a stale listing or an interrupted upload.
- Requires Android 9 or later. Older releases have had no security patches since 2021 and lack the Keystore protections the app relies on.
- A vault created without a password opens straight from the splash, hides the lock settings that do not apply to it, and can add a password later from Settings.
- Recovery phrase and share-key screens are excluded from screenshots and the recents snapshot. Other screens are not.
- Hardening from the OWASP MASVS v2.1.0 self-assessment, published in `docs/MASVS_REPORT.md`: Keystore-backed encrypted preferences for the secure store, clipboard copies of the phrase and share links flagged sensitive so Android 13+ hides them from the clipboard preview, lockout after repeated wrong passwords, connection timeouts on every network call, release builds that refuse to sign with the debug key, per-account data removal on disconnect, hashed deletion tracker, and a share viewer that scrubs the key from the address bar.
