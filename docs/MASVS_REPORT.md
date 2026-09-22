# CipherNest: OWASP MASVS v2.1.0 Self-Assessment

## 1. Scope

| Item | Value |
|---|---|
| Application | CipherNest, Android |
| Package | `io.ciphernest.vault` |
| Version assessed | 1.0.0 (versionCode 1) |
| Commit | `c43cd1a2ca4cf460fb523ec1affaaf31e35931b3` |
| Artefact | `build/app/outputs/flutter-apk/app-release.apk`, built 2026-09-20, signed SHA-256 `C5:EE:12:FD:44:40:26:E4:71:42:E3:B9:F0:14:F5:17:C3:13:DA:D8:A0:31:1A:7F:2A:65:A4:31:17:1C:8C:D0` |
| Toolchain | Flutter 3.38.5 stable, AGP 8.11.1, Kotlin 2.2.20, minSdk 24, targetSdk 36, compileSdk 36 |
| Standard | OWASP MASVS v2.1.0, released 2025-01-18 |
| Test procedures | OWASP MASTG test IDs, cited per finding where one applies |
| Target profile | MAS-L2 |
| Assessment date | 2026-09-20, static and device passes on the same day |
| Test device | Samsung SM-A556E, Android 16, API 36, `user` build, not rooted |
| Assessor | Usman Shafi, developer. This is a self-assessment. |

The artefact under test was the installed one, not a rebuild. The APK on the device hashed identically to the file assessed:

```
on-device sha1 : 832e059dd46662a3425d5aa1d0efe37e3dc89a20
local sha1     : 832e059dd46662a3425d5aa1d0efe37e3dc89a20
```

### Target profile note

MASVS v2.0.0 removed verification levels from the standard itself. The MASVS text states: "The MAS project has traditionally provided three verification levels (L1, L2 and R), which were revisited during the MASVS refactoring in 2023, and have been reworked as 'MAS Testing Profiles' and moved over to the OWASP MASTG." Levels now attach to individual MASTG tests, not to MASVS controls.

This assessment targets MAS-L2 and evaluates all eight MASVS control groups, including MASVS-PRIVACY, which v2.1.0 added. MASVS-RESILIENCE belongs to the MAS-R profile and is not required for L2. It is assessed and reported anyway, marked as out of L2 scope, because omitting it would leave a gap a reader would notice.

### Threat model assumed

CipherNest is a client-side encrypted vault. Files are encrypted on the device and stored in the user's own Google Drive or OneDrive. The developer operates no file server. The controls below are evaluated against four adversaries:

1. The cloud provider, or anyone with read access to the user's Drive or OneDrive account.
2. Another application installed on the same device, without root.
3. Someone with physical access to an unlocked device.
4. Someone with physical access to a locked device, plus the ability to extract application data, which means root, an unlocked bootloader, or a forensic image.

An adversary who fully controls a running device while the vault is unlocked is out of scope, as are attacks on the user's cloud account credentials.

## 2. Methodology

### Static

Source review of the Flutter application (`frontend/lib`, 118 Dart service and screen files), the Android host (`frontend/android`, three hand-written Kotlin files, Gradle configuration, ProGuard rules, network security configuration), the Cloudflare Worker (`worker.js`), and the web share viewer (`web-viewer/`). Evidence is cited as `path:line`.

Binary review of the shipped release APK, which is the authoritative record of what the build actually produces:

- Manifest flags and merged components extracted with `aapt2 dump xmltree` and `aapt2 dump permissions`.
- Signature scheme and certificate extracted with `apksigner verify --print-certs`.
- Obfuscation state determined by searching `classes.dex` for original Kotlin class names and `lib/arm64-v8a/libapp.so` for Dart symbol names, then cross-checked against the R8 mapping file at `build/app/outputs/mapping/release/`. The cross-check mattered: the Gradle configuration suggested one answer and the build artefacts proved another. See F-17.

The release merged manifest at `build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml` was used for component enumeration, cross-read against the source manifest. Plugin-merged resources such as `filepaths.xml` were read from the build intermediates, not inferred from plugin documentation.

Live checks against the deployed web infrastructure: response headers on `share.ciphernest.io`, the `/proxy` endpoint's behaviour with and without an `Origin` header, the `auth.ciphernest.io` path restriction, and the four `.well-known` files.

### Device-verified

A dynamic pass was run on the device named above against the installed shipped build. Of the eighteen planned tests, eight produced a complete result, three produced a partial one, and seven were not run. Section 7 records every one of them, including the reason for each test that produced nothing.

Throughout this report, findings and controls carry one of two markers:

- **Device-verified.** Observed on the running app. The evidence is a command output, a captured frame, or a file pulled from the device.
- **Static only.** Derived from source, configuration or the binary. Not observed at runtime.

Most of the dynamic work was driven over adb rather than by hand, which matters for reproducibility. Screen protection was tested with `screencap`, because a window carrying `FLAG_SECURE` captures as a blank frame, so a legible capture is a negative result that cannot be argued with. The task switcher was driven with `input keyevent KEYCODE_APP_SWITCH`. The loopback server was probed with the device's own `toybox nc` running as uid 2000, which is a genuinely different uid from the app's 10434, so a successful fetch proves cross-application access rather than merely proving the socket exists.

### Reading app-private storage: the instrumented variant

Three tests needed the app-private data directory, which a `user` build does not expose. `run-as` refused, as it should:

```
$ adb shell run-as io.ciphernest.vault ls
run-as: package not debuggable: io.ciphernest.vault
```

Rather than skip them, a release build with `isDebuggable = true` was produced and installed as an in-place update. It carries the same upload signing key, so the update preserved the existing vault, cache and database instead of wiping them.

The protocol was chosen so the instrumented build could not contaminate the evidence. Every artefact was generated first, by the shipped build, during normal use. The variant was then installed and **never launched**. It was used only to read files that the shipped build had already written. The app was confirmed not running at the moment of each read.

One fidelity caveat is recorded because it is real. Setting the debuggable flag makes the Flutter toolchain emit JIT Dart rather than an AOT snapshot, and it skips R8 obfuscation. The built APK contains `kernel_blob.bin` and no `libapp.so`. This does not affect what was measured, because the variant only read files, and because the Dart source contains no build-mode branches at all: `kDebugMode`, `kReleaseMode` and `kProfileMode` appear zero times in `frontend/lib`.

Afterwards the original APK was reinstalled and the state verified: the on-device hash returned to `832e059d`, `run-as` was refused again, and the Gradle edit was reverted.

### Prior work referenced

`docs/self_audit_ledger.md` entries SA-WEB-01 through SA-WEB-05, re-verified in section 6. `docs/MTR1_FINDINGS.md` and `docs/MTR2_PROTOCOL.md` cover functional test runs and are not security findings.

## 3. Results

| Control | Statement | Verdict | Evidence |
|---|---|---|---|
| MASVS-STORAGE-1 | The app securely stores sensitive data. | FAIL | Device-verified |
| MASVS-STORAGE-2 | The app prevents leakage of sensitive data. | FAIL | Device-verified |
| MASVS-CRYPTO-1 | The app employs current strong cryptography and uses it according to industry best practices. | PASS | Static only |
| MASVS-CRYPTO-2 | The app performs key management according to industry best practices. | FAIL | Device-verified |
| MASVS-AUTH-1 | The app uses secure authentication and authorization protocols and follows the relevant best practices. | PASS | Static only |
| MASVS-AUTH-2 | The app performs local authentication securely according to the platform best practices. | FAIL | Device-verified |
| MASVS-AUTH-3 | The app secures sensitive operations with additional authentication. | FAIL | Static only |
| MASVS-NETWORK-1 | The app secures all network traffic according to the current best practices. | PASS | Static only |
| MASVS-NETWORK-2 | The app performs identity pinning for all remote endpoints under the developer's control. | N/A | Static only |
| MASVS-PLATFORM-1 | The app uses IPC mechanisms securely. | FAIL | Device-verified |
| MASVS-PLATFORM-2 | The app uses WebViews securely. | N/A | Static only |
| MASVS-PLATFORM-3 | The app uses the user interface securely. | FAIL | Device-verified |
| MASVS-CODE-1 | The app requires an up-to-date platform version. | FAIL | Static only |
| MASVS-CODE-2 | The app has a mechanism for enforcing app updates. | FAIL | Static only |
| MASVS-CODE-3 | The app only uses software components without known vulnerabilities. | FAIL | Static only |
| MASVS-CODE-4 | The app validates and sanitizes all untrusted inputs. | FAIL | Device-verified |
| MASVS-RESILIENCE-1 | The app validates the integrity of the platform. | FAIL, out of L2 scope | Static only |
| MASVS-RESILIENCE-2 | The app implements anti-tampering mechanisms. | FAIL, out of L2 scope | Partly device-verified |
| MASVS-RESILIENCE-3 | The app implements anti-static analysis mechanisms. | FAIL, out of L2 scope | Static only |
| MASVS-RESILIENCE-4 | The app implements anti-dynamic analysis techniques. | FAIL, out of L2 scope | Static only |
| MASVS-PRIVACY-1 | The app minimizes access to sensitive data and resources. | PASS | Static only |
| MASVS-PRIVACY-2 | The app prevents identification of the user. | PASS | Static only |
| MASVS-PRIVACY-3 | The app is transparent about data collection and usage. | FAIL | Static only |
| MASVS-PRIVACY-4 | The app offers user control over their data. | FAIL | Device-verified |

Within the MAS-L2 scope of twenty controls: five pass, thirteen fail, two are not applicable. Eight controls were device-verified; the device pass changed no verdict, and confirmed every failing one it touched.

### Every PASS in this report is static only

This is stated separately because it is the most important caveat in the document. All five passing controls rest on code and configuration review. None was confirmed at runtime.

- **MASVS-CRYPTO-1.** The primitives and formats were read, not exercised. The HPKE implementation states it is pinned to the RFC 9180 A.1 test vectors; those vectors were not executed during this assessment.
- **MASVS-AUTH-1.** The OAuth flows were not re-run on the device. Test 18 was planned and not reached.
- **MASVS-NETWORK-1.** No traffic was intercepted. Tests 12 and 13 were not run, for the reason in section 7.
- **MASVS-PRIVACY-1 and PRIVACY-2.** The permission set and the absence of tracking SDKs were established from the shipped manifest and the dependency tree, not from observed traffic.

A reader should treat these five as unverified claims, not as demonstrated results.

One PASS was independently confirmed at runtime even though its control did not pass overall: the shipped build carries no debuggable flag, and the device refused `run-as` against it both before and after the instrumented pass.

### Not-applicable justifications

**MASVS-NETWORK-2, identity pinning.** The control is scoped to "remote endpoints under the developer's control". The app's HTTP client contacts exactly two endpoint families, both third-party: Google APIs and Microsoft Graph. Pinning a third-party CA chain the developer does not control is explicitly outside this control and would create an availability failure on every rotation. The two hosts the developer does control, `share.ciphernest.io` and `auth.ciphernest.io`, are never fetched by the app. `share.ciphernest.io` appears only inside generated link text (`frontend/lib/services/share_service.dart:169`) and as an App Link host filter. `auth.ciphernest.io` is loaded by Chrome Custom Tabs during OneDrive sign-in, which uses the browser's trust store, outside the app's control. Grep for these hosts across `frontend/lib` returns no HTTP call site.

This N/A is conditional. If the share viewer's fetch is ever routed through the developer's Worker, or any telemetry or licence endpoint is added, NETWORK-2 becomes in scope and pinning must be implemented.

**MASVS-PLATFORM-2, WebViews.** The app contains no WebView. `pubspec.lock` contains neither `webview_flutter` nor `flutter_inappwebview`. The only Dart occurrences of the string are two comments recording that WebView-based OAuth was removed (`frontend/lib/services/cloud/onedrive_provider.dart:110`) and that the document viewer deliberately avoids one (`frontend/lib/src/screens/documents/document_viewer_screen.dart:18`). OAuth uses Chrome Custom Tabs via `flutter_web_auth_2`, not an embedded WebView. `pdfx` renders through the native `PdfRenderer`, `chewie` through ExoPlayer, and `pro_image_editor` draws to a canvas.

One WebView-capable component is merged into the manifest: `io.flutter.plugins.urllauncher.WebViewActivity`, from `url_launcher`. It is `exported="false"` and unreachable, because the single `launchUrl` call in the app passes `mode: LaunchMode.externalApplication` (`frontend/lib/src/screens/settings/settings_screen.dart:1545`). It is dead weight, not an attack surface.

## 4. Findings

Thirty-four findings here, plus five in the web section. Severity reflects impact on the product's core claim, which is that neither the developer nor the cloud provider can read the user's files, and that a lost or seized device does not yield them.

F-32 and F-33 were found during the device pass rather than in the source review, and they are the reason a device pass was worth running.

