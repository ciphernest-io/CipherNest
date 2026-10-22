# Changelog

All notable changes to CipherNest are recorded here. Versions follow the Play Store release; the number in brackets is the Android `versionCode`.

## Unreleased

- The Free limit now applies to edited copies, captured video frames and playlist covers. Each is a new vault file and took a slot past the cap; Replace original is unaffected. The save sheet says when a copy will not fit.
- The image editor uses dark chrome in every theme. In a light theme the tick, back and tool icons sat on the package's black bars and disappeared.
- The About label no longer says Beta. Release builds silence debug logging.

## 1.0.0 (10), October 2026

First public release.

- Client-side encryption of photos, videos and documents into the user's own Google Drive or OneDrive. AES-256-GCM in 512 KiB chunks, per-file keys sealed with HPKE (RFC 9180).
- Twelve-word BIP-39 recovery phrase as the root of trust, with an optional local password (Argon2id) and optional biometric unlock. A vault can also be created with no password.
- Gallery with folders and albums, image viewer, in-app video playback over a loopback streaming server, in-app image editor.
- Encrypted metadata index synced across devices through the cloud account.
- Zero-knowledge share links: the file key stays in the URL fragment and decryption happens in the recipient's browser.
- Free tier up to 1,000 files. CipherNest Plus (monthly, yearly or lifetime) lifts the upload cap and nothing else. Files in the Recycle Bin count until the bin is emptied. Home shows the count against the limit, warns from 90%, and the upload buttons open the Plus sheet at the cap. A batch uploads what fits and reports the rest; album backup stops at the cap and resumes after an upgrade instead of skipping photos.
- Uploads retry rate limits and transient cloud errors with backoff, hold the foreground service during album backup, and clean up any blob left by a failed attempt. Files never appear at the vault root because of a stale listing or an interrupted upload.
- Gallery: swipe between Pictures, Albums, Stories and Menu; the tabs slide either way. Albums shrink straight from tile to square when pinched down to the list. Album pages use the gallery grid, pinch and all, without date headers. Opening a photo from anywhere (Pictures, albums, stories, folders, search, Recycle Bin) flies the thumbnail into place with no overshoot, and the full-resolution image fades in only after the flight. Every multi-photo view has the filmstrip. Pages slide in over a screen that stays put.
- Settings reorganised: Music has its own section (reachable from the Music tab), Security starts with the password, Plus and the activity log live under Account, Clear cache sits inside the cache card, the theme picker is a carousel with the chosen theme centred, and the Gallery section has one Featured switch with a toggle per story kind. Vaults without a password can view their recovery phrase. The About page links to GitLab.
- Folders and Documents three-dot menus all carry icons; the large document card no longer repeats Send and Save in its menu. Playlists shrink straight to the square when pinched to the list. The media notification follows the track-title setting immediately. The music bar shows only the active vault's music, and the activity log no longer carries another account's results.
- Requires Android 9 or later. Older releases have had no security patches since 2021 and lack the Keystore protections the app relies on.
- A vault created without a password opens straight from the splash, hides the lock settings that do not apply to it, and can add a password later from Settings.
- Recovery phrase and share-key screens are excluded from screenshots and the recents snapshot. Other screens are not.
- Hardening from the OWASP MASVS v2.1.0 self-assessment, published in `docs/MASVS_REPORT.md`: Keystore-backed encrypted preferences for the secure store, clipboard copies of the phrase and share links flagged sensitive so Android 13+ hides them from the clipboard preview, lockout after repeated wrong passwords, connection timeouts on every network call, release builds that refuse to sign with the debug key, per-account data removal on disconnect, hashed deletion tracker, and a share viewer that scrubs the key from the address bar.
