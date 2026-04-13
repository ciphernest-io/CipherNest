# Context Setup for AI Assistant: CipherNest

I am building a zero-knowledge, client-side encrypted cloud storage app for Android called CipherNest. My primary goal is to publish it on the Play Store, monetize it, and use it as a flagship portfolio piece for Master's applications in Cybersecurity (targeting the US, Germany, France, and Italy) and as an enterprise-grade showcase for my startup.

Please review the following project context, technical stack, current progress, and roadmap before executing any commands or writing code.

## 1. Project Overview: What is CipherNest?
CipherNest is a "Privacy Vault" or "Cryptomator for Memories." It provides a zero-knowledge encryption layer for Google Drive (and eventually other cloud providers). Users can upload photos, videos, and documents. Everything is encrypted locally on the device before it ever touches the cloud. The server/cloud provider never sees the raw files or the encryption keys.

## 2. Strategic & Academic Context
* **Academic Project:** This is part of my Directed Course Work (DCW) with my instructor, Sir Waqar Ahmad, at LUMS.
* **The "Basit Benchmark":** I am solving a usability challenge posed by my Network Security instructor, Sir Basit Shafiq (that privacy is useless if sharing is too difficult). Future features, like Zero-Knowledge Sharing, are designed specifically to prove the app's real-world viability without compromising cryptography.

## 3. Technical Architecture & Stack
* **Frontend:** Flutter (Dart).
* **Backend/Storage:** Local SQLite database for metadata, Google Drive API for cloud storage.
* **Encryption:** Client-side AES-GCM-256. All files are encrypted before upload and decrypted after download.
* **UI/UX Paradigm:** The app strictly follows a "Samsung Gallery" design language—dark theme, tight edge-to-edge photo grids, horizontal filmstrips, and intuitive swipe gestures.
* **Local Cache Management:** We use the device's temporary directory to store decrypted thumbnails and full images for fast loading, managed by a custom Garbage Collector.

## 4. Current State: What Has Been Implemented
Do not attempt to rebuild these core systems; they are already functional:
* **Secure File Transfer:** Photos and videos are successfully encrypted, uploaded, downloaded, and decrypted via streams.
* **Gallery View (gallery_screen.dart):** Tight 3-column grid (1.5px spacing, no padding), auto-thumbnail generation, bottom navigation bar, pull-to-sync, and gallery date sorting. 
* **Image Viewer (image_viewer_screen.dart):** Progressive loading (thumbnail to full image cross-fade). Samsung-style gesture controls: Swipe down to close into gallery, swipe up to open Details panel.
* **Filmstrip:** Horizontal, draggable photo slider at the bottom that auto-syncs with the currently viewed photo.
* **Cache Manager Service:** Background garbage collector with a user-defined cache limit. 
* **Aggressive Deletion:** Deleting a file wipes it from Drive, SQLite, and the local cache entirely.

## 5. Immediate Roadmap: Active Development (Phase 2)
These are the highest priority items currently being worked on:
* **Chunked Video Streaming Proxy:** Building a local HTTP web server (`shelf` package) to fetch, decrypt, and stream video chunks on-the-fly to the video player (avoiding full downloads before playback).
* **Folders & Albums Organization:** Allowing users to group encrypted files.
* **Database Cloud Backup:** Uploading an encrypted snapshot of the SQLite `.db` file to Google Drive to allow multi-device sync and account recovery ("Last Write Wins" safety check).
* **In-App Image Editor:** Must be entirely in-app (e.g., `pro_image_editor`) to prevent decrypted files from leaking to public storage via external apps.
* **Zero-Knowledge Sharing (The "Magic Link"):** Hash-Fragment Key sharing system (`ciphernest://share?id=123#key=abc`).
* **Migration Script** An intuitve, UI/UX-powered method of migration of unencrypted old photos in Google Photos and files in Drive to CipherNest infrastructure to support easy onboarding. 


## 6. Feature Backlog (To-Do / Planned Refinements)
* **Performance/UX:** Background loading ahead and back (pre-fetching in viewer), fixing any gaps in swiping, squeeze gallery view to resize grid.
* **Media Management:** Rename photos/files, multi-selection ("Hold to Select"), auto-sync with Android gallery, save a decrypted copy to local public storage.
* **Viewer Actions:** Fleshing out skeleton buttons (Copy to clipboard, Set as wallpaper, Print).
* **App Structure:** Portrait and Landscape mode responsiveness, Recycle Bin (soft delete), "A year ago" memory surface (Stories tab).
* **Polish:** Aesthetic animations for deletion and state changes.

## 7. Coding Style & AI Rules
* Always use early returns to avoid deep nesting.
* Prefer immutable state where possible.
* Do not use third-party packages for UI components unless explicitly asked; stick to custom Flutter widgets to maintain the exact Samsung Gallery feel.
* Ensure all file generation and terminal commands are executed with the mindset of a strict zero-knowledge architecture (e.g., never accidentally log decryption keys or write decrypted files to persistent public storage).