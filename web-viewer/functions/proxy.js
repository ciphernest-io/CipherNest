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

  // Forward the request, following redirects (Drive uses redirects to the
  // actual content host for `uc?export=download`).
  const upstream = await fetch(parsed.toString(), {
    method: 'GET',
    redirect: 'follow',
    headers: {
      'User-Agent': 'CipherNest-WebViewer/1.0',
      'Accept': '*/*',
    },
  });

  // Stream the body straight back, dropping cookies and any sensitive headers.
  const headers = new Headers();
  headers.set('Content-Type',
    upstream.headers.get('Content-Type') || 'application/octet-stream');
  const len = upstream.headers.get('Content-Length');
  if (len) headers.set('Content-Length', len);
  headers.set('Access-Control-Allow-Origin', '*');
  headers.set('Cache-Control', 'no-store');

  return new Response(upstream.body, {
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
