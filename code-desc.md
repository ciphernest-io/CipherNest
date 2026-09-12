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

---

# Entry 2 — The crypto foundation

This is the heart of CipherNest, and the reason the whole "zero-knowledge" claim
is true. By the end of this entry you'll be able to trace a photo from the moment
it's picked to the encrypted blob that lands in Drive, and back, and explain every
key involved to a skeptical reviewer. We build it up slowly.

Six files, in the order they depend on each other:

| File | Role (one line) |
|---|---|
| `lib/crypto/aes_gcm.dart` | The symmetric workhorse: encrypt/decrypt a blob or a chunk with a key. |
| `lib/crypto/hpke.dart` | Public-key encryption (RFC 9180) used to lock a file's key to the vault. |
| `lib/services/key_manager_service.dart` | The key hierarchy: one seed to all keys; lock/unlock; biometrics. |
| `lib/services/encryption_service.dart` | The CipherNest file *format*, tying AES + HPKE together. |
| `lib/services/share_service.dart` | Turns a vault file into a shareable magic link (the Dart half of Entry 1's `share.js`). |
| `lib/services/device_identity_service.dart` | A stable per-install ID for multi-device coordination. |

## 2.0 The one idea, in plain words

Every design choice below serves a single sentence:

> **Files are encrypted *to* a public key that can sit in memory even when the
> vault is locked; they can only be *decrypted* with a private key that appears
> only when you unlock with your password (or fingerprint).**

That asymmetry is what lets CipherNest keep auto-backing-up new photos in the
background without your password being present — it can *lock* new files but not
*read* old ones. It's the same trick HTTPS uses (anyone can encrypt to a server's
public key; only the server decrypts), applied to your gallery.

The layered picture (memorize this shape — everything else is a detail of it):

```
   your 12 words  --(BIP-39)-->  64-byte SEED   <- the single root secret
                                     |
                 +-------------------+--------------------+
            (HKDF, label             (HKDF, label
             "ciphernest/x25519/v1")  "ciphernest/local/v1")
                 |                        |
        X25519 KEYPAIR              k_local (a 32-byte key
        pub  (can encrypt)          for small on-device secrets)
        priv (can decrypt)
                 |
     each file gets its OWN random AES-256 key
                 |
   file KEY is sealed to the vault pub key via HPKE  -> stored in the 81-byte header
   file BODY bytes are AES-256-GCM, chunked
```

And the seed itself is stored on disk only in **wrapped** (encrypted) form:
locked with a key derived from your password via **Argon2id**. No password means
the seed stays gibberish, so the private key can't be rebuilt, so old files can't
be read. That's the lock.

## 2.1 A five-minute vocabulary (skip if you know it)

- **Plaintext / ciphertext:** the readable bytes vs. the scrambled bytes.
- **Symmetric key:** one secret used to both encrypt and decrypt (like a house
  key). CipherNest uses **AES-256-GCM** for the actual file bytes.
- **Nonce** ("number used once"): a per-encryption value mixed in so encrypting
  the same data twice gives different ciphertext. Must never repeat under the
  same key. 12 bytes here.
- **MAC / tag:** a 16-byte checksum GCM computes that proves the ciphertext
  wasn't altered. If a single byte is flipped, decryption *fails* rather than
  returning garbage. This is the "authenticated" in AES-GCM.
- **AAD** (additional authenticated data): extra bytes that are *not* encrypted
  but *are* covered by the tag. Used to bind a chunk to its position so it can't
  be shuffled. You saw the receiving end of this in Entry 1's `share.js`.
- **Public-key / asymmetric crypto:** a **keypair** — a public half that locks,
  a private half that unlocks. CipherNest's is **X25519** (a modern elliptic
  curve). **HPKE** is the standard recipe for using it to encrypt data.
- **KDF** (key derivation function): turns one secret into others.
  **HKDF** stretches a strong random seed into several subkeys cheaply;
  **Argon2id** turns a *weak* human password into a key *slowly and expensively*
  (to resist guessing).
- **BIP-39:** the standard that turns 12 memorable words (a "mnemonic") into a
  64-byte seed. It's the same scheme crypto wallets use for recovery phrases.

### Dart notes you'll keep seeing
- `Future<T>` = "a T that isn't ready yet"; `async`/`await` = wait for it without
  freezing the app. Nearly every crypto call is a `Future` because it may run on
  a background thread.
