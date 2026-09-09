# CipherNest — A Guided Tour of the Code

> A plain-language walkthrough of your own codebase, written for someone who has
> seen Flutter once and wants to actually understand what they're shipping.
> We start at the very outside (the repository root) and slowly move inward.
> This document grows in **entries**. This is **Entry 1: everything *around* the
> app** — the repo layout, the little config files, and the whole Cloudflare
> "web viewer" that decrypts shared files in a browser. The app itself
> (`frontend/`) is the next entries.

---

## 0. How to read this document

You are going to look at a lot of code you didn't type by hand. That's normal —
you *designed* it, and every line here exists because of a decision you made.
The goal of this file is that when an investor, a professor, or a future
employer points at any file and asks "what is this and why is it here?", you can
answer without hesitating.

A few conventions I'll use throughout:

- When I show a chunk of code, I'll quote it **exactly** as it appears in your
  repo, then explain it line-by-line underneath. I never invent code that isn't
  there.
- I'll explain the *language* as I go (Dart for the app, JavaScript for the web
  viewer), because knowing "what does `async` mean" matters as much as knowing
  "what does this function do."
- **"Where it sits / what it does / why it's needed / what it links to"** is the
  four-part shape I try to give every piece.

### The two halves of CipherNest

CipherNest is really **two programs** that speak the same secret language:

1. **The Android app** (everything in `frontend/`). This is the real product.
   It encrypts your photos/videos/documents/music *on the phone* before they go
   to Google Drive or OneDrive, and decrypts them when you look at them. Written
   in **Flutter/Dart**.

2. **The web viewer** (`web-viewer/` + `worker.js` + `wrangler.jsonc`). This is
   a tiny website hosted on Cloudflare. Its only job: when you share an
   encrypted file with someone who doesn't have the app, they open a link and
   this website decrypts the file **in their browser**. Written in plain
   **HTML + JavaScript**, no app required.

The thing that makes both "zero-knowledge" is: **the decryption key never
reaches any server.** In the app, the key lives on your phone. In the web
viewer, the key rides in the part of the URL *after the `#`* — and browsers, by
web standard, never send the part after `#` to the server. So Cloudflare (and
Google, and OneDrive) only ever see an unreadable encrypted blob.

That single idea is why this project is a credible cybersecurity portfolio
piece, and you'll see it echoed in almost every file.

### The chronological plan for later entries

You asked to be walked through `frontend/` in the order the app was actually
built. Here's the roadmap (each becomes its own entry appended below, when you
say "continue"):

- **Entry 2 — Crypto foundation.** The math and the keys: `lib/crypto/`,
  `encryption_service.dart`, `key_manager_service.dart`, `share_service.dart`,
  `device_identity_service.dart`.
- **Entry 3 — Auth & cloud APIs.** Signing into Google and Microsoft, talking to
  Drive/OneDrive: `services/cloud/` and the auth screens.
- **Entry 4 — Sync, upload, and the services layer.** The machinery:
  `services/sync/`, `upload_pipeline.dart`, `auto_sync_*`, caching, thumbnails,
  the local video-streaming server, audio.
- **Entry 5 — Screens, config, models, state, widgets.** The user interface and
  how navigation/theming/data-shapes work.
- **Entry 6 — The SQLite database.** How metadata is stored, versioned, and
  recycled: `database_service.dart`, recycle bin, DB backup.
- **Entry 7 — Android platform features.** The native Kotlin bits: biometric
  unlock, notifications, the upload foreground service, App Links, deep-link
  relay.

---

## 1. The repository root — a map

When you open `E:\CipherNest\`, here's what's there and what each thing is for.
Think of this as the table of contents for the whole project.

```
E:\CipherNest\
├── frontend/                     ← THE ANDROID APP (Flutter/Dart). Entries 2–7.
├── web-viewer/                   ← The browser share-decryptor (HTML/JS website).
├── worker.js                     ← Cloudflare "Worker": server-side glue for the website.
├── wrangler.jsonc                ← Config telling Cloudflare how to deploy the website.
├── .wrangler/                    ← Local cache created by Cloudflare's CLI tool. Ignorable.
├── docs/                         ← Pitch deck, proposal, pricing, progress report (Word/PDF).
├── temp/                         ← Scratch: design-reference screenshots. Not shipped.
├── .claude/                      ← Settings for the Claude Code assistant. Local-only.
├── .vscode/                      ← Editor (VS Code) settings. Local-only.
├── .git/                         ← Git's own storage of your history. Never touch by hand.
├── .gitignore                    ← List of things git should NOT track.
├── CLAUDE.md                     ← Project brief for the AI assistant. Local-only.
├── README.md                     ← The public "what is this project" description.
├── web-viewer.zip                ← A zipped copy of web-viewer/ for manual upload. Generated.
└── CipherNest-v1.0.0-beta.apk    ← The installable app file you share with testers.
```

The mental split again: **`frontend/` is the app**; **`web-viewer/` +
`worker.js` + `wrangler.jsonc` are the website**; everything else is either
git/editor/AI tooling (`.git`, `.vscode`, `.claude`, `.gitignore`, `CLAUDE.md`),
business paperwork (`docs`, `README.md`), scratch (`temp`), or build output
(`web-viewer.zip`, the `.apk`).

### What is an `.apk`, and why is it sitting in the root?

An **APK** ("Android Package Kit") is the single file Android installs to put an
app on a phone — the Android equivalent of a `.exe` installer on Windows.
`CipherNest-v1.0.0-beta.apk` is the *build output* of the Flutter app: the whole
`frontend/` project compiled down into one 109 MB file you can hand to a tester
("sideload") or drop in Drive. It isn't source code; it's the *result*. It's the
shareable copy we keep refreshing so it matches what's on your phone.

---

## 2. `.gitignore` — the "do not track" list

**Where it sits:** repo root. **What it does:** tells **git** (your version-
control system, the thing that records every change and lets you go back in
time) which files to *ignore* — never save into history, never upload when you
push to GitHub.

Here's the whole file:

```gitignore
# Build artefacts produced when packaging the static web viewer for upload.
# The source lives in web-viewer/ — the zip is generated on demand.
web-viewer.zip
docs/