The single most severe finding in this assessment is W-01 in section 6, because it is the only one where key material reaches a third party. It is filed under the web component because that is where the defect lives.

Status values: OPEN means unfixed as of the assessed commit. No finding in this report has been remediated, because this assessment reports before it fixes.

Findings appear below in identifier order. This index gives the severity ranking.

| Severity | Findings |
|---|---|
| High | W-01, F-01, F-02, F-03, F-04, F-05, F-06, F-07, F-08, F-09, F-10, F-11, F-33, F-34 |
| Medium | F-12, F-13, F-14, F-15, F-16, F-18, F-19, F-20, F-21, F-22, F-23, F-27, F-28, F-29, F-32, W-02 |
| Low | F-17, F-24, F-25, F-26, F-30, F-31, W-03, W-04 |
| Info | W-05 |

Device-verified findings: F-01, F-02, F-03, F-04, F-05, F-06, F-08, F-10, F-11, F-12, F-14, F-15, F-18, F-21, F-32, F-33, F-34, and partly F-27. The rest are static or binary only, and each says so at the top of its entry.

---

### F-01. Decrypted plaintext persists indefinitely in the cache directory

**Severity: High. MASVS-STORAGE-1. MASTG-TEST-0001, MASTG-TEST-0207.**

**Verification: Device-verified. Decrypted MP3 and JPEG artefacts pulled from `cache/` with the app not running; 19 MB present; the app logged `Usage 18.62 MB / Limit 512.00 MB`, so eviction never ran.**

Every decrypted artefact the app produces is written to `getTemporaryDirectory()`, which is `/data/data/io.ciphernest.vault/cache`, and is removed only when a size budget is exceeded.

```dart
// frontend/lib/services/cache_manager_service.dart:296
final limitGB = prefs.getDouble('cache_limit') ?? 0.5; // Default 500MB
// :313
while (currentUsage > limitBytes && cacheFiles.isNotEmpty) {
  final victim = cacheFiles.removeAt(0);
```

The budget defaults to 500 MB. Below that figure nothing is ever deleted. The sweep runs on cold start (`frontend/lib/main.dart:74`), after each sync (`frontend/lib/services/sync_service.dart:219`), and when the settings slider is released. There is no age rule and no content rule.

What accumulates: full decrypted originals of any type (`frontend/lib/services/file_export_service.dart:59`), full decrypted documents (`frontend/lib/src/screens/documents/documents_screen.dart:180`), complete decrypted video and audio bodies written at true plaintext offsets (`frontend/lib/services/video_streaming_server.dart:223`), decrypted still images and thumbnails (`frontend/lib/src/screens/gallery/image_viewer_screen.dart:659`), decrypted cover art (`frontend/lib/services/audio_player_service.dart:112`), and SAF import copies (`frontend/android/app/src/main/kotlin/io/ciphernest/vault/MainActivity.kt:222`).

Several of these are named after the user's own filename. `File('${dir.path}/${file.filename}')` appears at `file_export_service.dart:59`, `documents_screen.dart:180`, and `folder_browser_screen.dart:1312`. The SAF import writes `"${System.nanoTime()}_$safe"`, also carrying the original name.

**Impact.** Adversary 4 extracts the cache and recovers both the plaintext content of recently viewed files and, from the filenames alone, a picture of the vault. The product claims files are protected at rest. Under 500 MB of cached material, they are not. The `.plain` video cache is explicitly permanent by design: "The disk cache is intentionally left behind, that's what makes replays instant" (`video_streaming_server.dart:343`).

**Fix.** Add a maximum-age sweep independent of the size budget, deleting any `*_decrypted.*`, `*.plain*`, `*_audio.bin`, or filename-named artefact older than a few minutes. Name every temporary plaintext file by opaque id, never by `file.filename`. Purge the cache on lock, not only on vault reset.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** purge of all large decrypted artifacts on lock (`cache_manager_service.dart` `purgeAllLargePlaintext`).

---

### F-02. Locking the vault does not revoke access to decrypted data

**Severity: High. MASVS-AUTH-2, MASVS-STORAGE-1. MASTG-TEST-0017.**

**Verification: Device-verified, and worse than written. The locked state could not be reached at all while the app ran. See F-33.**

`AppLockService.lockNow()` clears memory and nothing else:

```dart
// frontend/lib/services/app_lock_service.dart:127-136
```

It nulls the vault private key, clears `ThumbStore`, and clears the Flutter image cache. It does not delete the decrypted cache from F-01, does not stop the local streaming server, and does not end streaming sessions. After lock, the plaintext of every recently viewed photo, document and video is still on disk, and the loopback server of F-03 is still listening and still able to decrypt more.

Lock is also evaluated only on resume. `frontend/lib/src/app.dart:66-71` handles `AppLifecycleState.resumed` and no other state. There is no pause handler anywhere in the app. The default inactivity timeout is five minutes, the minimum selectable is one minute, and "Never" is offered (`frontend/lib/src/screens/settings/settings_screen.dart:462`). Lock is further deferred indefinitely while audio plays or a video session is open (`app_lock_service.dart:117-121`).

**Impact.** The lock screen is a UI gate, not a security boundary. An adversary who takes a locked phone gets the same cached plaintext as one who takes an unlocked one.

**Fix.** On `lockNow()`: stop the streaming server, drop all sessions, and delete the large plaintext artefacts. Handle `AppLifecycleState.paused` so the timeout starts at background time rather than being measured after the app is already visible again. Add an "Immediately" timeout option. Cap the playback deferral.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** lock now stops the streaming server and purges decrypted media from disk.

---

### F-03. Unauthenticated loopback server decrypts and serves any vault file

**Severity: High. MASVS-PLATFORM-1. MASTG-TEST-0029.**

**Verification: Device-verified. From uid 2000, a raw HTTP request to the loopback port returned 8,733,449 bytes of decrypted MP3 with ID3 tags intact, with no credential of any kind.**

`VideoStreamingServer` binds a shelf HTTP server to `127.0.0.1` on an OS-assigned port and serves decrypted media at `http://127.0.0.1:<port>/<fileId>` (`frontend/lib/services/video_streaming_server.dart:143,169`). The route handler checks the HTTP method and nothing else. There is no token, no header check, no `Origin` check.

Worse, a request for an unknown id is not rejected. It opens a new session:

```dart
// frontend/lib/services/video_streaming_server.dart:324-341
Future<_StreamingSession?> _sessionFor(String fileId) {
  final existing = _sessions[fileId];
  if (existing != null) return Future.value(existing);
  return _lazyOpens.putIfAbsent(fileId, () async {
      final file = await DatabaseService().getFileById(fileId);
      if (file == null || file.cloudId == null) return null;
      return await _openSession(file);
```

So an unauthenticated loopback request triggers a download, an HPKE key unwrap, and decryption. Two consequences follow. `endSession` does not revoke anything, because the next request silently reopens the session. And `stop()` has no caller anywhere in `frontend/lib`, so the listener stays bound for the entire process lifetime, across lock and sign-out.

Android does not namespace loopback per application. Any installed app holding `INTERNET` can connect. The only thing protecting the plaintext is that `file.id` is a version 4 UUID. That UUID is logged to logcat on every range request (`video_streaming_server.dart:445`), as is the port (`:168`).

**Impact.** A local application that learns one file id, from a logcat read on an older Android version, a bug report, or a shared crash log, holds a durable capability to read that file's plaintext. The port space is small enough to scan.

**Fix.** Mint a random per-process token at start, require it as a path prefix or header, and reject everything else. Maintain an explicit allowlist of live session ids so `_sessionFor` cannot resurrect a closed one. Call `stop()` from `lockNow()` and on sign-out. Remove the id and port from the logs.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** per-process 32-byte token required as the first path segment, constant-time compared; token discarded on stop.

---

### F-04. Share URLs containing raw decryption keys are stored in plaintext SQLite and copied to the clipboard

**Severity: High. MASVS-STORAGE-1, MASVS-CRYPTO-2. MASTG-TEST-0001.**

**Verification: Device-verified for the stored copy. The `shares` row was read out of the pulled database: a 266-character URL whose `k=` parameter decodes to 32 bytes, with `has_password = 0`. The clipboard half was not tested.**

A share link carries the file's content key in its fragment:

```dart
// frontend/lib/services/share_service.dart:160
fragment.write('k=${base64Url.encode(keyBytes)}');
// :169
return 'https://${AppConstants.shareHost}/s/$encodedDl#${fragment.toString()}';
```

The complete URL, fragment included, is persisted to the metadata database (`shares.share_url TEXT NOT NULL`, `frontend/lib/services/database_service.dart:359`), which is a plain `sqflite` database with no SQLCipher. It is also rendered as selectable text (`frontend/lib/src/screens/settings/active_shares_screen.dart:160`) and written to the system clipboard (`frontend/lib/src/screens/share/share_dialog.dart:332`, `active_shares_screen.dart:173`).

The shared blob itself is world-readable by design: it is uploaded to the cloud with anyone-with-link access so the web viewer can fetch it.

**Impact.** Anyone who reads the database recovers the decryption key for every active plain share, and those blobs are publicly downloadable. The clipboard copy exposes the same key to every clipboard manager and, on Android below 13, to any app that reads the clipboard. The manifest comment at `frontend/android/app/src/main/AndroidManifest.xml:25-28` already acknowledges that the shares table "holds magic links with raw key fragments".

**Fix.** Do not persist `share_url`. Store the share key under `k_local` or in the Keystore and rebuild the link on demand. Mark the clipboard item sensitive via `ClipDescription.EXTRA_IS_SENSITIVE` and auto-clear it.

**Status: OPEN.**

---

### F-05. No FLAG_SECURE anywhere, including the recovery phrase and share key screens

**Severity: High. MASVS-PLATFORM-3. MASTG-TEST-0010, MASTG-TEST-0289, MASTG-TEST-0291.**

**Verification: Device-verified. `screencap` returned legible frames on every screen tested, and the OS screenshot key wrote a file containing the live recovery phrase into `DCIM/Screenshots`.**

A search of `frontend/lib`, `frontend/android`, `frontend/ios`, `third_party/`, `pubspec.yaml` and `pubspec.lock` for `FLAG_SECURE`, `setSecure`, `setRecentsScreenshotEnabled`, `secure_application`, `flutter_windowmanager`, `screen_protector` and `no_screenshot` returns zero matches. `MainActivity.onCreate` sets no window flags.

Screenshots, screen recording and recents snapshots are unblocked on all 49 screens. Thirty-four of them render decrypted content or secrets. The four that matter most:

- `frontend/lib/src/screens/auth/recovery_phrase_screen.dart:141` and `frontend/lib/src/screens/settings/view_phrase_screen.dart:54` display the twelve-word BIP-39 mnemonic. One screenshot is a full vault compromise, and on a phone with photo backup enabled that screenshot leaves the device unencrypted.
- `frontend/lib/src/screens/share/share_dialog.dart:300` and `active_shares_screen.dart:160` render share URLs in selectable text widgets.

The device pass corrected one claim here, in the app's favour. A static reading of `active_shares_screen.dart:160` suggested a screenshot of that screen would expose the key. It does not. The rendered link is clipped to two lines and the capture ended at the base64 path segment, with the `#k=` fragment not visible. The key still reaches the clipboard through the Copy button, and it is still stored in plaintext in the database, so F-04 is unaffected. The correction is recorded because a published report that overstates a finding is worth less than one that does not.

The only mitigation is advisory copy: "Do not screenshot" (`view_phrase_screen.dart:118`).

Combined with F-06, the recents thumbnail is the sharper problem, because it requires no user action.

**Fix.** Set `FLAG_SECURE` on the window, or per-route for the thirty-four screens. The two phrase screens and the two share screens should be unconditional, with no user toggle.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** `FLAG_SECURE` set on the window in `MainActivity.applySecureWindow()`, release builds only.

---

### F-06. Recents snapshot captures decrypted content, and survives auto-lock

**Severity: High. MASVS-PLATFORM-3. MASTG-TEST-0289, MASTG-TEST-0292.**

**Verification: Device-verified. The task switcher card showed the decrypted gallery grid, a fullscreen decrypted photo, and the recovery phrase screen.**

```dart
// frontend/lib/src/app.dart:66-71
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    AppLockService().onResumed();
  }
}
```

Only `resumed` is handled. Nothing blanks the UI on `paused` or `inactive`. Android captures the last drawn frame when the app goes to background, so the recents card shows the gallery grid of decrypted thumbnails, or the fullscreen decrypted photo, or the phrase screen, depending on where the user was.

The image-cache purge in `lockNow()` happens after resume, which is strictly after the snapshot was taken. So the recents thumbnail still shows vault content after the app has locked itself.