- `Uint8List` = a fixed, efficient array of bytes (0–255). This is *the* type for
  raw crypto data. `.sublist(a, b)` slices out bytes `a`…`b-1`.
- `static` = belongs to the class itself, not an instance (you call it as
  `EncryptionService.encryptFile(...)`).
- The **singleton** pattern — `factory KeyManagerService() => _instance;` — means
  "every `KeyManagerService()` you write returns the *same* object," so there's
  exactly one keychain in the whole app.

## 2.2 `lib/crypto/aes_gcm.dart` — the symmetric workhorse (117 lines)

The lowest layer: given some bytes and a key, produce `nonce + ciphertext + tag`,
and the reverse. Nothing here knows about files or the vault; it just does one
AES-GCM operation cleanly.

```dart
class AesGcmCipher {
  final AesGcm _aesGcm = AesGcm.with256bits();

  /// Returns: Nonce (12 bytes) + Ciphertext + MAC (16 bytes)
  Future<Uint8List> encrypt(Uint8List plaintext, SecretKey key) async {
    final nonce = _randomBytes(12); // Standard 96-bit nonce
    final secretBox = await _aesGcm.encrypt(plaintext, secretKey: key, nonce: nonce);
    return _assemble(nonce, secretBox.cipherText, secretBox.mac.bytes);
  }
```

- `AesGcm.with256bits()` comes from the `cryptography` package — the audited
  library that does the real math. This file is a thin, opinionated wrapper.
- A **`SecretBox`** (the library's term) bundles ciphertext + nonce + MAC.
  CipherNest flattens it to one byte array on the wire: `nonce + ct + tag`, so a
  blob is self-describing (decrypt reads the first 12 bytes as the nonce, the
  last 16 as the tag). `decrypt` just reverses that:

```dart
final nonce = encryptedData.sublist(0, 12);
final macBytes = encryptedData.sublist(encryptedData.length - 16);
final cipherText = encryptedData.sublist(12, encryptedData.length - 16);
```

The other pair, `encryptChunk` / `decryptChunk`, is the same but (a) takes a
*caller-supplied* nonce and AAD, and (b) on decrypt refuses a chunk whose inline
nonce isn't the one expected:

```dart
final nonce = data.sublist(0, 12);
if (!_bytesEqual(nonce, expectedNonce)) {
  throw Exception('Chunk nonce mismatch');
}
```

That check is a cheap first line of defense against someone swapping two chunks
of a file — it fails *before* the expensive GCM step even runs (the tag+AAD would
catch it anyway; this just fails faster and clearer). `_assemble` builds the
output into one pre-sized `Uint8List` instead of concatenating lists — a small
speed detail the comment calls out (fewer buffer copies per 512 KB chunk).

`_randomBytes` uses `Random.secure()` — the OS cryptographic RNG, *not* the
ordinary `Random()` (which is predictable and would be a real vulnerability for
nonces/keys). Worth noticing: getting this wrong is a classic crypto bug, and the
code gets it right.

## 2.3 `lib/services/key_manager_service.dart` — the keychain (735 lines)

This is the most important security file in the app. Its long doc-comment is
worth reading in the source; here's the structure and the *why*.

### One root, many keys (HKDF)
Account creation:

```dart
Future<String> createAccount(String password) async {
  final mnemonic = bip39.generateMnemonic();        // 12 random words
  final seed = bip39.mnemonicToSeed(mnemonic);       // 64 bytes
  await _installSeed(seed, password);
  ...
  return mnemonic;                                   // shown once, to write down
}
```

`_installSeed` calls `_deriveKeys`, which is the heart:

```dart
static Future<_DerivedKeys> _deriveKeys(Uint8List seed) async {
  final x25519Seed = await _hkdf(seed, infoX25519, 32);   // "ciphernest/x25519/v1"
  final kLocalBytes = await _hkdf(seed, infoLocal, 32);   // "ciphernest/local/v1"
  final keyPair = await X25519().newKeyPairFromSeed(x25519Seed);
  final publicKey = await keyPair.extractPublicKey();
  return _DerivedKeys(keyPair: keyPair, publicKey: publicKey,
                      kLocal: SecretKey(kLocalBytes));
}
```

- **HKDF** stretches the one seed into two independent 32-byte subkeys. The
  **`info` strings** (`ciphernest/x25519/v1`, `ciphernest/local/v1`) are *domain
  separators*: same seed, different label gives a completely different key, and no
  key can be mistaken for another. The comment flags these as **frozen forever** —
  a typo would permanently orphan a real vault, so a test pins them. That's a
  mature detail: they treat these constants as a wire format.
- From the X25519 subkey it builds the **vault keypair**. `k_local` is a separate
  symmetric key for small on-device secrets (the crash-recovery mnemonic blob).

### The split: public key resident, private key gated
Two fields, two capabilities:

```dart
SimpleKeyPair? _vaultKeyPair;     // decrypt capability — only while unlocked
SimplePublicKey? _vaultPublicKey; // encrypt capability — available even locked

bool get isUnlocked => _vaultKeyPair != null;
bool get canEncrypt => _vaultPublicKey != null;
```

`lock()` throws away the private key but keeps the public one:

```dart
void lock() {
  _vaultKeyPair = null;
  _kLocal = null;
  _signupPassword = null;
}
```

So a locked app is **encrypt-only**. The public key also lives in
Keystore-wrapped secure storage (`vault_pub_v1`) and can be loaded into a
background isolate with `loadPublicKeyForEncrypt()` — "structurally cannot load
the private key," as the comment says. This is the mechanism behind
encrypt-while-locked background sync.

### Wrapping the seed under your password (Argon2id)
The seed is never stored in the clear. `_encryptAndSaveSeedBlob`:

```dart
final salt = _randomBytes(16);
final kek = await _deriveKeyFromPassword(password, salt);   // Argon2id
final nonce = _randomBytes(12);
final box = await AesGcm.with256bits().encrypt(seed, secretKey: kek, nonce: nonce);
// -> stores base64(cipherText), nonce, mac, salt in SharedPreferences
```

- `kek` = "key-encryption key," derived from your password by **Argon2id** with
  `memory: 65536` (64 MB), `iterations: 2`. Deliberately slow and memory-hungry
  so an attacker who copies the blob can't brute-force passwords cheaply. (This
  is the *same* Argon2id the browser runs in Entry 1's password shares — the
  parameters must match, and they do.)