# Local design references / scratch files.
temp/

# Local-only context files — never publish.
CLAUDE.md
CLAUDE_CODE_PROMPT.md
.claude/
.wrangler/
```

Reading it top to bottom:

- **`web-viewer.zip`** — this is *generated* from `web-viewer/`, so tracking it
  would just be a duplicate that goes stale. The *source* (`web-viewer/`) is
  tracked; the zip is not.
- **`docs/`** — your pitch deck, pricing strategy, and progress report. Business
  documents, not code, and some are drafts you may not want public.
- **`temp/`** — scratch screenshots you use as design references. Throwaway.
- **`CLAUDE.md` / `CLAUDE_CODE_PROMPT.md` / `.claude/`** — instructions and
  settings for the AI assistant. Local to your machine; no reason to publish.
- **`.wrangler/`** — a cache folder Cloudflare's command-line tool creates. Pure
  machine-generated junk.

**Security angle worth saying out loud in an interview:** notice what's *not*
here — there's no `key.properties`, no secrets file, no `.env`. That's because
CipherNest is zero-knowledge: there are no server-side secrets to leak. The one
thing you'd want to add before open-sourcing is your Android **release signing
keystore** (the private key that proves an APK is really from you) — that must
*never* be committed. Right now the app is debug-signed, so there's no keystore
in the repo yet; when you make one, its `.jks` file and its passwords go into
`.gitignore` immediately.

> **Note:** the `.apk` itself is *not* in `.gitignore`, which is why the 109 MB
> file is tracked. That's a choice — fine for a beta you want in the repo, but
> most teams keep large binaries out of git (they bloat history forever). Worth
> revisiting before you publish the repo.

---

## 3. `.vscode/` and `.claude/` — your local tooling

These two folders configure the *tools you use to work on the project*, not the
project itself. Nothing in them ships to users.

### `.vscode/settings.json`

**VS Code** is the code editor you're (likely) using. This file customizes it
for this project:

```json
{
    "cmake.sourceDirectory": "E:/CipherNest/frontend/linux"
}
```

`cmake` is a build system used by C/C++ programs. Flutter's **Linux desktop**
target is built with cmake, and this line just tells the editor's cmake
extension where that project lives (`frontend/linux`). You ship Android, not
Linux desktop, so this is essentially a harmless leftover from Flutter creating
all the desktop scaffolding by default. Safe to ignore.

### `.claude/`

This holds settings for **Claude Code**, the AI assistant. Two files:

- **`settings.local.json`** — a permission allowlist. It's what lets the
  assistant run certain commands without asking you every single time:

  ```json
  {
    "permissions": {
      "allow": [
        "PowerShell(flutter test *)",
        "PowerShell(git fetch *)",
        "PowerShell(Select-String *)",
        "PowerShell(git *)",
        "WebFetch(domain:ciphernest.ciphernest20.workers.dev)",
        "PowerShell(flutter build *)",
        "PowerShell(Set-Content *)"
      ]
    }
  }
  ```

  Each entry is a pattern of commands pre-approved to run (e.g. any
  `flutter build …`, any `git …`). The `*` is a wildcard. Note the `WebFetch`
  line — that's your live Cloudflare Worker URL,
  `ciphernest.ciphernest20.workers.dev`, which is the deployed web viewer we'll
  discuss next.

- **`scheduled_tasks.lock`** — a lock file the assistant uses internally to
  avoid two scheduled jobs colliding. Machine-managed; you never edit it.

Both are git-ignored, local to your machine, and irrelevant to the shipped
product.

---

## 4. The Cloudflare web viewer — the "magic link" story

This is the most interesting non-app part of the repo, and the piece that best
demonstrates the zero-knowledge design. Let's build up the whole picture.

### 4.0 The problem it solves

You've encrypted a photo and it lives on Google Drive as gibberish. You want to
send it to a friend who **doesn't have CipherNest**. You can't just send them
the Drive link — they'd download gibberish. You need a way for them to decrypt
it *without installing anything and without any server ever seeing the key.*

The solution is a **"magic link"**: a URL that contains, in its `#` fragment,
the key to decrypt this one file. When your friend opens it, a tiny website
(this web viewer) runs *in their browser*, fetches the encrypted blob, and
decrypts it locally. Cloudflare hosts the website but never sees the key.