**Fix.** Add a `paused`/`inactive` handler that covers the UI with an opaque surface and removes it on resume. This is needed in addition to F-05, because `FLAG_SECURE` and a pause cover solve overlapping but not identical problems.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** same window flag; Android also refuses to snapshot a secure window for recents.

---

### F-07. Decrypted copies are handed to arbitrary third-party apps and never cleaned up

**Severity: High. MASVS-STORAGE-2, MASVS-PLATFORM-1. MASTG-TEST-0004.**

**Verification: Device-verified in round 2. Both handoff paths left a decrypted copy on disk, each named after the user's own filename, still present minutes after the operation finished.**

Sharing out and opening a document both write full plaintext to the cache and hand a granted content URI to an app of the user's choosing.

```dart
// frontend/lib/src/widgets/file_actions.dart:34
if (plain != null) out.add(XFile(plain.path, name: f.filename));
// :55
await Share.shareXFiles(out);
```

There is no deletion after the share sheet returns. The doc comment states the intent: "the on-disk copies stay app-private and are reclaimed by the cache GC". Under F-01 that reclamation may never happen. The same pattern appears at `frontend/lib/src/screens/documents/documents_screen.dart:179-190`, `folder_browser_screen.dart:1311-1319` and `shared_viewer_screen.dart:603`, each calling `OpenFile.open`.

Compounding this, the `open_file` plugin's FileProvider is scoped to the whole filesystem. From the shipped build's `filepaths.xml`:

```xml
<paths>
    <root-path name="root" path="" />
    ...
    <cache-path name="cache-path" path="."/>
</paths>
```

The provider is `exported="false"`, and no exported activity proxies a caller-supplied URI into it, so sibling enumeration by another app is not possible today. The risk is the blast radius of a future mistake: any path passed to `OpenFile.open`, including the vault database or the secure-storage backing file, would be served without complaint.

Two of the three call sites also join an unsanitized filename into a path. `File('${dir.path}/${file.filename}')` at `documents_screen.dart:180` and `folder_browser_screen.dart:1312` would escape the cache directory given a filename containing `../`. The share viewer does sanitize (`shared_viewer_screen.dart:258-275`); the vault paths do not.

**Fix.** Delete the materialized plaintext when the share or open future returns. Override the `open_file` provider with an app-level declaration scoped to a single cache subdirectory. Reuse the existing `_sanitizeFilename` at the two vault call sites.

**Status: OPEN.**

---

### F-08. A crafted share link makes the app fetch an attacker-controlled URL

**Severity: High. MASVS-CODE-4, MASVS-PLATFORM-1. MASTG-TEST-0028, MASTG-TEST-0394.**

**Verification: Device-verified. A crafted link caused two fetches to a host of the tester's choosing, both logged with the app's own `Dart/3.10 (dart:io)` user agent.**

The app's deep-link filter correctly pins the host of the incoming link (`frontend/lib/src/app.dart:131-143`). The URL inside it is not validated at all.

```dart
// frontend/lib/src/screens/share/shared_viewer_screen.dart:88
_downloadUrl = utf8.decode(base64Url.decode(_padBase64(segments[1])));
// :191
final resp = await http.get(Uri.parse(url));
```

The base64url path segment decodes to a fully attacker-chosen absolute URL, fetched directly by the app. There is no host allowlist, no scheme check, and no response size cap. The host pin on the outer link buys nothing, because the attacker mints the outer link.

The Worker enforces a host allowlist for the web viewer (`worker.js:27-51`), so the browser path is bounded. The app path is not.

**Impact.** Sending a link to a CipherNest user causes their device to make an HTTPS request to a host of the sender's choosing, disclosing the device's IP address and confirming the app is installed. For a privacy tool that is a deanonymization primitive, not a theoretical one. `resp.bodyBytes` buffers the entire response, so a large target also terminates the app. The network security configuration permits cleartext to `127.0.0.1`, which makes the loopback server of F-03 reachable from a crafted link, though the attacker still needs the port and the file UUID.

**Fix.** Require `https` and restrict the host to the same allowlist the Worker uses. Stream the body with a size ceiling instead of buffering.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** host allowlist and `https` requirement on the share download URL, plus a 512 MB body cap.

---

### F-09. The recovery phrase entry field lets the keyboard learn the seed words

**Severity: High. MASVS-PLATFORM-3. MASTG-TEST-0006, MASTG-TEST-0258.**

**Verification: Static only. Not exercised on the device.**

The mnemonic verification field sets `autocorrect: false` but omits `enableSuggestions`, which defaults to true:

```dart
// frontend/lib/src/screens/auth/recovery_phrase_screen.dart:547-550
TextField(
  controller: controller,
  autocorrect: false,
  textCapitalization: TextCapitalization.none,
```

The restore screen gets this right, setting both (`frontend/lib/src/screens/auth/restore_phrase_screen.dart:461-462`). The asymmetry is the finding.

**Impact.** The IME's suggestion engine can observe and retain words of the master recovery phrase in its personal dictionary, from which they may later be offered as completions in other applications, and may be synchronized to the keyboard vendor's cloud depending on the keyboard.

**Fix.** Add `enableSuggestions: false` at `recovery_phrase_screen.dart:547`. Set `autocorrect: false`, `enableSuggestions: false` and `enableInteractiveSelection: false` on every password and phrase field, so that toggling the reveal control cannot re-enable the IME path.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** `enableSuggestions: false` added to the mnemonic verification field.

---

### F-10. The recovery phrase and decrypted images are written to the system clipboard

**Severity: High. MASVS-PLATFORM-3. MASTG-TEST-0008.**

**Verification: Device-verified in round 2. The full phrase pasted into another app, remained in Samsung's clipboard history afterwards, and Android showed no sensitive-content indicator. The copied share link carried its `#k=` key.**

```dart
// frontend/lib/src/screens/settings/view_phrase_screen.dart:168
Clipboard.setData(ClipboardData(text: words.join(' ')));
```

The full twelve-word mnemonic, with no confirmation dialog, followed by a snackbar advising the user to clear their clipboard afterwards. `frontend/lib/src/screens/auth/recovery_phrase_screen.dart:218` does the same for the freshly generated phrase, behind a warning dialog.

```dart
// frontend/lib/src/screens/gallery/image_viewer_screen.dart:1149
await Pasteboard.writeImage(bytes);
```

Decrypted image bytes to the clipboard. Samsung's clipboard history persists clipboard images to disk outside the application sandbox.

No clipboard write anywhere in the app sets `ClipDescription.EXTRA_IS_SENSITIVE`, and there is no auto-clear.

**Fix.** Add a platform channel that marks the mnemonic and share-URL clips sensitive, and a timed clear that only fires if the clipboard still holds the value written. Consider removing the phrase copy button entirely; the phrase is meant to be written down.

**Status: OPEN.**

---

### F-11. The metadata database is unencrypted

**Severity: High. MASVS-STORAGE-1. MASTG-TEST-0001.**

**Verification: Device-verified. The database was pulled off the device and opened directly: header `SQLite format 3`, 73 files with readable filenames, 54 with absolute local paths, 108 of 148 sync operations retaining names.**

`openDatabase` is called with no key and no SQLCipher (`frontend/lib/services/database_service.dart:89-104`). The only PRAGMA set is `foreign_keys = ON`. `pubspec.yaml` has `sqflite`, not `sqflite_sqlcipher`.

In plaintext, across 22 schema versions: original filenames, absolute local paths to gallery originals, MediaStore asset ids, capture timestamps, dimensions, codecs, recording device model, audio tags, folder names, album names, the account email embedded in `account_id`, unsalted SHA-256 hashes of plaintext content, and an append-only operation log (`sync_ops`) recording every add, rename, move, favourite and delete with timestamps and filenames. Compaction never drops operations, so purged files keep their filenames in the log permanently.

**Impact.** Adversary 4 reconstructs the complete contents and history of the vault without decrypting a single file. Against the product's claim that "filenames, folder names, album names and file contents are all encrypted", the cloud side of that claim holds and the device side does not. The unsalted content hashes additionally allow confirming whether a specific known file is in the vault.

**Fix.** Move to `sqflite_sqlcipher` with a key derived from the vault seed and wrapped by the Keystore. If that is too large a change for v1, encrypt the high-signal columns: `filename`, `local_path`, `folders.name`, `albums.name`, `sync_ops.name`, and the audio tags. Replace the plain SHA-256 with an HMAC under a vault-derived key.

**Status: OPEN.**

---

### F-12. All logging ships in release builds, and some of it names user files

**Severity: Medium. MASVS-STORAGE-2. MASTG-TEST-0003, MASTG-TEST-0203, MASTG-TEST-0231.**

**Verification: Device-verified, with a material refinement. See the finding text.**

Flutter does not strip `debugPrint` or `print` from release builds. The app has 118 `debugPrint` call sites plus six file-append logging sites. `kDebugMode`, `kReleaseMode` and `kProfileMode` appear nowhere in `frontend/lib`. Zero of the sites are guarded.

Representative examples:

```
frontend/lib/services/auto_sync_service.dart:779  'Heal re-upload failed for ${row.filename}: $e'
frontend/lib/services/backup_backfill_runner.dart:160  'Backfill failed for ${album.name}: $e'
frontend/lib/services/cache_manager_service.dart:122  'Cache Manager: could not delete ${f.path}: $e'
frontend/lib/services/sync_service.dart:149  'SyncService: deleted condemned blob $cloudId'
frontend/lib/services/video_streaming_server.dart:445  served $fileId bytes $rangeStart-$rangeEnd
```

The OneDrive provider embeds raw HTTP response bodies in thrown exceptions which are then logged (`frontend/lib/services/cloud/onedrive_provider.dart:264,299`). One of those paths raises `'Failed to fetch user info: ${meResp.body}'` (`:186`), which is the Graph `/me` response, containing the account email and display name.

There is also a persistent unencrypted log file, in the documents directory rather than the cache, never rotated and never deleted, not covered by vault reset:

```dart
// frontend/lib/services/auto_sync_worker.dart:183-188
final file = File('${dir.path}/autosync_debug.log');
await file.writeAsString(line, mode: FileMode.append, flush: false);
```

Its contents are counts rather than filenames, which limits the severity.

**Genuinely clean.** No key bytes, base64 keys, nonces, mnemonic words, passwords, bearer tokens or share key fragments are interpolated into any log line. Two sites are the template for the fix: `onedrive_provider.dart:140-141` logs the redirect prefix before `?`, and `:149-151` logs parameter names only, deliberately avoiding the OAuth code. The three hand-written Kotlin files contain zero `Log` calls, including `BiometricSeedVault.kt`, which handles the raw seed.

**Impact.** On Android 4.1 and later an app cannot read another app's logcat, so this is not directly exploitable by adversary 2. It matters for bug reports, OEM logging frameworks, crash-collection tooling, and anyone with ADB access.

**What the device pass actually showed, which cuts both ways.** A full session was captured: unlock, gallery browsing, a fullscreen photo, video playback, two audio tracks, the Active Shares screen and the recovery phrase screen. Out of 146,944 captured log lines the app emitted **16**. No key, token, password, mnemonic word, email address or filename appeared in any of them. The error paths that interpolate filenames were simply not hit, and the two sites that handle OAuth parameters log names rather than values by design.

So the volume risk is much lower in practice than 123 unguarded call sites suggests, and that is worth saying plainly. The content risk is not. Two of those 16 lines were these:

```
VideoStreamingServer listening on 127.0.0.1:43149
VideoStreamingServer beginSession <uuid>: header fetched in 1562ms (8 MB video, 17 chunks)
```

The port and the file identifier are precisely the two values an attacker needs to exploit F-03, and the app volunteers both on a normal playback path. The logging finding and the loopback finding are the same finding seen from two sides.

**Fix.** Route every site through one helper that early-returns unless `kDebugMode`. Throw typed errors carrying status codes rather than embedding response bodies. Delete `autosync_debug.log` or gate it on `kDebugMode`.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** all logging in the streaming server gated behind `kDebugMode`; the port is no longer logged.

---

### F-13. Creating a share link requires no additional authentication

**Severity: Medium. MASVS-AUTH-3.**

**Verification: Static only. Not exercised on the device.**

`ShareService().createShare` is invoked directly from the share dialog with no re-authentication (`frontend/lib/src/screens/share/share_dialog.dart:88`). It requires only that the vault is currently unlocked.

Sensitive operations were reviewed as a group:

| Operation | Requirement |
|---|---|
| View recovery phrase | Master password |
| Change password | Current password |
| Enable biometric unlock | Master password |
| Disable biometric unlock | None |
| Create a public share link | None |
| Forget vault on this device | Confirmation dialog |
| Disconnect a cloud account | Confirmation dialog |
| Change auto-lock timeout, including to Never | None |

The first three are correct. Creating a share link is the operation that turns a vault file into a publicly downloadable blob plus a key. It is the highest-value action in the app and is the least protected.

