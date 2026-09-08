# CipherNest Web Viewer

Static page that decrypts CipherNest "magic-link" shares entirely in the
browser. Deployed as a **Cloudflare Worker with static assets** (see
`../wrangler.jsonc` and `../worker.js`), currently reachable at
`https://ciphernest.ciphernest20.workers.dev`. A `share.ciphernest.io` custom
domain is planned before public launch — see `docs/DOMAIN_DNS_SETUP.md` and
`docs/self_audit_ledger.md` (SA-WEB-04); the share base URL is baked into every
link at creation, so it must be finalised before any real user mints a share.

## Architecture

Recipients receive a URL of the form

```
https://<host>/s/<base64UrlEncodedDownloadUrl>#k=<shareKey>&exp=<unixMs>
```

The fragment after `#` (the share key, salt, and expiry) is **never** sent to
the server — browsers and HTTP libraries don't include it. So Cloudflare only
sees an opaque file ID.

On load:

1. `index.html` boots `share.js` (and `hash-wasm.min.js` for Argon2id).
2. `share.js` parses the URL and pulls the share key out of the fragment.
3. The browser fetches the encrypted blob through `/proxy?u=…`, a route handled
   by the Worker in `../worker.js`, which adds CORS headers — Google Drive and
   OneDrive don't allow cross-origin fetches directly.
4. `SubtleCrypto.decrypt(AES-GCM, …)` unwraps the file key from the 60-byte
   header, then decrypts each chunked AES-GCM segment of the body.
5. The plaintext is sniffed for a content type (image / video / audio /
   document / unknown) and rendered inline or offered as a download.

## Layout

The Worker and its config live one level up, at the repo root:

- `../wrangler.jsonc` — Cloudflare deploy config: Worker name, `main` =
  `worker.js`, and an `ASSETS` binding pointing at this `web-viewer/` directory
  with single-page-application fallback.
- `../worker.js` — the Worker. Routes `GET/OPTIONS /proxy` to the CORS-proxy
  logic (host allowlist, `no-store`, HTML-interstitial sniffing) and serves
  everything else from the static assets in this directory.

This directory holds the static assets:

- `index.html` — UI shell; loads `share.js` and `hash-wasm.min.js`.
- `share.js` — decryption pipeline. Depends only on `hash-wasm` (bundled
  locally as `hash-wasm.min.js`) for Argon2id; no other external code.
- `hash-wasm.min.js` — local Argon2id (SubtleCrypto lacks it), for
  password-protected shares.
- `oauth-callback.html` — OAuth return page that hands sign-in back to the app.
- `.well-known/assetlinks.json` — Android App Links verification.

> Historical note: earlier this proxy was a Cloudflare **Pages Function**
> (`functions/proxy.js`). It is now the single root `worker.js` under the
> Workers-with-static-assets model; that `functions/` file no longer exists.

## Deploy

Deployed with Wrangler from the repo root (where `wrangler.jsonc` lives):

1. Sign in to the `ciphernest20` Cloudflare account (`wrangler login`).
2. From the repo root, run `wrangler deploy`. It reads `wrangler.jsonc`, uploads
   `worker.js`, and publishes this `web-viewer/` directory as the Worker's
   static assets.
3. After deploy, paste a generated share link from the app into a browser to
   verify.

## Limitations (v1)

- **Password-protected shares** need Argon2id key derivation, which the
  browser's `SubtleCrypto` doesn't include. The viewer now bundles Argon2id
  locally (`hash-wasm.min.js`) and derives the share key from the password in
  the browser, so password shares work fully in-browser too. The Argon2 params
  in `share.js` must stay byte-identical to the app's
  `EncryptionService.derivePasswordKey`, or the derived key won't match.
- **Streaming decryption** isn't implemented — the entire encrypted blob is
  fetched, then decrypted, then rendered. Fine for photos and documents,
  noticeable for large videos. Ship in v2.
- **Android App Links verification** — to make the app open *automatically*
  instead of showing an "Open with" chooser, host
  `/.well-known/assetlinks.json` here with the app's signing fingerprint.
  Without it, recipients see the chooser the first time. Note the fingerprint
  must be the **Play app-signing** certificate once the app ships via Play (see
  the launch playbook, Part 2.4), not only the local/upload key.

## Hardening notes

- The proxy (`../worker.js`) only relays hosts it recognizes. Trimming that
  allowlist to the hosts the app actually emits, plus origin checks, rate
  limiting, a bot challenge, and `.cnest` magic-byte validation, are tracked in
  `docs/self_audit_ledger.md` (SA-WEB-01). This stops the Worker from being
  abused as a general download relay.
- `Cache-Control: no-store` keeps Cloudflare's edge cache from holding onto
  encrypted blobs (small extra defense — they're already encrypted, but no
  reason to cache them).
