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

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.hostname === AUTH_HOST) {
      if (url.pathname !== AUTH_PATH) {
        return new Response('Not found', { status: 404 });
      }
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        return new Response('Method not allowed', { status: 405 });
      }
      return env.ASSETS.fetch(request);
    }

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

function corsPreflight() {
  return new Response(null, {
    status: 204,
    headers: {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
      'Access-Control-Allow-Headers': '*',
      'Access-Control-Max-Age': '86400',
    },
  });
}

async function handleProxy(url) {
  const target = url.searchParams.get('u');
  if (!target) return new Response('Missing u parameter', { status: 400 });

  let parsed;
  try {
    parsed = new URL(target);
  } catch {
    return new Response('Bad target URL', { status: 400 });
  }

  if (!isAllowed(parsed.host)) {
    return new Response('Host not allowed: ' + parsed.host, { status: 403 });
  }

  // Chrome-flavored User-Agent — Drive can serve different content for
  // non-browser UAs (sign-in HTML instead of the file bytes for anonymous
  // downloads). Real Chrome UA sidesteps that.
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

  const upstreamContentType =
    upstream.headers.get('Content-Type') || 'application/octet-stream';

  // If the cloud host returned HTML, sniff the first 300 bytes into a
  // custom header so the recipient page can show WHAT the cloud sent
  // (sign-in page, virus warning, access denied, etc.).
  let debugSnippet = '';
  let bodyToReturn = upstream.body;
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

  const headers = new Headers();
  headers.set('Content-Type', upstreamContentType);
  const len = upstream.headers.get('Content-Length');
  if (len) headers.set('Content-Length', len);
  headers.set('Access-Control-Allow-Origin', '*');
  headers.set(
    'Access-Control-Expose-Headers',
    'X-CipherNest-Debug, X-CipherNest-Final-Url',
  );
  headers.set('Cache-Control', 'no-store');
  headers.set('X-CipherNest-Final-Url', upstream.url);
  if (debugSnippet) headers.set('X-CipherNest-Debug', debugSnippet);

  return new Response(bodyToReturn, {
    status: upstream.status,
    headers,
  });
}