A magic link looks like this (from `web-viewer/README.md`):

```
https://ciphernest.pages.dev/s/<base64UrlEncodedDownloadUrl>#k=<shareKey>&exp=<unixMs>
```

- `/s/<…>` — the path. The `<…>` is the Drive/OneDrive download URL, encoded so
  it survives being stuffed into another URL.
- `#k=<shareKey>&exp=<unixMs>` — the fragment. `k=` is the decryption key;
  `exp=` is an expiry timestamp. **This part never leaves the browser.**

### 4.1 `wrangler.jsonc` — how Cloudflare is told to deploy this

**Wrangler** is Cloudflare's command-line tool for deploying "Workers" (small
programs that run on Cloudflare's edge servers). This file is its config.
`.jsonc` means "JSON with comments allowed."

```jsonc
{
  "$schema": "node_modules/wrangler/config-schema.json",
  "name": "ciphernest",
  "main": "./worker.js",
  "compatibility_date": "2026-07-05",
  "compatibility_flags": ["nodejs_compat"],
  "assets": {
    "directory": "./web-viewer",
    "binding": "ASSETS",
    "not_found_handling": "single-page-application"
  },
  "observability": {
    "enabled": true
  }
}
```

Line by line:

- **`name: "ciphernest"`** — the project name on Cloudflare; it's why your live
  URL contains `ciphernest`.
- **`main: "./worker.js"`** — the server-side program to run is `worker.js`
  (next section).
- **`compatibility_date` / `compatibility_flags`** — pins the runtime behavior
  to a specific date, and turns on Node.js compatibility features. Standard
  boilerplate for stability.
- **`assets`** — the key part. It says: the static files (HTML, JS) live in
  `./web-viewer`, expose them to the Worker under the name `ASSETS`, and if a
  requested path isn't found, fall back to serving the single-page app
  (`index.html`). That "single-page-application" fallback is what makes
  `/s/anything` still load `index.html`.
- **`observability`** — turns on logging/metrics so you can see traffic in the
  Cloudflare dashboard.

### 4.2 `worker.js` — the server-side CORS proxy

**Where it sits:** repo root. **What it does:** it's the *only* server-side code
in the whole share system, and it does exactly one job — act as a **CORS proxy**
so the browser can fetch the encrypted blob from Google/OneDrive.

**Why it's needed (the "CORS" problem):** browsers have a security rule called
*CORS* (Cross-Origin Resource Sharing). A website at `ciphernest.pages.dev` is
not allowed to fetch files from `drive.google.com` unless Google explicitly
says "this website may read my responses." Google doesn't say that for raw file
downloads. So the browser refuses. The fix: route the request through *our own*
server (`worker.js`), which fetches the file and re-serves it *with* the
permission header attached. The Worker sees only encrypted bytes, so this leaks
nothing.

Here's the heart of it — the entry point:

```javascript
export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === '/proxy') {
      if (request.method === 'OPTIONS') return corsPreflight();
      if (request.method === 'GET') return handleProxy(url);
      return new Response('Method not allowed', { status: 405 });
    }

    // Everything else: static assets. SPA fallback handled by
    // wrangler.jsonc's assets.not_found_handling.
    return env.ASSETS.fetch(request);
  },
};
```

Syntax and meaning:

- **`export default { … }`** — JavaScript's way of saying "this object is the
  thing this file provides." Cloudflare looks for an object with a `fetch`
  function and calls it on every incoming request.
- **`async fetch(request, env)`** — the function that runs per request.
  `request` is the incoming HTTP request; `env` is the environment, which
  includes that `ASSETS` binding from the config. `async` means the function can
  `await` (pause for) slow operations like network calls.
- **`new URL(request.url)`** — parses the request's URL into parts (`pathname`,
  `searchParams`, etc.). `URL` is a built-in browser/JS helper.
- The `if (url.pathname === '/proxy')` block: if someone asks for `/proxy`, we
  handle it ourselves. An `OPTIONS` request is the browser's "pre-flight"
  permission check → answer with CORS headers. A `GET` → actually fetch the
  file. Anything else → "405 Method not allowed."
- **`return env.ASSETS.fetch(request)`** — for every other path, just serve the
  static file from `web-viewer/`. This is how `index.html`, `share.js`, etc. get
  delivered.

The allowlist right above it is a **security hardening** measure — it stops your
proxy from being abused to fetch *arbitrary* websites (an "open relay"):