- `unlock` reverses it and then does something clever:

```dart
Future<bool> unlock(String password) async {
  final seed = await _decryptSeedBlob(password);
  if (seed == null) return false;                 // wrong password
  final keys = await _deriveKeys(seed);
  await _verifyStoredPublicKey(keys.publicKey);    // <- anti-tamper
  _vaultKeyPair = keys.keyPair; ...
  return true;
}
```

`_verifyStoredPublicKey` re-derives the public key from the seed and
**constant-time compares** it to the stored one; a mismatch throws
`PublicKeyMismatchException` and halts. Why? If malware swapped the stored public
key, your background sync would start encrypting new files to *the attacker's*
key. This check refuses to proceed. (`_constantTimeEquals` avoids leaking, via
timing, how many leading bytes matched — a subtle but correct touch.)

### Biometric unlock is a *second wrap*, not a second secret
`enableBiometric(password)` re-wraps the *same seed* under an AndroidKeyStore key
that's hardware-gated behind a fingerprint prompt (the native side is
`BiometricSeedVault.kt`, covered in Entry 7). Key properties, all enforced here:
- Enabling **requires the password** (the seed only exists in memory during a
  password entry — there's no other honest moment to re-wrap it).
- `unlockWithBiometric()` runs the *identical* derive-and-verify sequence as the
  password path, including the anti-tamper check — biometrics are not a shortcut
  around the integrity guarantee.
- If Android destroys the key (you add/remove a fingerprint, change your PIN), it
  throws `BiometricInvalidatedException` and silently falls back to password.
  "Zero data loss," because the password wrap is always the real root.

### Staged recovery — the fix for a nasty old bug
When restoring from a phrase, the naive approach persists the new seed
immediately. The comment records why that was dangerous (MTR#1 F9): a *valid but
wrong* phrase would overwrite your real vault, and only a reinstall could undo
it. The fix — `stageRecovery` then `commitStagedRecovery` — derives the candidate
keys **in memory only**, lets a "canary" check prove the phrase actually owns the
cloud vault, and *only then* persists:

```dart
Future<void> stageRecovery(String mnemonic, String newPassword) async {
  ...
  final seed = bip39.mnemonicToSeed(mnemonic);
  final keys = await _deriveKeys(seed);
  _vaultKeyPair = keys.keyPair; ...       // in memory
  _stagedSeed = seed;                      // nothing written to disk yet
}
```

Notice the repeated `seed.fillRange(0, seed.length, 0)` — the seed bytes are
zeroed after use. Dart can't *guarantee* memory is scrubbed (the comment is
honest about this), but overwriting the known copy is the right habit.

`changePassword` is a neat consequence of this architecture: it decrypts the seed
with the old password and re-wraps it under the new one — **the seed, the vault
keys, and the recovery phrase are all unchanged**; only the local wrapping key
changes. So changing your password can't lose access to files, and the recovery
phrase still works.

## 2.4 `lib/crypto/hpke.dart` — sealing the file key (441 lines)

This is the fanciest file, but the *idea* is simple: **encrypt a file's 32-byte
key to the vault's public key**, so only the vault's private key can recover it.
HPKE (RFC 9180, "Hybrid Public Key Encryption") is the modern standard recipe for
exactly that.

The public entry points are tiny:

```dart
static Future<HpkeSealed> sealFileKey(SimplePublicKey recipientPublicKey, Uint8List fileKey);
static Future<Uint8List>  openFileKey(SimpleKeyPair recipientKeyPair, Uint8List enc, Uint8List ct);
```

- `sealFileKey` returns two pieces: **`enc`** (32 bytes — a one-time "ephemeral"
  public key generated for this seal) and **`ct`** (48 bytes — the 32-byte file
  key encrypted, plus its 16-byte tag). Together they're the header's payload.
- Sealing needs **only the recipient's public key**, which is what gives
  encrypt-while-locked. Opening needs the private key, i.e. an unlocked vault.

Why "hybrid"? Public-key math is slow and size-limited, so HPKE uses it once to
agree on a shared symmetric key (via a Diffie-Hellman exchange with that ephemeral
keypair — "DHKEM"), then uses fast AES-GCM to encrypt the payload. You get
public-key convenience at symmetric-key speed.

Two things about this file signal real rigor, worth saying in an interview:

1. **It's a from-scratch implementation of the RFC**, built over the
   `cryptography` package's HMAC/X25519/AES primitives — the labeled KDF
   (`_labeledExtract`/`_labeledExpand`), DHKEM (`_encap`/`_decap`), and the key
   schedule (`_keySchedule`) are each the literal RFC 9180 procedures. Every
   intermediate is checked against the RFC's **published test vectors**
   (Appendix A.1) in `test/crypto/hpke_test.dart`. That's how you earn the right
   to hand-roll crypto: byte-for-byte conformance to the spec's own numbers.
2. **The suite is chosen deliberately:** `DHKEM(X25519, HKDF-SHA256),
   HKDF-SHA256, AES-128-GCM`. The comment explains the one surprise — AES-*128*
   for the key wrap (not 256): X25519 already caps this path at ~128-bit
   security, so AES-256 here would buy nothing, while AES-128 is the suite that
   has official RFC test vectors. File *bodies* are still AES-256-GCM. That's an
   informed trade-off, not a weakness.

There's also `deriveKeyPair` / `_deriveSk`, the RFC's deterministic
"seed to keypair" procedure — but note the vault keypair is actually built in
`key_manager` via `X25519().newKeyPairFromSeed(hkdf(...))`, and HPKE's own
`deriveKeyPair` exists mainly to satisfy the RFC conformance tests. The
`fileKeyInfo = 'ciphernest/filekey/v1'` string is another frozen domain separator
(same discipline as the HKDF labels).

You don't need to follow the KDF byte-plumbing to trust it — that's what the test
vectors are for. You *do* need to be able to say: "each file key is sealed to the
vault's X25519 public key with standard HPKE; sealing needs no secret, opening
needs the vault private key."

## 2.5 `lib/services/encryption_service.dart` — the file format (488 lines)

This file defines **what a `.cnest` blob actually looks like** and orchestrates
AES + HPKE into it. The class doc-comment is the spec; here it is, annotated:

```
Header (81 bytes):
  [1]  version = 0x01
  [32] enc         — HPKE ephemeral public key
  [48] sealed key  — HPKE seal of the 32-byte AES-256 file key
Body:
  [16] content_id      — random, plaintext
  [4]  total_chunks (big-endian)
  chunk i (stride 524316, last shorter):
     [12] nonce = BE96(i)   [ciphertext up to 524288]   [16 tag]
     AAD = content_id + BE32(i) + BE32(total_chunks)
```

Encrypting a file (`_encryptFileWith`) is now readable end to end:

```dart
final fileKey = await AesGcm.with256bits().newSecretKey();   // fresh per file
final contentId = _randomBytes(16);
final totalChunks = fileBytes.isEmpty ? 0 : (fileBytes.length / _chunkSize).ceil();

out.add(await _buildHeader(recipient, fileKeyBytes));        // HPKE-seal the key
out.add(_buildPreamble(contentId, totalChunks));
for (var i = 0; i < totalChunks; i++) {
  ...
  out.add(await _cipher.encryptChunk(chunk, fileKey,
      _chunkNonce(i), _chunkAad(contentId, i, totalChunks)));
}
```

Key takeaways:
- **Every file gets its own random AES-256 key.** That key is then sealed into
  the header via HPKE. So the vault key never directly touches file bytes — it
  only ever unwraps per-file keys. (This is "key wrapping," the same two-layer
  design you met from the reader's side in Entry 1.)
- **`content_id` + `AAD` = integrity, not just secrecy.** Each chunk's AAD binds
  it to *this file* (`content_id`), *its position* (`i`), and *the total count*.
  The class comment states the payoff plainly: "reorder, truncation, duplication,
  and cross-blob splicing all fail authentication." `decryptBody` even re-checks
  the count at the end:

```dart
if (index != totalChunks) {
  throw Exception('Chunk count mismatch: header says $totalChunks, found $index');
}
```

- **The nonce is a counter**, `BE96(i)` — a 96-bit big-endian encoding of the
  chunk index. That's safe here *because each file key is brand-new and used by
  exactly one encryptor*, so counter nonces can never collide under a key (the
  cardinal AES-GCM rule). The comment in `aes_gcm.dart` calls this out.

### Two things that are about *performance*, not crypto
- **`decryptBody` is shared by vault files and shares.** A share only swaps the
  header; the body ciphertext is byte-identical. That's why `ShareService` can
  re-wrap a file without re-encrypting it, and why Entry 1's `share.js` decrypts
  the body with the exact same chunk logic.
- **Isolate offloading.** Pure-Dart AES/SHA runs synchronously and would freeze
  the UI mid-encrypt, so `encryptFileInBackground` etc. use `Isolate.run(...)` to
  do it on a background thread. Crucially, only the **public key bytes** are
  captured and sent across (rebuilt inside the isolate) — "nothing secret crosses
  the port," because sealing needs only the public key. `encryptStream` (an
  `async*` generator that `yield`s encrypted chunks) handles large videos without
  loading them fully into memory.

### The plaintext content hash ("filename is not identity")
`encryptFileWithHash` / `encryptStreamWithHash` compute a **SHA-256 of the
plaintext** in the *same read pass* as encryption. This hash is the file's true
identity — used for real deduplication and for safely matching a local gallery
photo to a vault file across reinstalls/devices, instead of trusting a filename.
It's computed cheaply alongside the AES that's already running.

## 2.6 `share_service.dart` and `device_identity_service.dart`

### `share_service.dart` (219 lines) — the Dart half of the magic link
This is the exact counterpart to Entry 1's `share.js`; reading them side by side
is the best way to understand the share format. `createShare` (annotated):

```dart
// 1. download the existing encrypted blob
final originalBytes = await CloudService().downloadFile(file.cloudId!);
// 2. recover THIS file's key from its header (needs an UNLOCKED vault — HPKE open)
final fileKey = await EncryptionService.decryptFileKeyFromHeader(originalBytes);
// 3. make a share key: random, OR Argon2id-derived from a password + salt
SecretKey shareKey; Uint8List? salt;
if (password != null && password.isNotEmpty) {
  salt = EncryptionService.generatePasswordSalt();
  shareKey = await EncryptionService.derivePasswordKey(password, salt);
} else {
  shareKey = await EncryptionService.generateShareKey();
}
// 4. RE-WRAP the file key under the share key (symmetric), frame a share header
final wrapped = await EncryptionService.wrapFileKeyForShare(fileKey, shareKey);
```

So a share swaps the **header only**: instead of the file key sealed to the vault
(HPKE), it's wrapped under a symmetric **share key** (`wrapFileKeyForShare` =
AES-GCM `encrypt`, producing the 60-byte `nonce+ct+tag` that `share.js` expects at
offset 5 of the blob). The share header framing —
`[1 version][4 region-len][region]`, region = `wrapped` or `salt+wrapped` — is
built here and parsed by `share.js` in Entry 1. The **body is copied verbatim**.