**Fix.** Require biometric or password confirmation before `createShare`, at minimum for links without a password or with a long expiry. Require confirmation before forget-vault.

**Status: OPEN.**

---

### F-14. Secure storage uses the plugin's weak default backend

**Severity: Medium. MASVS-CRYPTO-2, MASVS-STORAGE-1. MASTG-TEST-0016.**

**Verification: Device-verified. `FlutterSecureStorage.xml` holds four base64 ciphertexts in an ordinary preferences file, with the wrapped key in `FlutterSecureKeyStorage.xml`.**

`flutter_secure_storage` 9.2.4 is instantiated three times, all bare:

```dart
frontend/lib/services/cloud/account_registry.dart:19      const FlutterSecureStorage();
frontend/lib/services/device_identity_service.dart:20     const FlutterSecureStorage();
frontend/lib/services/key_manager_service.dart:95         const FlutterSecureStorage();
```

`AndroidOptions` is never passed. A repository-wide grep for `encryptedSharedPreferences` returns nothing. The plugin's default for that flag is `false`, which selects AES/CBC/PKCS7 for values with the AES key wrapped under an AndroidKeyStore RSA key using `RSA/ECB/PKCS1Padding`. That is unauthenticated CBC and PKCS#1 v1.5 unwrapping, rather than Jetpack `EncryptedSharedPreferences` with AES-GCM.

What is stored this way: the OAuth access and refresh tokens and the account email (`cloud_accounts_v1`), the active account id, the per-install device UUID, and the vault public key.

**Impact.** The key-encryption key stays inside the Keystore, so a pure file read from a pulled image does not break it. A root-level attacker on a live device, or a padding-oracle-shaped attack against the CBC layer, is in scope. The contrast with the app's own native code is instructive: `BiometricSeedVault.kt:313` gets this right.

**Fix.** Pass `aOptions: const AndroidOptions(encryptedSharedPreferences: true)` at all three sites, gated behind a one-way migration flag, or wrap the token blob under `k_local` with AES-GCM the way the seed blob already is.

**Status: OPEN.**

---

### F-15. The password-wrapped seed sits in SharedPreferences with no device binding

**Severity: Medium. MASVS-CRYPTO-2. MASTG-TEST-0001.**

**Verification: Device-verified. `seed_blob_v1` and its salt, nonce and tag, plus the separate `mnemonic_pw_blob_v1` set, were read out of the plaintext preferences XML.**

The vault seed is wrapped correctly. Argon2id with 64 MiB memory, two iterations, parallelism one, a fresh 16-byte random salt, then AES-256-GCM (`frontend/lib/services/key_manager_service.dart:96-101,529-540`). The wrapped blob and its salt, nonce and tag are stored as four base64 strings in SharedPreferences, keys `seed_blob_v1` and siblings.

SharedPreferences is a plaintext XML file. Nothing binds the blob to the device. An adversary who extracts it can attack the password offline at their own pace, on their own hardware.

The master password policy caps length at twenty characters and relies on composition rules (`frontend/lib/src/widgets/master_password_field_group.dart:110,171,181`). A twenty-character ceiling blocks passphrases, which are the defence that actually matters against an offline attack. There is no rate limiting or backoff on wrong password attempts; the only cost is one Argon2id evaluation.

A second offline oracle exists: the recovery mnemonic is also stored permanently on the device under a separate Argon2id derivation of the same password (`key_manager_service.dart:83-86,627-639`).

`android:allowBackup="false"` is set with `tools:replace` (`AndroidManifest.xml:33`) and confirmed in the shipped APK manifest, so none of this reaches Google Auto Backup. That is the control that keeps this at Medium.

**Fix.** Add a Keystore-wrapped layer around the blob, using a non-authentication-bound key, so extraction alone is insufficient. Raise the password ceiling to at least 64 characters and add an entropy or breach check in place of composition rules. Add persisted exponential backoff on failed unlock attempts.

**Status: OPEN.**

---

### F-16. Release builds silently fall back to the debug signing key

**Severity: Medium. MASVS-RESILIENCE-2, build integrity. MASTG-TEST-0038.**

**Verification: Static only. Not triggered in this build; the installed artefact is correctly signed with the upload key.**

```kotlin
// frontend/android/app/build.gradle.kts, release block
signingConfig = if (hasReleaseKeystore) {
    signingConfigs.getByName("release")
} else {
    signingConfigs.getByName("debug")
}
```

If `android/key.properties` is absent, the release build succeeds and is signed with the universally known Android debug key, with no warning.

The assessed artefact is correctly signed. `apksigner verify --print-certs` reports one signer, `CN=CipherNest, O=CipherNest, L=Lahore, C=PK`, RSA 2048, SHA-256 `C5:EE:12:...:8C:D0`, matching the upload key registered in `web-viewer/.well-known/assetlinks.json`. Scheme v2 verifies; v1 and v3 do not.

**Impact.** A build made on a machine without `key.properties`, such as a fresh clone or a CI runner, produces an installable artefact that anyone can re-sign and modify. It would be rejected by Play, but it could still be distributed sideloaded.

**Fix.** Throw a `GradleException` instead of falling back. Consider enabling v3 signing to allow future key rotation.

**Status: OPEN, not triggered in this build.**

---

### F-17. Dart code is not obfuscated

**Severity: Low. MASVS-RESILIENCE-3. MASTG-TEST-0051, MASTG-TEST-0368.**

**Verification: Binary-verified against the shipped APK.**

The Java and Kotlin half of the app is minified and obfuscated. The Dart half is not.

An earlier reading of this finding was wrong and is corrected here, because the method matters. `frontend/android/app/build.gradle.kts` declares `proguardFiles` but never sets `isMinifyEnabled`, which suggested R8 was off. The shipped build proves otherwise. `build/app/outputs/mapping/release/mapping.txt` is 400,025 mapping lines produced by R8 8.11.18, with entries such as `IsEnabledMessage -> a`, alongside `seeds.txt`, `usage.txt` and `resources.txt`. The Flutter Gradle plugin enables shrinking and obfuscation for release builds on its own. In the shipped dex, `io.ciphernest.vault.BiometricSeedVault` does not appear by name, while `MainActivity` and `UploadForegroundService` do, which is exactly correct: R8 must preserve the names of manifest-referenced entry points.

Dart is a different story. No `--obfuscate --split-debug-info` appears in any documented build command across `docs/`, so the AOT snapshot keeps its symbol names:

```
$ unzip -p app-release.apk lib/arm64-v8a/libapp.so | strings | grep -E "KeyManagerService|EncryptionService"
KeyManagerService (3 occurrences)
EncryptionService
```

`ShareService`, `BiometricUnlockService` and `VideoStreamingServer` are likewise present. Since all the security logic lives in Dart, the obfuscated half is the half that matters least.

**Impact.** Low against this threat model. CipherNest's security does not depend on code secrecy, the source is public under GPL-3.0, and the algorithms are documented. The practical cost is that a symbol-rich AOT snapshot lowers the effort needed to build a targeted patch against F-03 or F-11 for a sideloaded build.

**Fix.** Add `--obfuscate --split-debug-info=build/symbols` to the release command and archive the symbol files so crash reports stay readable. Set `isMinifyEnabled = true` explicitly so the configuration states what the build actually does rather than relying on plugin behaviour.

**Status: OPEN.**

---

### F-18. Media session publishes decrypted track titles and cover art by default

**Severity: Medium. MASVS-PLATFORM-3, MASVS-PRIVACY-1. MASTG-TEST-0005.**

**Verification: Device-verified. `dumpsys media_session` reported `metadata: size=6, description=A song, Unknown, Tracks`, so the real track title and queue name are published by default.**

```dart
// frontend/lib/services/audio_player_service.dart:84-92
title: _showTitlesOnLockScreen ? displayTitle(file) : 'CipherNest Audio',
artist: _showTitlesOnLockScreen ? 'Unknown' : null,
album: _showTitlesOnLockScreen ? _queueSourceName : null,
artUri: artUri,
```

`artUri` is a `file://` URI pointing at decrypted cover art on disk (`:106-122`). The privacy flag is well designed and gates title, artist, album and art together. It defaults to `true` (`:43,71`).

So out of the box the real track title, the playlist name and decrypted cover art are published to the system media session, visible on the lock screen, on the always-on display, on paired Bluetooth, Android Auto and Wear devices, and to any application holding notification-listener access.

Related: `com.ryanheise.audioservice.AudioService` is exported with no permission and a `MediaBrowserService` intent filter (merged manifest). Whether the browse tree serves anything to an arbitrary caller was not determined; see section 8.

**Fix.** Default `_showTitlesOnLockScreen` to false. Make it opt-in with a clear explanation.

**Status: OPEN.**

---

### F-19. No timeouts on any network call

**Severity: Medium. MASVS-NETWORK-1, robustness.**

**Verification: Static only.**

A grep for `.timeout(`, `connectionTimeout` and `idleTimeout` across `frontend/lib/services` returns nothing. Every one of roughly thirty HTTP calls in `google_drive_provider.dart` and `onedrive_provider.dart` uses the package default, which is no application-level timeout.

**Impact.** A hung connection, which a hostile or merely broken network can cause, holds an upload slot indefinitely. Combined with the foreground service that pins the process during uploads, this can keep the app alive and the vault key resident in memory for an unbounded period. That last consequence is what makes it a security finding rather than a usability one.

**Fix.** Wrap every call in a timeout appropriate to its size class, short for metadata operations and longer for transfers, and fail the job cleanly on expiry.

**Status: OPEN.**

---

### F-20. Cross-account data is co-mingled and never deleted

**Severity: Medium. MASVS-PRIVACY-4, MASVS-STORAGE-1.**

**Verification: Static only.**

There is one database for all accounts, scoped only by an `account_id` column. Removing an account (`frontend/lib/src/screens/settings/settings_screen.dart:846-858`, `account_registry.dart:84-92`) removes the registry entry and the tokens. No `DELETE ... WHERE account_id = ?` exists anywhere.

The removed account's filenames, folder names, album names and activity history stay in the local database, and are therefore included in the next encrypted database snapshot uploaded to whichever other provider is active. The decrypted cache is also shared: account A's plaintext media remains in the cache directory while account B is in use.

**Fix.** Delete rows by `account_id` from `files`, `folders`, `albums`, `shares` and the sync tables on account removal, and purge that account's cache artefacts. A database file per account would be cleaner.

**Status: OPEN.**

---

### F-21. Plaintext filenames and sizes of deleted files persist in SharedPreferences and survive vault reset

**Severity: Medium. MASVS-STORAGE-1, MASVS-PRIVACY-4.**

**Verification: Device-verified. `auto_sync_deleted_keys` was present in the preferences XML carrying a filename and an exact byte size.**

```dart
// frontend/lib/services/auto_sync_service.dart:807-814
final keys = prefs.getStringList('auto_sync_deleted_keys') ?? [];
final key = '$filename|$sizeBytes';
```

A growing plaintext list of the filename and exact size of every file the user has deliberately deleted, in an XML file. `auto_sync_deleted_keys` is not in `VaultResetService._vaultPrefs` (`frontend/lib/services/vault_reset_service.dart:27-46`), so "Forget this vault on this device" leaves it behind, along with `entitlement_plus_v1`, `device_name_v1`, `meta_migration_remaining_v1` and `sync_clock_skew_v1`.

Also in plaintext preferences: `backup_enrolled_buckets`, the normalized names of the device albums enrolled for backup, which are themselves content-revealing.

**Fix.** Store the deletion tracker as `HMAC(k_local, filename|size)`, or move it into the database. Add every vault-derived key to `_vaultPrefs`.

**Status: OPEN.**

---

### F-22. The published privacy policy does not match the shipped build

**Severity: Medium. MASVS-PRIVACY-3. MASTG-TEST-0206.**

**Verification: Static only. Tests 12 and 13 were not run, so no traffic inventory backs this.**

The policy at `https://ciphernest.io/privacy` was cross-checked against the code.