```javascript
const ALLOWED_HOSTS = new Set([
  'drive.google.com',
  'drive.usercontent.google.com',
  'www.googleapis.com',
  'docs.google.com',
  'lh3.googleusercontent.com',
  'onedrive.live.com',
  '1drv.ms',
  'api.onedrive.com',
  'graph.microsoft.com',
]);

const ALLOWED_HOST_SUFFIXES = [
  '.sharepoint.com',
  '.dropbox.com',
  '.dl.dropboxusercontent.com',
];

function isAllowed(host) {
  if (ALLOWED_HOSTS.has(host)) return true;
  for (const suffix of ALLOWED_HOST_SUFFIXES) {
    if (host.endsWith(suffix)) return true;
  }
  return false;
}
```

- **`new Set([...])`** — a `Set` is a collection with fast "is X in here?"
  checks (`.has(host)`). Used for exact hostnames.
- The suffix list handles hosts where the prefix varies (every Dropbox user
  gets their own `something.dropbox.com`), so we match by ending.
- `isAllowed(host)` returns `true` only for hosts we recognize. Any other host →
  the proxy refuses with 403. This is the anti-abuse guard.

Then `handleProxy` does the actual fetch. Two clever touches worth calling out
because they're the kind of thing a reviewer will ask about:

```javascript
const upstream = await fetch(parsed.toString(), {
  method: 'GET',
  redirect: 'follow',
  headers: {
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
      '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    Accept: '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
  },
});
```

- **The fake Chrome User-Agent.** Google Drive serves *different content* to
  programs than to browsers — if it thinks a robot is asking, it may return a
  sign-in HTML page instead of the file. Pretending to be Chrome sidesteps that.
  (This is a pragmatic hack, documented in the comment, not a security hole.)

```javascript
if (upstreamContentType.includes('text/html')) {
  const buf = await upstream.arrayBuffer();
  const bytes = new Uint8Array(buf, 0, Math.min(400, buf.byteLength));
  debugSnippet = new TextDecoder('utf-8')
    .decode(bytes)
    .replace(/[\r\n]+/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .slice(0, 300);
  bodyToReturn = buf;
}
```

- **The HTML sniff.** If Drive returns an HTML page (a virus-scan warning, a
  sign-in wall, "access denied") instead of the real encrypted bytes, this grabs
  the first 300 characters of that page and attaches them to a debug header, so
  the browser side can tell the user *what actually went wrong* instead of a
  useless "decryption failed." A nice diagnostics-for-your-future-self move.

And the response headers it sets:

```javascript
headers.set('Access-Control-Allow-Origin', '*');   // the CORS permission
headers.set('Cache-Control', 'no-store');           // don't cache encrypted blobs
```

- **`Access-Control-Allow-Origin: *`** — this is the whole point: it's the
  "any website may read this response" permission that Google wouldn't give but
  we now add ourselves.
- **`Cache-Control: no-store`** — tells Cloudflare's edge not to keep a copy.
  The blobs are already encrypted, so caching wouldn't leak anything, but "don't
  hold user data you don't need to" is good hygiene.

### 4.3 `web-viewer/index.html` — the page shell

**Where it sits:** `web-viewer/index.html`. **What it does:** the visible page
your recipient sees — a dark card that says "Decrypting in your browser" with a
spinner, a hidden password box, a preview area, and Download/Open-in-app
buttons. **What it links to:** it loads `share.js` (the brain) and
`hash-wasm.min.js` (a crypto helper).

The `<body>` is mostly a static layout with elements that JavaScript will show
or hide. The genuinely instructive part is the very bottom, where scripts load,
because the comments there encode two real bugs you already hit and fixed:

