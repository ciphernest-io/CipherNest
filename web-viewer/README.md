# CipherNest Web Viewer

Static page that decrypts CipherNest "magic-link" shares entirely in the
browser. Designed to be deployed on Cloudflare Pages as
`https://ciphernest.pages.dev`.

## Architecture

Recipients receive a URL of the form

```
https://ciphernest.pages.dev/s/<base64UrlEncodedDownloadUrl>#k=<shareKey>&exp=<unixMs>
```

The fragment after `#` (the share key, salt, and expiry) is **never** sent to
the server — browsers and HTTP libraries don't include it. So Cloudflare only
sees an opaque file ID.

On load:

1. `index.html` boots `share.js`.
2. `share.js` parses the URL and pulls the share key out of the fragment.
3. The browser fetches the encrypted blob through `/proxy?u=…` (a Cloudflare
   Pages Function in `functions/proxy.js`) which adds CORS headers — Google
   Drive and OneDrive don't allow cross-origin fetches directly.
4. `SubtleCrypto.decrypt(AES-GCM, …)` unwraps the file key from the 60-byte
   header, then decrypts each chunked AES-GCM segment of the body.
5. The plaintext is sniffed for a content type (image / video / audio /
   document / unknown) and rendered inline or offered as a download.

## Layout

- `index.html` — UI shell
- `share.js` — decryption pipeline, no external dependencies
- `_redirects` — rewrites `/s/<encoded>` to `index.html` so the SPA can read
  the path
- `functions/proxy.js` — Cloudflare Pages Function that proxies the encrypted
  blob with permissive CORS, restricted to known cloud-storage hosts

## Deploy

1. Sign in at https://dash.cloudflare.com (free tier, no card required).
2. **Workers & Pages → Create application → Pages → Direct upload**.
3. Project name: `ciphernest` → final URL `https://ciphernest.pages.dev`.
4. Drag-and-drop **the contents of this directory** (not the directory itself)
   into the upload box. Pages will auto-detect `functions/` and deploy the
   proxy as a Worker.
5. After deploy, paste a generated share link from the app into a browser to
   verify.

## Limitations (v1)

- **Password-protected shares** require Argon2id key derivation; the browser's
  `SubtleCrypto` doesn't include Argon2id and we want to keep this viewer
  zero-dependency. The viewer detects password mode and tells the recipient to
  open the link in the CipherNest Android app instead. Plain (non-password)
  shares work fully in-browser.
- **Streaming decryption** isn't implemented — the entire encrypted blob is
  fetched, then decrypted, then rendered. Fine for photos and documents,
  noticeable for large videos. Ship in v2.
- **Android App Links verification** — to make the app open *automatically*
  instead of showing an "Open with" chooser, host
  `/.well-known/assetlinks.json` here with the app's signing fingerprint.
  Without it, recipients see the chooser the first time.

## Hardening notes

- The proxy function only proxies hosts it recognizes (Google Drive, OneDrive,
  Dropbox, SharePoint). This stops the function from being abused as an open
  relay.
- `Cache-Control: no-store` keeps Cloudflare's edge cache from holding onto
  encrypted blobs (small extra defense — they're already encrypted, but no
  reason to cache them).