| Claim | Code | Verdict |
|---|---|---|
| "There is no CipherNest account, no email address, no analytics, no advertising identifier, no crash reporting." | No Firebase, Crashlytics, Sentry, or any analytics SDK in `pubspec.yaml` or `frontend/lib`. No advertising id API. | Consistent |
| "The app does not contact any server operated by me during normal use." | OneDrive sign-in redirects to `https://auth.ciphernest.io/oauth-callback`, a Cloudflare Worker the developer operates, loaded in a Custom Tab during normal use (`frontend/lib/services/cloud/onedrive_provider.dart:38`). The share viewer proxy is separately disclosed; this host is not. | Inconsistent |
| "To check whether a purchase is active, the app sends a purchase token and a pseudonymous identifier derived from your vault key to RevenueCat." | `purchases_flutter` is not a dependency. No RevenueCat code exists. The billing integration is unbuilt. | Inconsistent, describes a future state |
| "Filenames, folder names, album names and file contents are all encrypted before upload." | True for current uploads: names are HPKE-sealed into `appProperties` on Drive and into the object name on OneDrive (`frontend/lib/services/cloud/sealed_metadata.dart`). Not true for files uploaded by older builds, which retain plaintext `original_name` until the user runs the Settings migration (`frontend/lib/services/metadata_migration_service.dart:17-19`). | Consistent for new installs, incomplete for upgrades |
| "Your cloud provider can see that encrypted files exist, their sizes, and when they were uploaded." | Accurate, and understated. The provider also sees a plaintext `README.txt` naming the product, the folder tree `CipherNest/{vault,backup,backup/log,shares}`, the file-to-thumbnail pairing, the number of syncing devices and their per-install UUIDs in log object names, and per-device activity cadence from object sequence numbers and timestamps. | Consistent but incomplete |
| "The decryption key is placed in the part of the link after the `#`, which browsers never send to any server." | False in the path the viewer itself handles. A link whose `#` was percent-encoded to `%23` carries the key in the request path, where Cloudflare sees and logs it. See W-01. | Inconsistent, and this is the serious one |
| "Cloudflare's request logs for this proxy are retained for at most seven days." | Nothing in the repository sets or pins retention. `wrangler.jsonc` enables observability with no sampling or retention key, and there is no Logpush configuration. Retention is the account default, whatever that currently is. The sentence is also scoped to "this proxy" while logging covers every request to both Worker hosts. | Unverifiable from the repository |
| "The sign-in tokens are stored on your device only." | True. Tokens are in `flutter_secure_storage`; see F-14 for the backend strength. | Consistent |
| "The twelve words are generated on your device and never transmitted anywhere." | True. No network path touches the mnemonic. One platform caveat: without data extraction rules the wrapped seed can leave via device-to-device transfer. See F-27. | Consistent in the app, platform gap |

The Play Data Safety form is not yet submitted. Section 8.4 of the launch playbook plans to declare Purchase history and Device or other IDs, both shared with RevenueCat. Since RevenueCat is not integrated in this build, submitting that form as planned would declare collection that does not occur. Over-declaring is not the safe option: it contradicts the policy's own "nothing" and invites questions a reviewer would otherwise never ask.

The planned answer "Do you provide a way for users to request data deletion: Yes" is not supported by the app. See F-23.

Google's guidance treats data that stays on the device as not collected, so the locally stored OAuth email correctly requires no declaration. It is obtained from the provider, kept in secure storage, used only as a local composite key, and never transmitted to the developer or to any third party.

**Fix.** Correct the fragment sentence after W-01 is fixed, not before. Add one sentence naming `auth.ciphernest.io` and what it sees, which is the OAuth authorization code and standard request metadata. Move the RevenueCat paragraph behind a "when you buy something" framing, or remove it until the integration ships and reinstate it in the same release. Pin Cloudflare log retention and record the setting, or reword to name the account default. Answer the Data Safety form against the build being submitted, not the roadmap. Auto-run the metadata migration instead of requiring a Settings visit, so the filename claim holds for upgraders.

**Status: OPEN.**

---

### F-23. No way to delete vault data from the cloud, and no export

**Severity: Medium. MASVS-PRIVACY-4.**

**Verification: Static only.**

`VaultResetService.forgetVaultOnDevice` is explicitly device-scoped: "Cloud blobs, the op-log, and snapshots are untouched" (`frontend/lib/services/vault_reset_service.dart:17-18`). It does the local job thoroughly: stops the movers, signs out, wipes keys, destroys the database, removes flow preferences, and deletes the cache directory recursively.

What survives in the user's cloud after a reset: every encrypted file and thumbnail, every database snapshot, the entire append-only operation log including tombstones that name deleted files, the `README.txt`, and any share blobs. The user must delete these manually through the Drive or OneDrive web interface, which the README specifically tells them not to do.

Share revocation exists and works (`frontend/lib/services/share_service.dart:177-188`). Individual file deletion removes the cloud blob. There is no bulk cloud erase and no data export path.

**Fix.** Add "Delete everything from the cloud" alongside the device reset, with a clear explanation that it is irreversible. Add an export that writes the decrypted vault to a user-chosen location.

**Status: OPEN.**

---

### F-24. minSdk 24 admits platforms that no longer receive security updates

**Severity: Low. MASVS-CODE-1. MASTG-TEST-0245.**

**Verification: Binary-verified. The shipped APK declares `minSdkVersion 24` and `targetSdkVersion 36`.**

The shipped APK declares `minSdkVersion 24` and `targetSdkVersion 36`. Targeting is current and correct. The floor is Android 7.0, released 2016 and long past its last security patch.

This is not only a patch-level concern. `setUnlockedDeviceRequired` and StrongBox require API 28, and the Keystore code has a pre-28 path that omits the former (`frontend/android/app/src/main/kotlin/io/ciphernest/vault/BiometricSeedVault.kt:284-286`). On API 24 to 27 the app's strongest key protection is weaker than the code elsewhere implies, and the platform beneath it is unpatched.

**Fix.** Raise `minSdk` to 26, or to 28 to make the Keystore path uniform. Measure the install-base cost first.

**Status: OPEN.**

---

### F-25. No forced-update mechanism

**Severity: Low. MASVS-CODE-2. MASTG-TEST-0036, MASTG-TEST-0392.**

**Verification: Static only.**

There is no in-app update check and no minimum-version gate. No use of Play's in-app updates API, and no server-side version floor, which follows from there being no server.

**Impact.** When a vulnerability in this report is fixed, there is no mechanism to move users off the vulnerable build. Play's automatic updates will reach most users eventually, and none at all if they have updates disabled.

**Fix.** Integrate the Play in-app update API with an immediate-update flow reserved for security releases. A version floor could also be carried in the encrypted cloud metadata the app already reads.

**Status: OPEN.**

---

### F-26. Dependency posture is not demonstrated

**Severity: Low. MASVS-CODE-3. MASTG-TEST-0272, MASTG-TEST-0274.**

**Verification: Static only.**

The app has 39 direct Dart dependencies. No software bill of materials is produced, and no dependency vulnerability scan runs in development or in CI. MASVS v2.1.0 added CycloneDX SBOM support specifically for this control.

No dependency was checked against an advisory database during this assessment. That is a statement of what was not done, not a finding that the dependencies are clean.

One concrete item: `google_fonts` is declared in `pubspec.yaml:70` but never used. The only occurrences in `frontend/lib` are two comments. All fonts are bundled as assets and declared under `flutter.fonts`. The dependency is unused surface. Its absence from the code is also the reason the app makes no runtime request to `fonts.gstatic.com`, which is the correct outcome for a privacy product and worth keeping deliberate rather than accidental.

**Fix.** Generate a CycloneDX SBOM as a release artefact. Add `dart pub outdated` and an advisory scan to the release checklist. Remove `google_fonts`, or pin `GoogleFonts.config.allowRuntimeFetching = false` if it is ever used.

**Status: OPEN.**

---

### F-27. No data extraction rules, so device-to-device transfer is not blocked

**Severity: Medium. MASVS-STORAGE-2. MASTG-TEST-0009, MASTG-TEST-0216, MASTG-TEST-0262.**

**Verification: Partly device-verified. The platform lists the app as not a backup participant, confirming cloud backup is excluded. The device-to-device path runs through a separate transport and was not tested. See section 7, test 15.**

`android:allowBackup="false"` is set and confirmed in the shipped APK manifest. On Android 12 and later that attribute governs cloud backup. Device-to-device transfer is governed separately by `android:dataExtractionRules`, which is not declared. `frontend/android/app/src/main/res/xml/` contains only `network_security_config.xml`.

**Impact.** On API 31 and above, a D2D transfer to a new phone can carry the application's data directory. That directory holds precisely what the manifest comment at `AndroidManifest.xml:25-28` says `allowBackup="false"` exists to protect: the password-wrapped seed, the biometric blob, and the shares database containing magic links with raw key fragments. The stated defence is half-implemented on current Android versions.

**Fix.** Add `res/xml/data_extraction_rules.xml` excluding the root domain from both `<cloud-backup>` and `<device-transfer>`, and reference it from the application element.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** `data_extraction_rules.xml` added, excluding every domain from both cloud backup and device transfer.

---

### F-28. Revoking a share can silently fail, and resetting the vault orphans live public links

**Severity: Medium. MASVS-PRIVACY-4.**

**Verification: Static only.**

Share revocation has four separate failure paths, all of which leave a publicly downloadable blob with a valid key in circulation and no way to find it again.

1. Revoke deletes the local row even when the cloud delete threw. The exception is caught and logged, then `deleteShare` runs regardless (`frontend/lib/services/share_service.dart:182-187`). The link stays live and the UI handle is gone. Vault blobs get a condemned-blob retry sweep (`frontend/lib/services/sync_service.dart:138-155`); shares get none.
2. The blob is uploaded and granted anyone-with-link access before the local row is written. The code acknowledges the window: "so revokeShare could never reach it" (`frontend/lib/services/cloud/google_drive_provider.dart:544-546`). The mitigation is a best-effort delete that can itself fail.
3. Forget-vault destroys the `shares` table (`frontend/lib/services/vault_reset_service.dart:73`) while never-expiring public blobs remain. Restoring from the recovery phrase cannot rebuild the list, because restore reads the op-log and the vault reconcile, and neither enumerates the `shares/` folder.
4. The Active Shares screen lists local rows only. `CloudProvider` has no `listPublicShares`, and `listCloudFiles` deliberately excludes the shares folder (`google_drive_provider.dart:264-266`). There is no reconciliation against reality.

**Fix.** Write a provisional local row before upload and sweep provisional rows at launch. Keep the row and mark it condemned when a cloud delete fails, retrying on each sync. Add `listPublicShares()` and reconcile the screen against it. Record shares as sync operations so they survive a phrase restore.

**Status: OPEN.**

---

### F-29. Cloud object names leak a stable device identifier and approximate filename length

**Severity: Medium. MASVS-PRIVACY-2.**

**Verification: Static only.**

Two metadata side channels are visible to the cloud provider.

The per-install device UUID appears in object names in the clear: `ops_<deviceId>_<seq>.cnest` and `state_<deviceId>_<seq>.cnest` (`frontend/lib/services/sync/segment_codec.dart:33-34,100-101`), and `db_backup_<deviceId>.cnest` (`frontend/lib/services/database_backup_service.dart:56`). The provider therefore learns how many devices sync this vault, and gets per-device sequence numbers and timestamps that describe activity cadence. The identifier itself is well handled everywhere else: a random v4 UUID in secure storage, deliberately excluded from the database backup so a restore cannot clone an identity (`frontend/lib/services/device_identity_service.dart:5-12,29`). The name only needs to be stable and unique, not to be the device id.

Sealed metadata is not length-padded. `maxNameBytes = 120` with `_chunkSize = 100`, and the payload is truncated rather than padded (`frontend/lib/services/cloud/sealed_metadata.dart:44-69`). On OneDrive the sealed blob rides inside the object name (`onedrive_provider.dart:312-314`), so the name's length is a near-direct function of the plaintext filename's length. On Drive the count of `m0..mN` properties bins it more coarsely.

**Fix.** Name log and backup objects with `HMAC(vault key, deviceId)` or a per-vault random label. Pad the sealed JSON to the fixed 120-byte budget before sealing, which costs nothing and removes the length channel.

**Status: OPEN.**

---

### F-30. GPS metadata is stripped on one upload path and preserved on another, and neither is documented

**Severity: Low. MASVS-PRIVACY-3.**

**Verification: Static only. Not exercised on the device.**

The app never reads location. A grep for GPS, latitude and longitude tags across `frontend/lib` returns nothing, and `ACCESS_MEDIA_LOCATION` is not declared in the shipped APK. EXIF is read for display only, from local plaintext, and is never persisted to the cloud (`frontend/lib/services/file_metadata_service.dart:225-253`).

The consequence is unintended. Every gallery and auto-sync upload path uses `asset.file` rather than `asset.originFile` (`auto_sync_service.dart:383,548`, `migration_service.dart:156,229,309`, `upload_pipeline.dart:585`). Without `ACCESS_MEDIA_LOCATION`, MediaStore redacts GPS EXIF from the copy it returns on Android 10 and later. The file picker and SAF paths do not go through MediaStore and preserve it.

So the same photo uploads with its geotag or without it depending on how the user added it, the user is never told, and the encrypted copy may differ from the phone's original. This is a data fidelity issue rather than a leak, since the files are encrypted into the user's own cloud, but it also means a restored file will not byte-match the original.

This needs device confirmation before it is treated as settled. See section 7.