```html
<!--
  ABSOLUTE paths. The _redirects rule `/s/* → /index.html 200` means any
  RELATIVE `src="share.js"` on a page served at `/s/<encoded>` resolves
  to `/s/share.js`, which the same rewrite would serve as index.html,
  which the browser refuses to execute as JS. Anchoring at `/` bypasses
  the /s/* rewrite entirely.
-->
<script src="/hash-wasm.min.js" defer></script>
<!-- Version query busts stale browser caches on redeploy. -->
<script src="/share.js?v=fmt1" defer></script>
```

- **Why `src="/share.js"` and not `src="share.js"`?** Because the page is served
  at a weird path like `/s/AbCdEf…`. A *relative* path would resolve to
  `/s/share.js`, and the single-page-app rewrite would turn *that* into
  `index.html` again — so the browser would try to run an HTML file as
  JavaScript and fail. The leading `/` forces "from the site root," dodging the
  rewrite. This is a subtle SPA-hosting gotcha and the comment is gold.
- **`?v=fmt1`** — a cache-buster. Browsers cache JS aggressively; bumping this
  query string forces recipients to download the *new* decryptor after you
  redeploy, so an old decryptor never runs against a new blob format.
- **`defer`** — "download the script now, but run it only after the page's HTML
  is parsed." Prevents the script from running before the elements it needs
  exist.
- **`hash-wasm.min.js`** — a small library that provides **Argon2id**, a
  password-hashing algorithm the browser's built-in crypto (`SubtleCrypto`)
  doesn't include. Needed only for password-protected shares (see below).

### 4.4 `web-viewer/share.js` — the in-browser decryptor

This is the mirror image of the app's own crypto (which we'll cover in Entry 2's
`encryption_service.dart` and `share_service.dart`). It has to produce *byte-for-
byte* the same decryption the app does, or nothing works. That's why the two
must agree on constants exactly:

```javascript
const ENCRYPTED_CHUNK_SIZE = 524316; // 512 KiB plaintext + 12-byte nonce + 16-byte MAC
const NONCE_SIZE = 12;
const MAC_SIZE = 16;
const FORMAT_VERSION = 0x01; // first byte of every CipherNest blob
const BODY_PREAMBLE_SIZE = 20; // 16-byte content_id + 4-byte total_chunks (BE)
```

These numbers *are* the file format. A CipherNest encrypted file is:

1. **1 byte** version tag (`0x01`).
2. **4 bytes** saying how long the "wrapped key region" is.
3. **The wrapped key region** — the file's own encryption key, itself encrypted
   ("wrapped") with the share key. (60 bytes, or 76 with a 16-byte salt for
   password shares.)
4. **The body** — a 20-byte preamble (`content_id` + how many chunks), then a
   series of chunks, each up to ~512 KiB, each independently encrypted with
   AES-GCM.

#### Where the key comes from: `#k=` vs `#p=`

`main()` reads the URL and splits into two cases:

```javascript
if (fragParams.p) {
  // Password-protected...
  const saltBytes = b64UrlDecodeBytes(fragParams.p);
  showPasswordPrompt(async (password) => {
    ...
    derived = await hashwasm.argon2id({ password, salt: saltBytes, ... });
    await decryptAndRender(downloadUrl, derived, { password: true });
  });
  return;
}
if (!fragParams.k) {
  return showError('Missing decryption key in the URL fragment.');
}
const shareKeyBytes = b64UrlDecodeBytes(fragParams.k);
decryptAndRender(downloadUrl, shareKeyBytes)...
```

Two share modes:

- **Plain (`#k=`):** the 32-byte share key is right there in the fragment. The
  browser just uses it. Convenient, and still zero-knowledge because the fragment
  never hits a server. This is the fully-working browser path.
- **Password (`#p=`):** the fragment carries only a *salt*, not the key. The
  recipient types a password; the browser runs **Argon2id** (via `hash-wasm`) to
  turn password + salt into the key. This is stronger (a leaked link alone is
  useless without the password), but note the limitation below.

The Argon2 parameters must match the Dart side exactly, and the comment says so:

```javascript
// Must match the Dart sender's EncryptionService.derivePasswordKey exactly,
// otherwise the derived share key won't match the one used to wrap the file key.
const ARGON2_PARAMS = { parallelism: 1, iterations: 2, memorySize: 65536, hashLength: 32 };
```

`memorySize: 65536` KiB = 64 MiB — deliberately making the hash expensive so an
attacker can't brute-force passwords cheaply. This is textbook good crypto.

#### The decryption pipeline

`decryptAndRender` is the whole flow in one function:

```javascript
setStatus('Fetching encrypted blob…', true);
const blob = await fetchViaProxy(downloadUrl);          // 1. download via /proxy

const shareKey = await crypto.subtle.importKey(         // 2. load the share key
  'raw', shareKeyBytes, { name: 'AES-GCM' }, false, ['decrypt']);

// 3. read the header, decrypt the wrapped file key
const regionLen = readU32BE(blob, 1);
const wrappedFileKey = blob.subarray(wrappedStart, regionEnd);
const fileKeyBytes = await aesGcmDecrypt(shareKey, wrappedFileKey);
const fileKey = await crypto.subtle.importKey('raw', fileKeyBytes, ...);

const body = blob.subarray(regionEnd);                  // 4. decrypt the body
const plaintext = await decryptBody(fileKey, body);
await render(plaintext);                                // 5. show it
```

The important idea here is **key wrapping**, and it's a genuinely elegant design
choice you should be able to explain:

- Every file has its own random **file key**.
- That file key is stored *encrypted* ("wrapped") inside the blob, locked with
  the **share key**.
- To decrypt: use the share key to unwrap the file key, then use the file key to
  decrypt the body.

Why do it in two layers instead of one? Because it lets you re-share or
re-key without re-encrypting the whole (possibly huge) file — you only re-wrap
the tiny file key. `crypto.subtle` is **SubtleCrypto**, the browser's built-in
cryptography engine, so the actual AES-GCM math runs in fast, audited native
code, not in your JavaScript.

#### The body format and its tamper-resistance

`decryptBody` walks the chunks, and the comment above it is a compact security
statement worth reading twice:

```javascript
// Body v1: [16 content_id][4 total_chunks BE] then chunks of up to
// ENCRYPTED_CHUNK_SIZE, each [12 nonce=BE96(i)][ct][16 tag] with
// AAD = content_id || BE32(i) || BE32(total_chunks). One format, no
// single-shot/chunked ambiguity. Reorder, truncation, duplication, and
// cross-blob splice all fail authentication.
```

Translating the guarantee: each chunk is bound to (a) *which file* it belongs to
(`content_id`), (b) *its position* (`i`), and (c) *the total count*. This is done
through the **AAD** ("additional authenticated data" — data that isn't encrypted
but *is* authenticated, so tampering is detected). The result:

- **Reorder** two chunks → the position no longer matches → authentication
  fails.
- **Truncate** the file → the count won't match → fails.
- **Splice** a chunk from a different file → the `content_id` won't match →
  fails.

That's the difference between "encrypted" and "encrypted *and tamper-evident*,"
and it's exactly the kind of detail that impresses a security reviewer.

#### Why password shares bounce to the app (an honest limitation)

`web-viewer/README.md` states it plainly:

> "Password-protected shares require Argon2id key derivation … Plain (non-
> password) shares work fully in-browser."

Historically the browser couldn't do Argon2id at all; the `hash-wasm` library
was added so it now can. The remaining limitation the README documents is that
the whole blob is downloaded then decrypted (no streaming yet), so very large
videos are slow in the browser — fine for photos and documents, a v2 item for
big videos.

#### The rest of `share.js`

- `fetchViaProxy` — calls `/proxy?u=…`, and if the response is HTML (the
  interstitial case the Worker sniffed), it surfaces the debug snippet as a
  clear error.
- `render` / `sniffKind` — after decrypting, it looks at the first few bytes
  ("magic bytes": `FF D8 FF` = JPEG, `%PDF` = PDF, `ID3` = MP3, etc.) to decide
  whether to show an image, a video, audio, or a download row. It never trusts a
  file extension; it reads the actual bytes.
- Encoding helpers (`b64UrlDecodeBytes`, `readU32BE`, …) — small utilities to
  decode the URL-safe base64 in the link and read big-endian numbers out of the
  blob.

### 4.5 `web-viewer/oauth-callback.html` — returning from sign-in

**Where it sits:** `web-viewer/oauth-callback.html`. **What it does:** it's the
page Google/Microsoft send the user back to *after* they approve sign-in, and its
only job is to hand control back to your Android app.

The whole trick is in the comment and the one line of script:

```html
<a class="btn" id="open" href="#">Open CipherNest</a>
<script>
  var target = 'intent://oauth-callback' + location.search +
    '#Intent;scheme=ciphernest-open;package=com.example.frontend;end';
  document.getElementById('open').setAttribute('href', target);
</script>
```

Why a button the user must tap, instead of jumping automatically? Two hard-won
reasons the comment records:

1. **Chrome only launches an app from a custom-scheme link (`intent://…`) after
   a real user gesture.** A scripted auto-redirect to an app scheme is blocked
   and can even break the tab. So there's a button.
2. **The scheme is `ciphernest-open`, not `ciphernest:`.** `ciphernest-open`
   targets your app's *MainActivity* (bringing the running app to the front),
   which then relays the sign-in code internally. Targeting the OAuth plugin's
   own activity directly used to strand the user in the browser tab. We'll see
   the Android side of this relay in Entry 7.

`location.search` is the `?code=…` part of the URL — the one-time, short-lived
sign-in code. The page sends it *only* to your app, nowhere else.

### 4.6 `web-viewer/.well-known/assetlinks.json` — App Links verification

**Where it sits:** `web-viewer/.well-known/assetlinks.json`. **What it does:**
this is how Android knows your website and your app are *the same owner*, so that
tapping a `ciphernest.pages.dev` link can open the app directly instead of
showing an "Open with…" chooser.

```json
[
  {
    "relation": ["delegate_permission/common.handle_all_urls"],
    "target": {
      "namespace": "android_app",
      "package_name": "com.example.frontend",
      "sha256_cert_fingerprints": [
        "FF:CD:23:AE:34:6C:51:F1:F2:E6:56:DA:4E:FA:A3:32:E3:29:45:97:D4:88:F9:1E:A4:A0:40:AA:66:BD:CB:68"
      ]
    }
  }
]
```

- **`package_name: io.ciphernest.vault`** — your app's unique Android ID.
  This was renamed from the old `com.example.frontend` placeholder (which the
  Play Store rejects) to the final `io.ciphernest.vault` (reverse of the
  `ciphernest.io` domain you own). The rename touched this file, the Gradle
  `applicationId`/`namespace`, the Kotlin package folders (`io/ciphernest/vault/`),
  and `oauth-callback.html`'s `package=` target. Note the OneDrive and Google
  redirects are *not* package-based (OneDrive uses the https `/oauth-callback`
  page + the `ciphernest` scheme; Google Sign-In matches on package + signing
  SHA-1 in Google Cloud), so the one external follow-up is registering the new
  package + SHA-1 in the Google Cloud Android OAuth client, and redeploying this
  file to Cloudflare so its `package_name` matches the installed app.
- **`sha256_cert_fingerprints`** — the fingerprint of the certificate your APK
  is signed with. Android checks that the app trying to open the link is signed
  by this exact key. **This is currently your debug key's fingerprint** — when
  you set up a real release keystore, this value must be updated to the release
  key's fingerprint, or App Links will silently stop verifying.
- **`.well-known/`** — a web convention: a standard folder where machines look
  for "proof of ownership" files like this one.

### 4.7 `web-viewer/README.md`

A developer-facing note that documents the architecture (recipient URL shape,
the fragment-never-sent principle), the deploy steps to Cloudflare Pages, the v1
limitations (password shares, no streaming, App Links needing the assetlinks
file), and the hardening notes (host allowlist, `no-store`). It's the human
summary of everything in 4.1–4.6. One thing to note: it references an older
`functions/proxy.js` Pages-Functions layout, whereas the repo has since moved to
the single `worker.js` Worker model described in `wrangler.jsonc`. Same behavior,
newer mechanism — worth updating the README wording someday so it matches.

---

## 5. `docs/` and `temp/` — paperwork and scratch

**`docs/`** (git-ignored) holds the business and academic materials, not code:

```
docs/
├── CipherNest Pitch.pdf                     ← the pitch deck
├── CipherNest Plan.docx                     ← the plan
├── CipherNest Proposal.docx                 ← the DCW proposal
├── Ciphernest Pricing Strategy.docx         ← monetization thinking
├── CipherNest_Progress_Report_Usman_Shafi.docx
├── Notes on CipherNest.docx
├── CipherNest by Claude Code.docx           ← AI-written drafts
├── CipherNest by Gemini.docx
├── master_test_run_1.pdf                    ← a QA test run
├── MTR1_FINDINGS.md / MTR2_PROTOCOL.md      ← test findings & protocol
└── peaceful-dreaming-frog.md                ← a saved plan
```

**`temp/`** (git-ignored) holds design-reference screenshots you compare the UI
against (e.g. `documents_view_default.jpeg`, `documents_view_expanded.jpeg`).
Pure scratch.

Neither ships in the app or the website. They're kept local via `.gitignore`.

---

## 6. What's inside `frontend/` at the top level (the Flutter scaffold)

We're not going into the app's actual code yet — that's Entry 2 onward. But you
asked what all the Flutter *scaffolding* is, because you'll see these folders in
**every** Flutter project and it's disorienting not to know what they do. Here's
the top of `frontend/`:

```
frontend/
├── lib/                    ← YOUR DART SOURCE CODE. This is the app. (Entries 2–6.)
│   ├── main.dart           ← the entry point: the first function that runs.
│   ├── src/app.dart        ← the root widget; sets up theme, routes, etc.
│   ├── crypto/             ← low-level crypto (Entry 2).
│   ├── services/           ← "engine" logic: encryption, cloud, sync, DB (Entries 2–4, 6).
│   └── src/                ← screens, config, models, state, widgets (Entry 5).
├── pubspec.yaml            ← the project manifest: name, dependencies, assets, fonts.
├── pubspec.lock            ← exact versions of every dependency (auto-generated).
├── analysis_options.yaml   ← linter rules ("warn me about bad code patterns").
├── assets/                 ← bundled images, fonts, etc. shipped inside the app.
├── test/                   ← automated tests.
├── third_party/            ← vendored (copied-in) external code you patched.
├── android/                ← the Android "runner" shell + native Kotlin (Entry 7).
├── ios/  linux/  macos/  windows/  web/   ← runner shells for other platforms.
├── build/                  ← compiled output (auto-generated; the APK comes from here).
├── .dart_tool/             ← Dart's own cache (auto-generated).
├── .idea/  frontend.iml    ← IntelliJ/Android Studio project settings.
├── .metadata               ← Flutter's bookkeeping about the project.
├── .flutter-plugins-dependencies  ← auto-generated plugin wiring.
├── PERF.md  QA_FOLDERS.md  README.md   ← your own notes/docs.
└── .gitignore              ← frontend-specific ignore list.
```

Let me demystify the ones that confuse newcomers most.

### `pubspec.yaml` — the project manifest

This is the single most important config file in any Flutter project. Think of
it as the app's "ingredients list." It declares:

- the app's name and version (`1.0.0+1`),
- every **dependency** (external package the app uses — `just_audio`, the crypto
  libraries, `url_launcher`, etc.),
- every bundled **asset** (images, and the custom fonts like `Cormorant Upright`,
  `Bungee`),
- and, notably here, a `dependency_overrides` section pointing `just_audio_
  background` at your local patched copy in `third_party/` (more on that below).

When you run `flutter pub get`, Flutter reads this file, downloads the listed
packages, and records the exact versions it picked in **`pubspec.lock`**. You
edit `pubspec.yaml` by hand; you never edit `pubspec.lock` (it's generated, and
it exists so every machine builds with identical versions).

### `analysis_options.yaml` — the linter

A **linter** is a tool that reads your code and warns about likely mistakes or
style problems *without running it*. This file configures which warnings are on.
When you (or I) run `flutter analyze` and see "baseline 8 issues," those 8 come
from rules defined here. It's a quality gate, not part of the shipped app.

### The per-platform folders — `android/`, `ios/`, `linux/`, `macos/`, `windows/`, `web/`

Here's the thing that trips everyone up: **Flutter is cross-platform**, so when
you create a project it generates a little "runner" shell for *every* platform it
supports — a minimal native wrapper whose job is to boot up the Flutter engine
and hand it your Dart code.

- **`android/`** — the one that matters for you. It's a real Android project
  (Gradle build files, the `AndroidManifest.xml`, and your native **Kotlin** code
  for biometrics, notifications, the upload service, deep links). Entry 7 lives
  here.
- **`ios/`, `linux/`, `macos/`, `windows/`, `web/`** — default scaffolding for
  platforms you are **not** shipping. They exist because Flutter created them and
  removing them gains nothing. You can safely think of them as inert. (This is
  also why `.vscode/settings.json` mentions `frontend/linux` — that reference is
  just pointing at one of these unused shells.)

**What is `.gradle`?** Inside `android/` you'll see Gradle files (`build.gradle`
/ `build.gradle.kts`) and a `.gradle/` cache folder. **Gradle** is the build tool
for Android — it's what compiles Kotlin, bundles resources, and produces the APK.
`build.gradle.kts` is where signing config, SDK versions, and dependencies for
the *Android* side are declared (it's the Android counterpart to `pubspec.yaml`).
The `.gradle/` cache is auto-generated junk, like `.dart_tool/`.

### `build/`, `.dart_tool/`, `.idea/`, `.metadata`, `frontend.iml`

All **auto-generated** — you never hand-edit these, and they can be deleted and
regenerated at any time (`flutter clean` wipes `build/` and `.dart_tool/`):

- **`build/`** — compiled output. Your shareable `.apk` is produced here, at
  `build/app/outputs/flutter-apk/app-release.apk`, before we copy it to the root.
- **`.dart_tool/`** — Dart's package/build cache.
- **`.idea/` + `frontend.iml`** — settings for the IntelliJ/Android Studio IDE.
- **`.metadata`** — Flutter's internal record of how the project was created.
- **`.flutter-plugins-dependencies`** — an auto-generated map of which plugins
  need native code on which platform.

### `assets/`, `test/`, `third_party/`

- **`assets/`** — files bundled *inside* the app: images, icons, and your custom
  fonts. Anything here must also be declared in `pubspec.yaml` to be included.
- **`test/`** — automated tests. `flutter test` runs these; they check that
  functions behave as expected without a phone attached.
- **`third_party/`** — external code you *copied into* the repo because you
  needed to patch it. Specifically, `just_audio_background` — the library that
  draws the music notification. You vendored it and removed a hard-coded "stop"
  button (the mystery white-box button you eliminated earlier). `pubspec.yaml`'s
  `dependency_overrides` points at this local copy so the build uses your patched
  version instead of the public one. "Vendoring" is a normal, defensible move
  when upstream doesn't give you a setting for what you need.

### The two `lib/` entry points

Every Flutter app starts at **`lib/main.dart`** — specifically its `main()`
function, the very first code that runs. `main.dart` does the boot sequence
(initialize services, set up the background audio, etc.) and then hands off to
**`lib/src/app.dart`**, the root *widget* that installs the theme and the
navigation routes (that `routes.dart` file we've touched before). We'll read both
properly in Entry 5.

### One thing to notice for later: two `services/` folders

There are **two** service directories — `lib/services/` (the big "engine" files:
encryption, cloud, sync, database, caching) and `lib/src/services/` (a smaller
set). That's mildly unusual and I'll map exactly what lives in each when we get
to Entry 4, so you're never confused about which `services` an import refers to.

---

## 7. Where we are, and what's next

You now understand the entire **perimeter** of CipherNest:

- the repo layout and which files are code vs. tooling vs. paperwork,
- the complete **web-viewer** system — the zero-knowledge magic-link share, the
  Cloudflare Worker proxy, the browser decryptor, the OAuth return page, and the
  App Links proof file,
- and the **Flutter scaffolding** around your app, so the pile of folders in
  `frontend/` no longer looks like noise.

The recurring theme you can now articulate confidently: **the key never touches a
server.** In the app it's on the phone; in the browser it's in the URL fragment.
Everything else — the proxy, the wrapping, the chunk authentication — is built to
preserve that one property.

**Next up (Entry 2): the crypto foundation** — `lib/crypto/` and
`encryption_service.dart` / `key_manager_service.dart` / `share_service.dart`.
That's where the Dart side of everything you just saw in `share.js` actually
lives, and where "AES-256-GCM, client-side" stops being a slogan and becomes
code you can read. Say the word and I'll append it.

<!-- END OF ENTRY 1 -->