The magic link is assembled in `_buildShareUrl`, and it's the mirror image of
what `share.js` parses:

```dart
if (salt != null) fragment.write('p=${base64Url.encode(salt)}');    // password mode
else              fragment.write('k=${base64Url.encode(keyBytes)}'); // plain mode
if (expiresAt != null) fragment.write('&exp=${expiresAt.millisecondsSinceEpoch}');
fragment.write('&n=${base64Url.encode(utf8.encode(filename))}');
return 'https://${AppConstants.shareHost}/s/$encodedDl#${fragment.toString()}';
```

Everything after `#` is the fragment — the key (or salt), expiry, and filename —
which, as Entry 1 explained, browsers never send to the server. `AppConstants.
shareHost` is the constant we just repointed to `share.ciphernest.io`. There's
also a **Plus gate** (free tier: no passwords, 7-day max expiry) enforced here as
a backstop so no code path can mint gated shares, and `sweepExpired`/`revokeShare`
for cleanup (deleting the public blob is the *real* expiry, since the fragment
expiry is only advisory — the point the security ledger's SA-WEB-02 makes).

### `device_identity_service.dart` (38 lines) — a stable install ID
Small but with a sharp rationale. It mints a random UUID on first use and keeps it
in Keystore-wrapped secure storage:

```dart
var id = await _storage.read(key: _kDeviceId);
if (id == null || id.isEmpty) {
  id = const Uuid().v4();
  await _storage.write(key: _kDeviceId, value: id);
}
```

The important design note is what it *doesn't* do: this ID is **deliberately kept
out of the database backup**. If it rode along in a restored snapshot, two devices
could end up writing under the same identity and clobber each other's multi-device
sync records. A reinstall minting a fresh ID is "a feature, not a loss" — it keeps
per-device names collision-proof. (You'll see why in the sync/backup entry.)

## 2.7 Putting it together — the life of one photo

1. You pick a photo. The app reads its bytes once, and in that pass computes the
   **plaintext SHA-256** (identity) and encrypts it (`encryptFileWithHash`, often
   in a background isolate).
2. Encryption makes a **fresh random AES-256 file key**, splits the photo into
   512 KB chunks, and AES-GCM-encrypts each chunk with a counter nonce and
   position-binding AAD.
3. That file key is **HPKE-sealed to the vault's public key** and written into the
   81-byte header. No private key was needed — this can happen while the vault is
   locked.
4. The blob (header + body) uploads to your Drive/OneDrive. Google sees only
   ciphertext + a random `content_id`.
5. To view it, you **unlock** (password to Argon2id to seed to derived keys, then
   verify the public key). The private key opens the header (HPKE), recovering the
   file key; `decryptBody` verifies and decrypts the chunks.
6. To **share** it, the file key is re-wrapped under a one-off share key, the body
   is reused unchanged, and the key rides in the URL fragment to a recipient's
   browser — never touching a server.

### What an attacker sees (the honest threat summary)
- **Has your cloud blob only:** ciphertext and a random id. No key material
  reaches the cloud, ever. Useless.
- **Has your locked phone:** the wrapped seed blob (Argon2id-protected), the vault
  *public* key, and — if enabled — a hardware-gated biometric wrap. No private key
  in memory. They can, at most, brute-force your password against a deliberately
  slow KDF.
- **Has your unlocked phone:** everything, of course — which is why auto-lock and
  the real `lock()` matter. This is the boundary the whole design defends.

That's the crypto core. Everything above it — sync, the gallery, the streaming
video server, the database — is plumbing that calls into these six files and never
re-implements crypto.

**Next (Entry 3): Auth & the cloud APIs** — how the app signs into Google and
Microsoft and talks to Drive/OneDrive (`lib/services/cloud/`), which is where the
`onedrive_provider.dart` and `google_drive_provider.dart` we touched during the
domain cutover actually live.

<!-- END OF ENTRY 2 -->