**Fix.** Decide explicitly. Either declare `ACCESS_MEDIA_LOCATION`, use `originFile`, and state in the policy that EXIF including location is preserved inside the encrypted file and never extracted; or keep the redaction, apply it on both paths for consistency, and document it as a feature.

**Status: OPEN, needs device verification.**

---

### F-31. The INTERNET permission is inherited from a wallpaper plugin

**Severity: Low. MASVS-CODE-3.**

**Verification: Binary-verified. `INTERNET` appears in the shipped APK permission list but not in the application manifest.**

`android.permission.INTERNET` appears in the shipped APK's permission list but is not declared in `frontend/android/app/src/main/AndroidManifest.xml`. It is merged in by `async_wallpaper` and `google_sign_in_android`.

**Impact.** No direct security consequence. It is a supply-chain fragility: an application whose entire function is network transfer depends on a wallpaper plugin to declare the permission that makes it work. Removing or replacing that plugin would produce a release build in which every network call fails.

**Fix.** Declare `INTERNET` in the application's own manifest.

**Status: OPEN.**

---

### F-32. There is no way to lock the vault on demand

**Severity: Medium. MASVS-AUTH-2, MASVS-PRIVACY-4.**

**Verification: Device-verified. The operator went looking for a lock control during testing and could not find one. A search of the Dart tree then confirmed why.**

`AppLockService.lockNow()` has no callers anywhere outside its own file. The service's own documentation comment asserts the opposite:

```dart
// frontend/lib/services/app_lock_service.dart:89
/// protecting yet; manual [lockNow] still works.
```

The only paths that reach it are `_onTimeout`, the inactivity timer, and `onResumed`, which locks only if the timeout already elapsed while the app was away. There is no menu item, no gesture, and no settings action that locks the vault.

**Impact.** A user who wants to hand their unlocked phone to someone cannot close the vault first. The product's entire premise is that the vault is a boundary, and the user has no control over that boundary. This is also the precondition that makes F-33 severe rather than merely untidy.

**Fix.** Add a lock action to the settings screen and the gallery overflow menu, wired to `lockNow()`. Correct the stale comment.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** "Lock vault now" action added to Settings, wired to `lockNow()`.

---

### F-33. Opening any media disables auto-lock for the rest of the process lifetime

**Severity: High. MASVS-AUTH-2. MASTG-TEST-0017.**

**Verification: Device-verified. After playing and then stopping audio, the vault did not lock after more than a minute at a one-minute timeout. The media session read `PAUSED`, the loopback listener was still bound, and two streaming sessions were still open.**

Auto-lock is deferred whenever playback is considered active:

```dart
// frontend/lib/src/app.dart:52-54
isPlaybackActive: () =>
    AudioPlayerService().playing ||
    VideoStreamingServer().hasActiveSessions,
```

and

```dart
// frontend/lib/services/video_streaming_server.dart:114
bool get hasActiveSessions => _sessions.isNotEmpty;
```

Pausing clears `playing`. Nothing clears `_sessions`. The only code that ends an audio streaming session is `_endCloudSessions()` and `ejectFile()`, and pausing calls neither. So once any track or streamed video has been opened, `hasActiveSessions` stays true and `_onTimeout` re-arms a 30-second timer indefinitely (`app_lock_service.dart:117-121`).

**Impact.** Combined with F-32, the vault becomes permanently open. The user has no manual lock, and the automatic one will never fire again. On the test device the only way to reach a locked state was `am force-stop`, which is not an action a user would think to take, and which is indistinguishable to them from the app crashing.

This also made one planned test unanswerable. Whether the loopback server continues serving decrypted media after a lock cannot be determined on the shipped build, because reaching the locked state requires killing the process, which closes the server's socket with it. That is reported as an open question rather than a pass.

**Fix.** End the streaming session when playback is paused or the player is dismissed, not only when the queue is replaced or a file is deleted. Separately, cap the deferral so it cannot extend indefinitely regardless of session state.

**Status: FIXED in code on 2026-09-20, not yet re-verified on device.** auto-lock deferral now keys on recent streaming traffic rather than session existence, with a 30 minute hard cap.

---

### F-34. Swiping the app away does not close the vault

**Severity: High. MASVS-AUTH-2, MASVS-STORAGE-1.**

**Verification: Device-verified, reported from normal use. After clearing the app from recents and reopening it, the vault was still unlocked, with the media notification still in the shade.**

The vault key lives in the Dart heap. It is cleared when the vault locks or when the process dies. Neither happens on a swipe-away, because the media foreground service keeps the process alive whenever a track is loaded, paused included. So the user performs the gesture that every Android user reads as "close this app", the process survives, and reopening lands straight back inside an unlocked vault.

This is the same root cause as F-33 seen from the other end. F-33 was the lock timer never firing; this is the process never dying. Either one alone leaves the vault open, and before the F-33 fix both were true at once.

A second, smaller part of the same report: locking the vault left music playing. That is defensible on its own, but it also leaves the decrypted track title on the lock screen through the media session, which is F-18.

**Fix.** A `TaskExitService` receives `onTaskRemoved` and ends the process, so a swipe-away is a real close. Because deliberate background playback is a legitimate reason to want the opposite, it is a setting rather than an assumption: "Keep playing after closing", off by default. When it is off, locking also stops playback. When it is on, both behaviours are left alone and the user has chosen that.

**Status: FIXED in code on 2026-09-21, not yet re-verified on device.** The device was disconnected when the build completed.

---

## 5. What passed, and why it matters

A findings list read alone gives a false impression. The cryptographic core of this application is the strongest part of it, and several controls that commonly fail elsewhere hold here.

**MASVS-CRYPTO-1 passes on evidence.** File bodies are AES-256-GCM in 512 KiB chunks with a 12-byte nonce and 128-bit tag (`frontend/lib/services/encryption_service.dart:46-50`). The chunk nonce is a big-endian counter and is verified on decrypt rather than trusted (`frontend/lib/crypto/aes_gcm.dart:93-95`). Associated data binds `content_id || chunk_index || total_chunks` (`encryption_service.dart:466-473`), so reordering, truncation and splicing are rejected. A fresh random 256-bit key is generated for every encryption call (`:133`), which is what makes the counter nonce safe. Per-file keys are sealed with HPKE per RFC 9180, base mode, DHKEM(X25519, HKDF-SHA256) with HKDF-SHA256 and AES-128-GCM, under a frozen info string (`frontend/lib/crypto/hpke.dart:29-31,69-70`). The key hierarchy derives from a 64-byte BIP-39 seed through HKDF-SHA256 with domain-separated labels (`key_manager_service.dart:64-65,463-485`). `Random.secure()` is used at every cryptographic randomness site; the one `Random()` is a UI shuffle in the memories tab. There are no hardcoded keys, IVs or salts. Public-key comparison is constant-time (`key_manager_service.dart:692-699`). The database snapshot and the sync op-log use the same authenticated format, and the op-log is sealed before upload with no code path that uploads raw operations (`frontend/lib/services/sync/segment_codec.dart:53-60`, `sync_engine.dart:236-241`).

**The biometric implementation is correct**, which is rare. `frontend/android/app/src/main/kotlin/io/ciphernest/vault/BiometricSeedVault.kt:305-325` builds the key with `setUserAuthenticationRequired(true)`, `setInvalidatedByBiometricEnrollment(true)`, `setUserAuthenticationParameters(0, AUTH_BIOMETRIC_STRONG)` on API 30 and above with `setUserAuthenticationValidityDurationSeconds(-1)` below, `setKeySize(256)`, GCM with no padding, `setUnlockedDeviceRequired(true)`, and StrongBox with a `StrongBoxUnavailableException` fallback to the TEE (`:290-303`). The prompt allows `BIOMETRIC_STRONG` only, with no device-credential fallback (`:221`). A `CryptoObject` is used for both encrypt and decrypt (`:122,184,242`), and the success callback uses `result.cryptoObject?.cipher` rather than the captured one (`:230`). No code path reads the seed without user presence: `checkArmed` calls only `Cipher.init`, never `doFinal`. `KeyPermanentlyInvalidatedException` tears the wrap down and falls back to the password. Enabling biometrics always requires the master password.

**MASVS-AUTH-1 passes.** Google uses the `drive.file` scope only (`google_drive_provider.dart:26-30`), which limits the app to files it created, and sign-out calls `disconnect()`, revoking the grant server-side (`:134-138`). Microsoft uses the authorization code flow with PKCE S256, a 32-byte verifier from `Random.secure()`, bound on exchange (`onedrive_provider.dart:59-71,101-102,165`). The embedded Entra client id is a public client identifier, not a secret, which is correct for a native app. No token is logged anywhere.

**MASVS-NETWORK-1 passes.** No `badCertificateCallback`, no custom `SecurityContext`, no `HttpOverrides` anywhere in `frontend/lib` or `frontend/android`. All remote traffic uses the platform TLS stack with default validation. Cleartext is permitted for `127.0.0.1` and `localhost` only, via an explicit and well-commented network security configuration, and the shipped manifest references it.

**MASVS-PRIVACY-1 and PRIVACY-2 pass.** There is no account system, no analytics, no crash reporter, no advertising identifier, and no third-party SDK that collects data. The device identifier is a per-install UUID in secure storage, deliberately excluded from the database backup so a restored snapshot cannot inherit another device's identity (`device_identity_service.dart:5-12`). Permissions in the shipped APK are justified by features, with two exceptions merged by plugins and unused: `WRITE_EXTERNAL_STORAGE` capped at API 28, and the deprecated `USE_FINGERPRINT`. Notably absent: `ACCESS_MEDIA_LOCATION`, so the app never reads GPS coordinates from MediaStore.

**Also verified clean.** `allowBackup="false"` with `tools:replace`, confirmed in the shipped APK manifest. Release is not debuggable. Flutter's built-in deep linking is explicitly disabled, closing the named-route injection surface. The deep-link host filter pins the share host and path prefix. The share-link fragment key is never logged, never persisted and never written to disk. The filename from the `n=` fragment parameter is sanitized against traversal. All SQL uses bound parameters, with no interpolated raw queries. The keystore and `key.properties` are gitignored and untracked. No `client_secret`, API key or embedded secret of any kind. Upload and sync notifications carry counts, never filenames, and the filename-bearing `detail` field is deliberately not mirrored to the foreground service.

## 6. Web viewer and Cloudflare Worker

MASVS does not cover web. This section assesses `worker.js` and `web-viewer/` against OWASP ASVS 4.0.3, and re-verifies the five existing ledger entries.

### Ledger cross-reference

| Entry | Claim | Verdict |
|---|---|---|
| SA-WEB-01 | `/proxy` is an unauthenticated open relay for allowlisted hosts | **Partially fixed.** Step 1 done: the allowlist is trimmed and the Dropbox suffixes are gone (`worker.js:39-43`). Steps 2 through 6 are open. `Access-Control-Allow-Origin: *` remains on both the response (`worker.js:144`) and the preflight (`:83`). There is no `Origin` check, no rate limiting, no Turnstile, and no magic-byte validation. Verified live: `GET /proxy?u=<allowlisted>` returns 200 with no `Origin` header, and 200 with `Origin: https://evil.example`. A disallowed host correctly returns 403. |
| SA-WEB-02 | Share expiry is client-advisory, enforced only by blob deletion | **Open, accepted.** `exp` is read from the fragment and checked client-side in `web-viewer/share.js:95-100` and in the app's `shared_viewer_screen.dart`. A recipient can strip it. Real expiry is `ShareService.sweepExpired`, called from `frontend/lib/src/app.dart:109` on app start. |
| SA-WEB-03 | Share viewer page is unbranded | **Fixed.** `web-viewer/index.html` carries the Binary theme tokens with light and dark variants, the logo mark, and a self-hosted `BungeeHairline` font served same-origin (`:12-17`). No Google Fonts request. No third-party script. |
| SA-WEB-04 | Share links minted on a workers.dev host | **Fixed, with follow-up open.** `AppConstants.shareHost` is `share.ciphernest.io` (`frontend/lib/src/config/constants.dart:11`) and the custom domain is live. The fix's own step 2, removing the now-unnecessary CORS header and preflight handler since page and proxy are same-origin, was not done. `web-viewer/README.md:6` still names the dead workers.dev host. |
| SA-WEB-05 | Password shares leak the filename in the URL | **Open.** `fragment.write('&n=${base64Url.encode(utf8.encode(filename))}')` at `frontend/lib/services/share_service.dart:167` is unconditional. It runs in password mode too, where the link is meant to reveal nothing without the password. |

### New web findings

**W-01. A mangled share link puts the decryption key in the request path, where the server sees and logs it. High. ASVS V7 and V8.**

