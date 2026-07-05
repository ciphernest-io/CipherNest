// Cloudflare Pages Function — CORS proxy for share blobs.
//
// Google Drive direct-download URLs and OneDrive sharing URLs return
// `Access-Control-Allow-Origin` headers that block our static site from
// fetching them via XHR. This function forwards the request server-side and
// re-emits the body with permissive CORS so the browser viewer can read it.
//
// Endpoint: GET /proxy?u=<urlEncodedDownloadUrl>
//
// Hardening: only host names from a small allow-list are proxied. This
// prevents the function from being abused as an open relay.

const ALLOWED_HOSTS = new Set([
  'drive.google.com',
  'drive.usercontent.google.com', // direct-content host, bypasses interstitial
  'www.googleapis.com',     // alternate Drive download endpoint
  'docs.google.com',        // Drive sometimes 302s here
  'lh3.googleusercontent.com',
  'onedrive.live.com',
  '1drv.ms',
  'api.onedrive.com',
  'graph.microsoft.com',
  // Microsoft Sharepoint personal storage host pattern (covered below by suffix)
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

export async function onRequestGet({ request }) {
  const url = new URL(request.url);
  const target = url.searchParams.get('u');
  if (!target) {
    return new Response('Missing u parameter', { status: 400 });
  }

  let parsed;
  try {
    parsed = new URL(target);
  } catch {
    return new Response('Bad target URL', { status: 400 });
  }

  if (!isAllowed(parsed.host)) {
    return new Response('Host not allowed: ' + parsed.host, { status: 403 });
  }

  // Forward the request, following redirects. Use a Chrome-flavored
  // User-Agent because Drive occasionally serves different content to
  // generic/bot User-Agents — anonymous public downloads sometimes get
  // an HTML "sign in required" page for non-browser UAs.
  const upstream = await fetch(parsed.toString(), {
    method: 'GET',
    redirect: 'follow',
    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
    },
  });

  const upstreamContentType =
    upstream.headers.get('Content-Type') || 'application/octet-stream';

  // Diagnostic: if the upstream returned HTML instead of the encrypted
  // blob, sniff the first ~300 bytes and expose them in a response
  // header so we can see exactly what Drive is complaining about in
  // DevTools Network tab (and forward the HTML through as-is, so the
  // client's existing "returned HTML" check still fires).
  let debugSnippet = '';
  let bodyToReturn = upstream.body;
  if (upstreamContentType.includes('text/html')) {
    const buf = await upstream.arrayBuffer();
    const bytes = new Uint8Array(
      buf,
      0,
      Math.min(400, buf.byteLength),
    );
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
  if (debugSnippet) {
    headers.set('X-CipherNest-Debug', debugSnippet);
  }

  return new Response(bodyToReturn, {
    status: upstream.status,
    headers,
  });
}

export function onRequestOptions() {
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
