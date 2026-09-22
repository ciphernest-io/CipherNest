// CipherNest web-viewer Worker.
//
// Under the Workers-with-static-assets model, the old Pages `functions/`
// convention doesn't auto-register endpoints. This Worker manually routes:
//   - auth.ciphernest.io: GET /oauth-callback only (the OneDrive OAuth
//                         return page); every other path is 404.
//   - GET /proxy   -> the CORS-proxying logic (was functions/proxy.js).
//   - OPTIONS /proxy -> the pre-flight response.
//   - everything else -> env.ASSETS.fetch(request), which serves the
//                        static files in web-viewer/ (or index.html for
//                        unmatched paths, because assets.not_found_handling
//                        is set to single-page-application in wrangler.jsonc).

// The OneDrive redirect_uri host. Must equal `_redirectHost` in
// frontend/lib/services/cloud/onedrive_provider.dart and the URI registered
// in Entra. Only the callback page is reachable here, so this host can never
// serve a share link and the share viewer can never shadow the callback.
const AUTH_HOST = 'auth.ciphernest.io';
const AUTH_PATH = '/oauth-callback';
// The callback page's own dependencies (theme logo marks). Nothing else from
// web-viewer/ is reachable on the auth host.
const AUTH_ASSETS = new Set([
  '/img/ciphernest_logo_black.png',
  '/img/ciphernest_logo_white.png',
]);

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
  // OneDrive for Business / SharePoint download hosts. No Dropbox provider
  // exists, so its suffixes were removed (SA-WEB-01, allowlist trim).
  '.sharepoint.com',
];

function isAllowed(host) {
  if (ALLOWED_HOSTS.has(host)) return true;
  for (const suffix of ALLOWED_HOST_SUFFIXES) {
    if (host.endsWith(suffix)) return true;
  }
  return false;
}

// Security headers for every response this Worker serves.
//
// The share viewer had none: no CSP, no HSTS, no nosniff, no frame control.
// It is the surface that handles ciphertext and, in the browser, the
// decryption key, so it should not be weaker than the marketing site
// (SA-WEB / MASVS report W-02).
//
// CSP is deliberately tight: this page loads two same-origin scripts, one
// same-origin font, and its own images, and it must be able to render a
// decrypted blob: URL for the preview and download. It talks to nothing
// except its own origin, because /proxy is same-origin.
// The OAuth callback page carries one inline script: the three lines that
// build the intent:// URL for the "Open CipherNest" button. `script-src
// 'self'` alone would block it and silently break OneDrive sign-in, so its
// exact SHA-256 is allowed and nothing else is. Change that script and this
// hash must change with it, or sign-in stops working.
//   Recompute: sha256 of the bytes between <script> and </script>, base64.
const OAUTH_INLINE_SCRIPT_HASH =
  "'sha256-cliF2edZN1dFlRXaqfps0st6nHIzEiyxDGMGwgzPjVM='";