**Status: PARTIALLY FIXED in code on 2026-09-20.** Round 2 added an important mitigating fact: the Worker's invocation logging appears to have been disabled on the account throughout, so the keys this finding warns about were probably never persisted anywhere. That is indicated rather than proven, and it does not change the defect. The Worker now detects `%23` in the path and answers with a 302 to the normalized `#` form before serving anything, so the key stops being re-sent on every subsequent asset request and never reaches the page's own address bar or history. That does not unsend the first request. Deciding what to do about request logging, and whether to re-mint existing shares, is still open and is the reason this stays the top item in section 10.

This is the most severe finding in the assessment, and it falsifies the claim CipherNest repeats most often.

The viewer handles the case where a link handler percent-encodes the fragment marker:

```js
// web-viewer/share.js:65-72
// Some link handlers (WhatsApp Desktop, Messenger, various URL wrappers)
// percent-encode the `#` fragment marker into `%23` so the whole fragment
// ends up embedded in the path. Detect and split.
const encodedHashIdx = path.indexOf('%23');
if (encodedHashIdx >= 0 && !rawFragment) {
  rawFragment = decodeURIComponent(path.substring(encodedHashIdx + 3));
  path = path.substring(0, encodedHashIdx);
}
```

The recovery is correct and the key is never re-sent. The problem is what already happened before that code runs. When the `#` was mangled into `%23`, the fragment was never a fragment. It was part of the path, so the browser sent it in the request line. For a plain share that path contains `k=<the raw 32-byte share key>`.

That request reaches the Worker. `wrangler.jsonc` sets `run_worker_first: true`, so the Worker is invoked for every request including static asset serving, and `observability.enabled: true`, so invocations are recorded in Cloudflare Workers Logs with their URL.

Verified live. A request to `https://share.ciphernest.io/s/QUJD%23k=TESTKEYNOTREAL` is accepted and answered by the edge, which is only possible because the full path reached it.

**Impact.** For any share link that passed through a URL-mangling intermediary, the decryption key for that file was transmitted to Cloudflare and written to a request log. The shared blob is publicly downloadable by design, so key plus blob is the whole file. Anyone with access to those logs, which means the developer and Cloudflare, can decrypt. The privacy policy states that the key "is placed in the part of the link after the `#`, which browsers never send to any server". In this path that is not true, and the code comment names three common intermediaries by which it happens.

Exploitation by an outside attacker is not the concern. The concern is that a zero-knowledge product transmitted key material to its own infrastructure and told users it could not.

**Fix, in order.** First, have the Worker detect `%23` in the path and answer with a 302 to the normalized `#` form before any asset is served, so the key is removed from the URL at the earliest possible point. Second, exclude `/s/*` request URLs from Workers Logs, or disable observability on the share host. Third, treat every share key that could have transited a log within the retention window as disclosed, which in practice means revoking and re-minting existing shares. Only then correct the policy wording.

**Status: OPEN.**

**W-02. No security headers on the share host. Medium. ASVS V14.4.**

**Status: FIXED in code on 2026-09-20.** The Worker now sets a Content Security Policy, HSTS, `nosniff`, `no-referrer`, a Permissions Policy and `frame-ancestors 'none'` on every response it serves. The policy allows exactly one inline script, the OAuth callback page's intent builder, pinned by SHA-256 hash rather than by `'unsafe-inline'`.
`curl -I https://share.ciphernest.io/` returns no `Content-Security-Policy`, no `Strict-Transport-Security`, no `X-Content-Type-Options`, no `Referrer-Policy` and no frame-ancestors control. `worker.js` sets none, and there is no `_headers` file in `web-viewer/`. The marketing site at `ciphernest.io` is configured to an A grade; the share viewer, which is the surface that actually handles ciphertext and keys, has nothing. The page can be framed, its responses can be MIME-sniffed, and there is no CSP to contain a future injection. The page does set `<meta name="referrer" content="no-referrer">`, which is good but is not a substitute.
Fix: add a `_headers` file or set headers in the Worker, with a CSP restricting `script-src` to `'self'`, `frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`, a long HSTS max-age, and `Referrer-Policy: no-referrer`.

**W-03. The proxy is an open CORS bypass for any public file on an allowlisted host. Low. ASVS V13.**
`handleProxy` fetches any URL whose host passes `isAllowed()` and returns it with `Access-Control-Allow-Origin: *` (`worker.js:91-156`). Google Drive hosts arbitrary public files, so any website can use this Worker to read any publicly shared Drive file cross-origin, which the browser same-origin policy would otherwise prevent. Confidentiality of CipherNest shares is unaffected, since the key never reaches the Worker. The exposure is a free relay and a CORS bypass service running at the developer's expense.
Fix: implement the remaining SA-WEB-01 steps. The magic-byte check is the highest-value one, because it reduces the Worker to relaying CipherNest ciphertext only.

**W-04. The decryption key persists in the recipient's browser history. Low. ASVS V8.**
`share.js` reads the key from `location.hash` and never scrubs it. The fragment stays in the address bar, in session history, and in the browsing history of a browser that syncs. Fragments are never sent to a server, so this is a client-side residue issue rather than a transmission one.
Fix: call `history.replaceState` to strip the fragment immediately after reading it into memory.

**W-05. No subresource integrity on the bundled Argon2 module. Info. ASVS V14.2.**
`web-viewer/index.html:206` loads `/hash-wasm.min.js` with no `integrity` attribute. The file is self-hosted and same-origin, so the practical risk is low and SRI would mainly defend against a compromise of the asset store itself. Worth adding because it is free.

**Verified clean on the web side.** The viewer escapes all untrusted text before insertion: the filename from the fragment goes through `escapeHtml` at `share.js:408`, as do status and error messages at `:519,524`. The filename is additionally stripped of path separators and capped at 255 characters at `:110`. There is no `localStorage`, `sessionStorage`, `eval`, or `document.write`. The key is never placed in a query string, a POST body or a console log. Decryption happens entirely in `SubtleCrypto`, with Argon2id parameters that match the Dart sender byte for byte (`share.js:39-44`). The `auth.ciphernest.io` host restriction works as designed and was verified live: `/oauth-callback` and the two logo assets return 200, and `/`, `/share.js` and everything else return 404. The OAuth callback page builds its `intent://` URL by concatenating `location.search`, which cannot contain a raw `#`, so the `Intent` parameter block cannot be injected through a crafted callback URL. All four `.well-known` files return 200, and `assetlinks.json` carries both the debug and upload certificate fingerprints.

## 7. Dynamic verification results

Run on 2026-09-20 against the installed shipped build, hash `832e059d`, on a Samsung SM-A556E running Android 16.

| # | Test | Outcome |
|---|---|---|
| 1 | Recents thumbnail exposure | Complete. Confirms F-06 |
| 2 | Plaintext on disk after a session | Complete. Confirms F-01 |
| 3 | Preferences and database contents | Complete. Confirms F-04, F-11, F-14, F-15, F-21 |
| 4 | Release logging | Complete. Confirms F-12, with a refinement |
| 5 | Loopback server reachable cross-uid | Complete. Confirms F-03 |
| 6 | Keystore refuses without authentication | Complete, round 2. Enrolment invalidation works |
| 7 | Screen capture coverage | Complete. Confirms F-05, corrects one claim |
| 8 | Residue after share, open, print | Complete, round 2. Confirms F-07 |
| 9 | Clipboard contents | Complete, round 2. Confirms F-10 |
| 10 | Media session disclosure | Complete. Confirms F-18 |
| 11 | Exported component probing | Complete. Confirms F-08 and the PLATFORM-1 surface |
| 12 | TLS interception | Not run. Tooling lacked the decryption feature |
| 13 | Traffic inventory | Complete, round 2. Refines F-22 |
| 14 | Link mangling through messaging apps | Inconclusive. Logging was off at the time |
| 15 | Device-to-device transfer | Partial. Backup eligibility read; transfer not tested |
| 16 | Anonymous share link sender identity | Complete for Drive. OneDrive blocked by a product bug |
| 17 | GPS EXIF across upload paths | Not run |
| 18 | OAuth relay under R8 | Not run |

Two findings were discovered during this pass rather than confirmed by it: F-32 and F-33. Both came from the operator noticing the vault would not lock.

### What the completed tests showed

**1. Recents.** The task switcher card was captured three times: from the gallery grid, from a fullscreen decrypted photo, and from the recovery phrase screen. All three rendered in full. Nothing blanks the window on background.

**2. Plaintext on disk.** Read through the instrumented variant, which was never launched, so every artefact was written by the shipped build:

```
video_1kHY9OgqwCkAMw8EQfyFXKwWrjZ-LX9WI.plain   8733449   ID3v2 MP3, plaintext
video_1N5J4CpDWz_tlruyQVK9ZNuLsPrzCnbJ3.plain   3722316   ID3v2 MP3, plaintext
thumb_1azM30v8VPZBAhI5VE-h_CJXZ7_VYSMwU.jpg       13007   JPEG, plaintext
cache total                                          19M
```

These survived `am force-stop`, so they persist across process death with no key in memory. File names here are cloud identifiers rather than user filenames. The paths that embed the original filename are in the export and document-open flows, which were not exercised.

**3. Preferences and database.** The database pulled cleanly and opened on a workstation with no key: header `SQLite format 3`, 73 files, 9 folders, 3 albums, 1 share, 148 sync operations. All 73 files carry readable filenames, 54 carry absolute local paths, and 108 operations retain a name, including deletions and purges. The `shares` row holds a 266-character URL whose `k=` parameter decodes to 32 bytes with `has_password = 0`. Preferences held `seed_blob_v1` with its salt, nonce and tag, a second complete `mnemonic_pw_blob_v1` set, `auto_sync_deleted_keys` carrying a filename and an exact byte size, and `entitlement_plus_v1` as a plain boolean set to true.

**4. Logging.** 146,944 lines captured across a full session, of which 16 came from the app. See F-12 for why that result cuts both ways.

**5. Loopback server.** The sharpest result in the assessment. From uid 2000, which is not the app's uid 10434, using the device's own `toybox nc`:

```
HTTP/1.1 206 Partial Content
x-powered-by: Dart with package:shelf
content-length: 8733449
content-type: audio/mpeg
content-range: bytes 0-8733448/8733449
```

The body was a complete ID3v2-tagged MP3 whose embedded title was readable. No credential was presented. The server also ignored the supplied `Range` header and returned the entire file.

**7. Screen capture.** Every screen tested captured in full: gallery grid, fullscreen photo, Active Shares, and the recovery phrase screen. The OS screenshot key then wrote 102,852 bytes to `DCIM/Screenshots` while the mnemonic was displayed, putting the vault's master secret into the device gallery where a photo backup would sync it. That file was deleted from the device immediately, a MediaStore rescan was requested, and the tester's own unblurred capture was destroyed. Only a heavily blurred frame was retained as evidence, and the screenshot's contents were never opened.

**10. Media session.** With a vault track playing, `dumpsys media_session` reported `metadata: size=6, description=A song, Unknown, Tracks`. The real track title and queue name are published to the system media session by default, so they reach the lock screen, paired displays and any notification listener.

**11. Exported components.** Both OAuth entry points accepted intents from an unprivileged external caller. `ciphernest-open://x?code=forged` was delivered to `MainActivity`, and `ciphernest://oauth-callback?code=forged` started `CallbackActivity` with no package pin. Neither validates its caller. The share-link probe is covered under F-08.

### What the partial tests showed

**6. Keystore.** The biometric wrap's stored backing value was read as `tee`, so on this device StrongBox was unavailable and the documented fallback took effect. That is correct behaviour, and it means any public claim of StrongBox protection would be wrong for this hardware class. The enrolment-change test, which is the one that proves `setInvalidatedByBiometricEnrollment` actually fires, was not performed.

**8. Residue.** Public storage was counted before and after the session and was unchanged: DCIM/Camera 453, Download 333, Pictures 12, Movies 3, Documents 20. Nothing was written outside the sandbox by the app. Three filenames matched a CipherNest-shaped grep, and all three are the operator's own pre-existing downloads, not app output. The share-out and document-open paths were not exercised, so the part of F-07 that matters most is untested.

**15. Device-to-device transfer.** The platform reports the app as not a backup participant at all, which confirms `allowBackup="false"` excludes it from cloud backup. Device-to-device runs through a separate transport, `com.google.android.gms/.backup.migrate.service.D2dTransport`, which only engages during a new device's setup wizard. That was not tested.

### What was not run, and why

**9. Clipboard.** Dropped deliberately. Reading the stored share row proves the same claim more directly and cost the operator fewer steps. The code path at `view_phrase_screen.dart:168` is unambiguous.

**12 and 13. TLS interception and traffic inventory.** Not run, and deliberately not approximated. No interception tooling is installed, and the usual workaround fails on this stack: Dart's HTTP client does not follow the Android system proxy, so a proxy-based capture would record the native traffic and silently miss every Drive and Graph call. That produces a clean-looking result which cannot fail, and that is worse than no result. Doing this properly requires root or a VpnService capture app. Until then MASVS-NETWORK-1 remains static only.

**14. Link mangling.** Requires sending links through the operator's own messaging accounts and then reading Cloudflare's logs. Not performed. W-01's mechanism is proven from the code and from a live request. What remains unmeasured is how often real intermediaries trigger it, which determines how many existing share keys should be treated as disclosed.

**16. Anonymous share sender identity.** Requires opening a live share link in a signed-out browser and inspecting the provider's own item page. Not performed.

**17. GPS EXIF.** Requires a geotagged photo added by two different paths and compared after export. Not performed, so F-30 stays static.

**18. OAuth relay under R8.** Requires a full OneDrive sign-out and sign-in on the shipped build. Not reached. This one matters more than its position suggests. `MainActivity.relayOAuthReturn` reaches a plugin static field, R8 does run on release builds, and `proguard-rules.pro` contains no keep rules. The path fails closed and silently, so it should be exercised on every release.

### Round 2, run by the developer on 2026-09-21

The device pass continued against the fixed build for tests that the fixes do not touch.

**6. Keystore enrolment invalidation works.** Adding a fingerprint in Android settings caused the app to refuse biometric unlock with "Your device security settings changed" and fall back to the master password. `setInvalidatedByBiometricEnrollment(true)` fires as intended. Two nuances were observed and neither is a defect: an already-unlocked session stays unlocked until it is closed, because invalidation destroys the key rather than the running session, and removing a fingerprint did not invalidate. The removal case is worth a follow-up, along with the untested cases of removing every fingerprint and of a device with none enrolled.

**9. Clipboard confirms F-10.** The full twelve-word phrase pasted into another app. It remained in Samsung's clipboard history afterwards, for as long as any other entry. Android showed no sensitive-content indicator, which is the `EXTRA_IS_SENSITIVE` flag the app does not set. The copied share link contained its `#k=` key.

**8. Residue confirms F-07, including the filename leak.** After sharing a photo out and opening a document, the cache held both copies in the clear:

```
cache/A document.docx                                       23341   ZIP/OOXML, plaintext
cache/share_plus/pexels-david-atkins-...-6337789.jpg       708639   JPEG, plaintext
```

Both are named after the user's original filename, which is the specific defect F-07 describes at `documents_screen.dart:180` and in the export path. Both were still present minutes after the sharing and opening had finished, so nothing deletes them on completion. Public storage was counted again and remains unchanged from the round 1 baseline, so the leak is confined to app-private storage and the deliberate handoff.

One incidental confirmation of an earlier fix. No `.plain` video caches remained, and the cache had fallen from 19 MB to 4.9 MB, so the purge-on-lock added for F-01 and F-02 is doing its job on the paths it covers. It does not cover these two, because they are written by the handoff code rather than by the streaming cache.

**13. Traffic inventory, and a refinement to F-22.** Captured with PCAPdroid, filtered to this app. Roughly 68 connections, all to `www.googleapis.com` over TLS on 443, plus DNS. A OneDrive sign-in added `graph.microsoft.com`, `login.microsoftonline.com` and `my.microsoftpersonalcontent.com`. Nothing else appeared.

Two things follow. No Google Fonts host was contacted, which confirms at runtime that the unused `google_fonts` dependency never fetches, so the privacy claim holds. And `auth.ciphernest.io` did not appear, because the OAuth callback loads in Chrome rather than in the app. That matters for the wording of F-22: the policy sentence "the app does not contact any server operated by me" is literally accurate. The disclosure gap is that the sign-in flow the app starts causes the user's browser to contact it, and that host sees the authorization code and the IP address. The fix is a disclosure, not a correction.

`my.microsoftpersonalcontent.com` was not previously in any inventory. It is a Microsoft content host and it is not on the Worker's proxy allowlist.

**12. Interception not run.** The capture tool on the device offered no TLS decryption option, so no certificate was installed and no interception was attempted. Full-payload capture showed TLS records only. MASVS-NETWORK-1 therefore remains static only.

**14. Link mangling inconclusive, and W-01 is probably smaller than written.** No requests appeared in the Worker's logs, because invocation logging was not enabled on the account at the time. If logging was off for the whole life of the share feature then no share key was ever persisted, and W-01's disclosure half never happened. That has not been proven, only strongly indicated, and it does not change the code defect.

**16. Share link identity, and a product bug.** A Google Drive share revealed nothing about the sender. Opening the decoded Drive URL while signed out simply downloaded the encrypted file, with no name, email or profile picture anywhere. That closes the question for Drive.

The OneDrive case could not be tested, because the share does not work at all. Opening a OneDrive share link as an anonymous recipient redirects to `login.live.com` and returns a sign-in page instead of the file. The viewer reports the HTML interstitial correctly. The cause is in `onedrive_provider.dart`, which builds the recipient URL by appending `?download=1` to the `1drv.ms` link returned by `createLink`. That does not produce an anonymous direct download. This is a functional defect rather than a MASVS finding, but it means the sharing feature is broken for every OneDrive user, and it is tracked outside this report.

## 8. Known gaps and accepted risks

These are stated rather than fixed. Each is a deliberate position or a limit of this assessment.

**The cloud provider learns a great deal of metadata.** The vault folder is visible rather than hidden, which is a deliberate portability choice matching Cryptomator, and it carries a plaintext `README.txt` naming the product. The provider can therefore see that the user runs CipherNest, how many files exist, their exact plaintext sizes, which blob is a thumbnail of which file, how many devices sync, each device's per-install UUID in the log object names, and the timing and volume of every session. File contents, names and folder structure remain sealed. The security page discloses the general shape of this; the privacy policy understates it.

**Share links are bearer tokens.** Anyone who obtains a plain share link can decrypt that file. Expiry is advisory until the sender's app runs the sweep. Revocation is deletion of the blob, not a cryptographic operation, and a recipient who already downloaded keeps their copy. This is inherent to a link that works in a browser with no account.

**MASVS-RESILIENCE is not implemented, by choice.** No root detection, no debugger detection, no emulator detection, no attestation, and no anti-tampering. The code is public under GPL-3.0 and the security model does not depend on secrecy. These are MAS-R controls and not required at L2. R8 shrinking and Java obfuscation do run; Dart obfuscation does not, and that is the half where the security logic lives. See F-17.

**Memory is not zeroized, and cannot be fully.** Dart strings are immutable, so passwords held as `String` cannot be overwritten. Seed byte buffers are explicitly zeroed after use (`key_manager_service.dart:249,261,368,415,448`), and the seed crossing the method channel is zeroed on the Kotlin side, but the channel codec's own buffers are beyond reach. This is documented in the source and is a platform limitation, not an oversight.

**An unlocked device in someone else's hands loses everything.** Nothing in the app defends against that, and F-13 makes it faster than it should be. The device pass made this worse rather than better: F-32 and F-33 together mean the user cannot close the vault at all once any media has been opened, so "unlocked" is the steady state rather than a window.

**The biometric wrap does not strengthen the password.** It is an alternative path to the same seed, hardware-bound and correctly implemented. The password blob remains the weaker root of trust, and F-15 describes why.

**Billing is unbuilt.** No RevenueCat integration exists. The entitlement is a local boolean (F-21 and `subscription_service.dart:42`), which anyone with root can set. That is a revenue risk, not a user-security risk, and it must be resolved before the paywall is enabled for real users.

**Legacy uploads keep plaintext names in cloud metadata** until the user runs the migration from Settings. New installs are unaffected.

## 9. What this assessment does not cover

**It is a self-assessment, not an independent audit.** It was performed by the developer of the application, assisted by automated analysis. It has not been reviewed by any external party. A self-assessment cannot substitute for an independent audit, and the results should be read with the author's interest in mind. An application for funded independent review is in progress.

**Dynamic testing was partial.** A device pass was run on one handset, and section 7 records exactly which tests produced a result and which did not. Seven produced nothing. The gaps are not evenly distributed: they fall hardest on the network and privacy controls, which is why every PASS in this report is still marked static only. No finding here was contradicted by the device, but absence of contradiction across eleven tests is not the same as verification across eighteen.

**One device, one Android version.** All dynamic results come from a Samsung SM-A556E on Android 16. Behaviour that varies by manufacturer or API level was not sampled. The StrongBox fallback observed here is one concrete example: this device has no StrongBox, so the code took its TEE path, and hardware that does have StrongBox was not exercised.

**No penetration test and no fuzzing.** Reverse engineering was limited to string and symbol inspection of the shipped binary. No instrumentation with Frida or Objection, and no attempt at runtime hooking or memory inspection. Two findings were exercised to the point of proof, F-03 and F-08, because both were reachable with ordinary platform tooling and neither required modifying the app. Nothing else was exploited.

**No cryptographic proof.** The primitives are standard and correctly parameterized as far as source review can establish, and the HPKE implementation states that it is pinned to the RFC 9180 A.1 test vectors. Those vectors were not executed during this assessment. The construction as a whole has not been formally analysed or independently reviewed by a cryptographer.

**No dependency vulnerability scan.** See F-26. No dependency was checked against any advisory database.

**Android only.** There is no iOS build.

**Out of scope by design:** the security of Google Drive and OneDrive, the security of the user's cloud account credentials, the Android platform itself, the device firmware, malicious OEM software, and any adversary with root on a running device while the vault is unlocked.

**The MASTG test IDs cited** indicate which procedure a finding corresponds to. The full MASTG procedures were not each executed as written; findings were reached by direct code and binary review and then mapped to the relevant test.

## 10. Remediation priority

Suggested order, by impact per unit of work rather than by severity alone.

**Immediately, before any further share links are created:**

1. W-01. Normalize `%23` at the edge, stop logging `/s/*` URLs, and treat keys that could already be in the log window as disclosed. This is the only finding where key material left the device to a third party, and it is the only one that makes a published claim untrue rather than incomplete.

**Before a closed test with real users:**

2. F-05 and F-06, screen protection. A window-level `FLAG_SECURE` plus a pause cover is a small change that closes two High findings, both now device-verified. The recovery phrase screen is the urgent one: the OS screenshot key put the master secret into the device gallery during testing.
3. F-33 and F-32 together, the lock. End the streaming session on pause, and add a manual lock control. Today the vault cannot be closed at all once media has played, which makes every other storage finding permanent for the life of the process.
4. F-09, one line, removes a path by which the master recovery phrase reaches a third-party keyboard.
5. F-03, add a session token and call `stop()` on lock. The device pass pulled a complete decrypted track from this endpoint with no credential.
6. F-01 and F-02, add an age-based cache sweep and purge on lock.
7. F-08, validate the share link's download URL against the Worker's allowlist. Proven exploitable on the device.
8. F-12, at minimum stop logging the streaming port and file identifier. Those two lines are what make F-03 reachable in practice.
9. F-27, add data extraction rules so `allowBackup="false"` means what the comment says it means.
10. F-22, correct the privacy policy before it is cited in a store listing, and answer Data Safety against the shipped build.

**Before public release:**

11. F-04, stop persisting share URLs. The device pass read a live 32-byte content key straight out of the database.
12. F-28, make share revocation reliable and reconcilable.
13. F-07, delete materialized plaintext after handoff and scope the `open_file` provider.
14. F-12, gate the remaining logging behind `kDebugMode`.
15. F-14, pass `encryptedSharedPreferences: true`.
16. F-16, fail the build instead of falling back to the debug key.
17. F-13, require re-authentication to create a share link.
18. W-02, add security headers to the share host.

**Next release:**

19. F-11, encrypt the metadata database.
20. F-15, bind the seed blob to the Keystore and raise the password ceiling.
21. F-20, F-21, F-23, data lifecycle and user control.
22. F-29, F-30, metadata side channels and EXIF consistency.
23. F-17, F-19, F-24, F-25, F-26, F-31, build and platform hygiene.
24. W-03 through W-05, and the remaining SA-WEB-01 steps.

**Verification debt to clear alongside the fixes.** Seven planned tests produced no result. Three of them cover controls this report currently marks PASS on static evidence alone, which means those passes are unproven: tests 12 and 13 for MASVS-NETWORK-1, and test 18 for MASVS-AUTH-1. Clearing that debt needs a VpnService capture app or a rooted test device, and a full OAuth round trip on a release build. Until then, treat the five passing controls as claims rather than results.

## Revision history

| Date | Version | Change |
|---|---|---|
| 2026-09-20 | 1.0 | Initial assessment at commit `c43cd1a`, static and binary only. |
| 2026-09-20 | 1.1 | Device pass on a Samsung SM-A556E, Android 16, against the installed shipped build. Eight tests complete, three partial, seven not run. Added F-32 and F-33, both found during testing. Corrected the F-05 claim about the Active Shares screen. Corrected F-17, which had reported R8 as disabled. Added evidence markers throughout and a statement that all five passing controls remain unverified at runtime. |