const SECURITY_HEADERS = {
  'Content-Security-Policy': [
    "default-src 'self'",
    // 'wasm-unsafe-eval' is required for WebAssembly.compile, which the
    // bundled Argon2 (hash-wasm) uses to derive the key for a
    // password-protected share. Without it the CSP blocks the module and
    // password shares fail in the browser with a compile error, which is
    // exactly what shipping this header without testing that path caused.
    // It permits WASM compilation only; it does NOT enable eval() or
    // inline script, so the policy stays tight.
    `script-src 'self' 'wasm-unsafe-eval' ${OAUTH_INLINE_SCRIPT_HASH}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' blob: data:",
    "media-src 'self' blob:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'none'",
  ].join('; '),
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy': 'geolocation=(), camera=(), microphone=(), interest-cohort=()',
  'X-Frame-Options': 'DENY',
};

function withSecurityHeaders(response) {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) headers.set(k, v);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

// Some link handlers (WhatsApp Desktop, Messenger, various URL wrappers)
// percent-encode the '#' that starts a share link's fragment. When they do,
// the fragment stops being a fragment: the decryption key travels in the
// REQUEST PATH, where this Worker and Cloudflare's logs can see it. That
// breaks the one guarantee the product repeats most often, that the key is
// never sent to a server (MASVS report W-01).
//
// share.js already recovers from this client-side, but only after the
// damage. Redirecting first gets the browser onto a clean URL immediately,
// so the key is not re-sent on every subsequent asset request and does not
// end up in the page's own address bar or history.
//
// This cannot unsend the request that carried it. Keys that may already have
// transited a log have to be treated as disclosed and the shares re-minted.
function normalizeEncodedFragment(url) {
  const marker = url.pathname.indexOf('%23');
  if (marker < 0) return null;
  const path = url.pathname.slice(0, marker);
  const fragment = decodeURIComponent(url.pathname.slice(marker + 3));
  const target = new URL(url.toString());
  target.pathname = path;
  target.hash = fragment;
  return new Response(null, {
    status: 302,
    headers: {
      Location: target.toString(),
      'Cache-Control': 'no-store',
      ...SECURITY_HEADERS,
    },
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    const normalized = normalizeEncodedFragment(url);
    if (normalized) return normalized;

    if (url.hostname === AUTH_HOST) {
      if (url.pathname !== AUTH_PATH && !AUTH_ASSETS.has(url.pathname)) {
        return new Response('Not found', { status: 404 });
      }
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        return new Response('Method not allowed', { status: 405 });
      }
      return withSecurityHeaders(await env.ASSETS.fetch(request));
    }

    if (url.pathname === '/proxy') {
      // No OPTIONS handler any more: the viewer and /proxy are same-origin,
      // so no browser ever sends a preflight for it. The old one answered
      // with a wildcard and advertised the endpoint to every origin
      // (SA-WEB-01 step 2).
      if (request.method === 'GET') return handleProxy(url, request);
      return new Response('Method not allowed', { status: 405 });
    }

    // Everything else: static assets. SPA fallback handled by
    // wrangler.jsonc's assets.not_found_handling.
    return withSecurityHeaders(await env.ASSETS.fetch(request));
  },
};


// Chrome-flavored User-Agent. Drive serves different content to non-browser
// UAs: a sign-in page instead of the file bytes for an anonymous download.
const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

const MAX_REDIRECTS = 10;

// Fetches an upstream blob, following redirects by hand and carrying cookies
// forward.
//
// Microsoft's migrated consumer accounts answer the first request with a
// redirect chain that sets a session cookie, and serve the file only when
// that cookie comes back. `redirect: 'follow'` does not carry Set-Cookie
// between hops, so this proxy kept receiving the HTML interstitial and the
// viewer reported it as a sign-in page. OneDrive sharing looked broken for
// months because of it, and it was never a URL-format problem: a browser
// carried the cookie and saw the file the whole time.
//
// Measured, and worth recording because it is counter-intuitive: this jar
// stays EMPTY on Cloudflare. Workers do not expose Set-Cookie from
// subrequest responses, so getSetCookie() returns nothing on every hop,
// with caching on and off. Freshly minted OneDrive shares are served
// anyway, so the handshake is evidently not required for them; a stale or
// already-redeemed link behaves differently and returns the interstitial.
//
// The loop earns its place regardless: following by hand is what lets every
// hop be checked against the allowlist. `redirect: 'follow'` validated only
// the first URL, so a redirect could previously walk the proxy anywhere.
async function fetchFollowingCookies(startUrl) {
  let current = startUrl;
  const jar = new Map();

  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const headers = {
      'User-Agent': BROWSER_UA,
      Accept: '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
    };
    if (jar.size) {
      headers.Cookie = [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
    }

    const res = await fetch(current.toString(), {
      method: 'GET',
      redirect: 'manual',
      headers,
      // Cloudflare strips Set-Cookie from responses it considers cacheable,
      // and the whole point of this loop is reading Set-Cookie. Without
      // these the jar stays empty and the upstream keeps serving its
      // sign-in interstitial. Diagnosed from a trace showing 0 cookies on
      // every hop.
      cf: { cacheTtl: 0 },
    });

    for (const raw of res.headers.getSetCookie?.() ?? []) {
      const [pair] = raw.split(';');
      const eq = pair.indexOf('=');
      if (eq > 0) jar.set(pair.slice(0, eq).trim(), pair.slice(eq + 1).trim());
    }

    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get('Location');
      if (!loc) throw new Error('Upstream redirected with no target');
      // Relative targets are normal here: one hop in the OneDrive chain is
      // path-only.
      current = new URL(loc, current);
      if (!isAllowed(current.host)) {
        throw new Error('Upstream redirected to a host not allowed: ' + current.host);
      }
      continue;
    }

    return res;
  }
  throw new Error('Upstream redirected too many times');
}

// Origins allowed to drive the proxy. The viewer and /proxy are the same
// origin, so nothing legitimate is ever cross-origin here (SA-WEB-01 step 3).
//
// Stated plainly, because it is easy to overrate: this is a filter, not a
// boundary. Browsers enforce it on themselves; curl and scripts ignore
// Origin entirely and can forge it. It stops a malicious WEB PAGE using this
// Worker as a relay. It does not stop a script. Rate limiting and a bot
// challenge are what stop scripts, and both live in the Cloudflare dashboard
// rather than in this file.
const SELF_ORIGIN = 'https://share.ciphernest.io';

function originAllowed(request) {
  const origin = request.headers.get('Origin');
  if (origin && origin !== SELF_ORIGIN) return false;
  const site = request.headers.get('Sec-Fetch-Site');
  if (site && site !== 'same-origin' && site !== 'none') return false;
  return true;
}

// Share-blob header bytes the proxy is willing to relay.
//   0x01  v1: [1 ver][4 region-len][region]
//   0x02  v2: [1 ver][8 expiry epoch-ms BE][4 region-len][region]
const SHARE_V1 = 0x01;
const SHARE_V2 = 0x02;
const SHARE_HEAD_BYTES = 13;

async function handleProxy(url, request) {
  if (!originAllowed(request)) {
    return new Response('Forbidden', { status: 403 });
  }

  const target = url.searchParams.get('u');
  if (!target) return new Response('Missing u parameter', { status: 400 });

  let parsed;
  try {
    parsed = new URL(target);
  } catch {
    return new Response('Bad target URL', { status: 400 });
  }

  if (parsed.protocol !== 'https:') {
    return new Response('Only https targets are relayed', { status: 403 });
  }
  if (!isAllowed(parsed.host)) {
    return new Response('Host not allowed: ' + parsed.host, { status: 403 });
  }

  let upstream;
  try {
    upstream = await fetchFollowingCookies(parsed);
  } catch (e) {
    return new Response(String(e.message || e), { status: 502 });
  }

  if (!upstream.body) {
    return new Response('Upstream returned no body', { status: 502 });
  }

  // Read just enough of the body to inspect the share header, then stream the
  // rest untouched. Buffering the whole blob would work and would also mean
  // holding a video in memory for no reason.
  const reader = upstream.body.getReader();
  const head = [];
  let headLen = 0;
  let done = false;
  while (headLen < SHARE_HEAD_BYTES && !done) {
    const r = await reader.read();
    if (r.done) {
      done = true;
      break;
    }
    head.push(r.value);
    headLen += r.value.length;
  }
  const headBytes = new Uint8Array(headLen);
  {
    let at = 0;
    for (const c of head) {
      headBytes.set(c, at);
      at += c.length;
    }
  }

  // Refuse to relay anything that is not a CipherNest share blob
  // (SA-WEB-01 step 6). Before this, any public file on an allowlisted host
  // could be pulled through the Worker, which made it a general-purpose
  // download relay for Google Drive. It also catches the cloud host's HTML
  // sign-in or virus-warning interstitials without needing to trust the
  // Content-Type it claimed.
  const version = headBytes[0];
  if (headLen === 0 || (version !== SHARE_V1 && version !== SHARE_V2)) {
    const snippet = new TextDecoder('utf-8')
      .decode(headBytes.subarray(0, Math.min(64, headLen)))
      .replace(/[\r\n]+/g, ' ')
      .slice(0, 60);
    return new Response('Not a CipherNest share blob', {
      status: 403,
      headers: {
        'Content-Type': 'text/plain',
        'Cache-Control': 'no-store',
        'X-CipherNest-Debug': snippet,
      },
    });
  }

  // Expiry, enforced server-side (SA-WEB-02). v2 carries the deadline in the
  // blob, where the recipient cannot edit it, unlike the fragment copy they
  // could simply delete. Not absolute: someone who saved the direct cloud URL
  // bypasses this Worker entirely and still holds the key. Deleting the blob,
  // which the sender's sweep does, remains the only real revocation.
  if (version === SHARE_V2 && headLen >= 9) {
    const expiryMs = Number(
      new DataView(headBytes.buffer, headBytes.byteOffset + 1, 8).getBigUint64(0, false),
    );
    if (expiryMs !== 0 && Date.now() > expiryMs) {
      return new Response('This share link has expired.', {
        status: 410,
        headers: { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' },
      });
    }
  }

  // Re-attach the bytes already read, then hand over the rest of the stream.
  const body = new ReadableStream({
    start(controller) {
      if (headLen) controller.enqueue(headBytes);
      if (done) controller.close();
    },
    async pull(controller) {
      const r = await reader.read();
      if (r.done) {
        controller.close();
        return;
      }
      controller.enqueue(r.value);
    },
    cancel(reason) {
      return reader.cancel(reason);
    },
  });

  const headers = new Headers();
  headers.set('Content-Type', 'application/octet-stream');
  const len = upstream.headers.get('Content-Length');
  if (len) headers.set('Content-Length', len);
  headers.set('Cache-Control', 'no-store');
  headers.set('X-Content-Type-Options', 'nosniff');
  // No Access-Control-Allow-Origin. The viewer and this endpoint are the same
  // origin, so CORS does not apply to the only legitimate caller, and the
  // wildcard was letting any page on the internet read the response
  // (SA-WEB-01 step 2).

  return new Response(body, { status: upstream.status, headers });
}
