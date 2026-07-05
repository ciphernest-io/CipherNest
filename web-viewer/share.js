// ----------------------------------------------------------------------------
// CipherNest web viewer — decrypts magic-link shares entirely in the browser.
//
// URL layout: https://ciphernest.pages.dev/s/<base64UrlDownloadUrl>#k=...&exp=...
//                                                        OR     #p=...&exp=...
//
// Plain mode (k=): the URL fragment carries the raw 32-byte share key. We
// download the encrypted blob via the /proxy CORS function, decrypt the 60-byte
// wrapped file key in the header, then decrypt each chunked AES-GCM body
// segment.
//
// Password mode (p=): the URL fragment carries only the salt. The recipient
// types the password; we'd need Argon2id to derive the key. The browser's
// SubtleCrypto does not implement Argon2id, and we want to keep this viewer
// dependency-free, so we tell the recipient to open the link in the
// CipherNest app instead.
// ----------------------------------------------------------------------------

const ENCRYPTED_CHUNK_SIZE = 524316; // 512 KiB plaintext + 12-byte nonce + 16-byte MAC
const NONCE_SIZE = 12;
const MAC_SIZE = 16;

const $ = (id) => document.getElementById(id);
const status = $('status');
const statusText = $('statusText');
const passwordForm = $('passwordForm');
const preview = $('preview');
const actions = $('actions');
const downloadBtn = $('downloadBtn');
const openInAppBtn = $('openInAppBtn');

let lastDecryptedBlob = null;
let lastFilename = 'shared-file';

document.addEventListener('DOMContentLoaded', () => {
  try {
    main();
  } catch (e) {
    showError('Could not parse this link. ' + e.message);
  }
});

function main() {
  let path = location.pathname; // /s/<encoded>
  let rawFragment = location.hash.replace(/^#/, '');

  // Some link handlers (WhatsApp Desktop, Messenger, various URL wrappers)
  // percent-encode the `#` fragment marker into `%23` so the whole fragment
  // ends up embedded in the path. Detect and split.
  const encodedHashIdx = path.indexOf('%23');
  if (encodedHashIdx >= 0 && !rawFragment) {
    rawFragment = decodeURIComponent(path.substring(encodedHashIdx + 3));
    path = path.substring(0, encodedHashIdx);
  }

  const segments = path.split('/').filter(Boolean);
  if (segments.length < 2 || segments[0] !== 's') {
    return showError('This page expects a share link of the form /s/...');
  }
  // Percent-decode the encoded download URL segment before base64. Handles
  // `%3D` for `=` padding, `%2F` for `/`, etc. — anything a URL-mangling
  // intermediary might have introduced.
  const encodedDownload = decodeURIComponent(segments[1]);
  let downloadUrl;
  try {
    downloadUrl = b64UrlDecodeUtf8(encodedDownload);
  } catch (e) {
    return showError(
      'This share link is malformed. Something between the sender and you ' +
      'may have mangled the URL — try opening it directly in a browser ' +
      "instead of a chat app's link preview. (base64 error: " + e.message + ')'
    );
  }

  const fragParams = parseFragment(rawFragment);
  const expStr = fragParams.exp;
  if (expStr) {
    const expMs = parseInt(expStr, 10);
    if (Number.isFinite(expMs) && Date.now() > expMs) {
      return showError('This share link has expired.');
    }
  }

  if (fragParams.p) {
    // Password-protected — Argon2 isn't built into SubtleCrypto and we want
    // this viewer to remain dependency-free. Direct recipient to the app.
    showOpenInApp(
      'This share is password-protected. ' +
      'Open the link in the CipherNest Android app to enter the password.'
    );
    return;
  }
  if (!fragParams.k) {
    return showError('Missing decryption key in the URL fragment.');
  }

  const shareKeyBytes = b64UrlDecodeBytes(fragParams.k);
  decryptAndRender(downloadUrl, shareKeyBytes).catch((e) => {
    console.error(e);
    showError('Decryption failed: ' + (e?.message || e));
  });
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

async function decryptAndRender(downloadUrl, shareKeyBytes) {
  setStatus('Fetching encrypted blob…', true);
  const blob = await fetchViaProxy(downloadUrl);

  setStatus('Decrypting in your browser…', true);
  const shareKey = await crypto.subtle.importKey(
    'raw',
    shareKeyBytes,
    { name: 'AES-GCM' },
    false,
    ['decrypt']
  );

  // Header layout: [4-byte big-endian length] [60-byte wrapped fileKey]
  const headerLen = readU32BE(blob, 0);
  const headerEnd = 4 + headerLen;
  const wrappedFileKey = blob.subarray(4, headerEnd);
  const fileKeyBytes = await aesGcmDecrypt(shareKey, wrappedFileKey);
  const fileKey = await crypto.subtle.importKey(
    'raw',
    fileKeyBytes,
    { name: 'AES-GCM' },
    false,
    ['decrypt']
  );

  const body = blob.subarray(headerEnd);
  const plaintext = await decryptBody(fileKey, body);

  hide(status);
  await render(plaintext);
}

async function decryptBody(fileKey, body) {
  // The sender uses TWO different body layouts depending on file type:
  //   - Images / small files:  EncryptionService.encryptFile writes one
  //                            AES-GCM output covering the WHOLE body:
  //                              [12-byte nonce][ciphertext][16-byte tag]
  //   - Videos / streaming:    EncryptionService.encryptStream splits the
  //                            plaintext into 512 KiB chunks, each becomes
  //                              [12-byte nonce][ct][16-byte tag]
  //                            of up to 524316 bytes on disk.
  //
  // Any body that fits inside a single chunk (≤ 524316 bytes total,
  // including the nonce+tag overhead) is decryptable as a single
  // AES-GCM call. Chunked bodies are only ever >524316 bytes, and the
  // last chunk may be shorter. So the heuristic is safe:
  //   body.length ≤ ENCRYPTED_CHUNK_SIZE → single-shot
  //   body.length >  ENCRYPTED_CHUNK_SIZE → chunked
  if (body.length <= ENCRYPTED_CHUNK_SIZE) {
    return await aesGcmDecrypt(fileKey, body);
  }
  const parts = [];
  let offset = 0;
  while (offset < body.length) {
    const remaining = body.length - offset;
    const chunkSize = Math.min(remaining, ENCRYPTED_CHUNK_SIZE);
    const chunk = body.subarray(offset, offset + chunkSize);
    const plain = await aesGcmDecrypt(fileKey, chunk);
    parts.push(plain);
    offset += chunkSize;
  }
  // Concatenate
  let total = 0;
  for (const p of parts) total += p.byteLength;
  const out = new Uint8Array(total);
  let cursor = 0;
  for (const p of parts) {
    out.set(p, cursor);
    cursor += p.byteLength;
  }
  return out;
}

async function aesGcmDecrypt(key, input) {
  // input layout: [12-byte nonce][ciphertext][16-byte tag]
  if (input.length < NONCE_SIZE + MAC_SIZE) throw new Error('chunk too short');
  const nonce = input.subarray(0, NONCE_SIZE);
  const ctAndTag = input.subarray(NONCE_SIZE);
  const buf = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce, tagLength: 128 },
    key,
    ctAndTag
  );
  return new Uint8Array(buf);
}

// ---------------------------------------------------------------------------
// Network — uses Cloudflare Pages Function /proxy?u=... to add CORS headers
// since Google Drive / OneDrive direct download URLs do not allow cross-origin
// fetches by default.
// ---------------------------------------------------------------------------

async function fetchViaProxy(downloadUrl) {
  const proxyUrl = '/proxy?u=' + encodeURIComponent(downloadUrl);
  const resp = await fetch(proxyUrl, { credentials: 'omit' });
  if (!resp.ok) throw new Error('Server returned ' + resp.status);
  // Detect when the cloud host returned an HTML interstitial (Google Drive
  // virus-scan warning, OneDrive sign-in page, etc.) instead of the real blob.
  const contentType = resp.headers.get('Content-Type') || '';
  if (contentType.includes('text/html')) {
    // Surface the diagnostic headers the proxy attached so we can see
    // exactly what the cloud returned — sign-in page, virus scan warning,
    // access denied, etc.
    const debug = resp.headers.get('X-CipherNest-Debug') || '(no snippet)';
    const finalUrl = resp.headers.get('X-CipherNest-Final-Url') || '(unknown)';
    console.error('Cloud returned HTML. Final URL:', finalUrl);
    console.error('First 300 bytes:', debug);
    throw new Error(
      'The cloud host returned an HTML page instead of the encrypted file. ' +
      'Final URL: ' + finalUrl + '. First bytes: ' + debug
    );
  }
  const buf = await resp.arrayBuffer();
  return new Uint8Array(buf);
}

// ---------------------------------------------------------------------------
// Render — sniff content-type from magic bytes, render inline where possible.
// ---------------------------------------------------------------------------

async function render(bytes) {
  const kind = sniffKind(bytes);
  const mime = mimeForKind(kind);
  const blob = new Blob([bytes], { type: mime });
  const url = URL.createObjectURL(blob);
  lastDecryptedBlob = blob;
  lastFilename = 'shared-file' + extForKind(kind);

  preview.classList.remove('hidden');
  actions.classList.remove('hidden');
  preview.innerHTML = '';

  if (kind === 'image') {
    const img = document.createElement('img');
    img.src = url;
    preview.appendChild(img);
  } else if (kind === 'video') {
    const v = document.createElement('video');
    v.src = url;
    v.controls = true;
    v.preload = 'metadata';
    preview.appendChild(v);
  } else if (kind === 'audio') {
    const a = document.createElement('audio');
    a.src = url;
    a.controls = true;
    preview.appendChild(a);
  } else {
    const row = document.createElement('div');
    row.className = 'file-row';
    row.innerHTML =
      '<div class="file-icon">📄</div>' +
      '<div class="file-meta">' +
        '<div class="name">' + escapeHtml(lastFilename) + '</div>' +
        '<div class="size">' + humanSize(bytes.byteLength) + '</div>' +
      '</div>';
    preview.appendChild(row);
  }

  downloadBtn.onclick = () => {
    const a = document.createElement('a');
    a.href = url;
    a.download = lastFilename;
    document.body.appendChild(a);
    a.click();
    a.remove();
  };
}

function sniffKind(b) {
  if (b.length < 12) return 'unknown';
  // JPEG
  if (b[0] === 0xFF && b[1] === 0xD8 && b[2] === 0xFF) return 'image';
  // PNG
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4E && b[3] === 0x47) return 'image';
  // GIF
  if (b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46) return 'image';
  // WebP
  if (b[0] === 0x52 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x46 &&
      b[8] === 0x57 && b[9] === 0x45 && b[10] === 0x42 && b[11] === 0x50) return 'image';
  // ftyp boxes — check sub-brand
  if (b[4] === 0x66 && b[5] === 0x74 && b[6] === 0x79 && b[7] === 0x70) {
    const brand = String.fromCharCode(b[8], b[9], b[10], b[11]);
    if (brand === 'heic' || brand === 'heix' || brand === 'mif1') return 'image';
    return 'video';
  }
  // PDF
  if (b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) return 'document';
  // ID3 / MP3
  if (b[0] === 0x49 && b[1] === 0x44 && b[2] === 0x33) return 'audio';
  if (b[0] === 0xFF && (b[1] & 0xE0) === 0xE0) return 'audio';
  // OGG
  if (b[0] === 0x4F && b[1] === 0x67 && b[2] === 0x67 && b[3] === 0x53) return 'audio';
  // FLAC
  if (b[0] === 0x66 && b[1] === 0x4C && b[2] === 0x61 && b[3] === 0x43) return 'audio';
  return 'unknown';
}

function mimeForKind(k) {
  switch (k) {
    case 'image': return 'image/jpeg';
    case 'video': return 'video/mp4';
    case 'audio': return 'audio/mpeg';
    case 'document': return 'application/pdf';
    default: return 'application/octet-stream';
  }
}

function extForKind(k) {
  switch (k) {
    case 'image': return '.jpg';
    case 'video': return '.mp4';
    case 'audio': return '.mp3';
    case 'document': return '.pdf';
    default: return '.bin';
  }
}

// ---------------------------------------------------------------------------
// UI helpers
// ---------------------------------------------------------------------------

function setStatus(text, spinning) {
  statusText.textContent = text;
  status.classList.remove('hidden');
  status.querySelector('.spinner').style.display = spinning ? '' : 'none';
}

function showError(msg) {
  status.classList.remove('hidden');
  status.innerHTML = '<span class="error">⚠ ' + escapeHtml(msg) + '</span>';
}

function showOpenInApp(message) {
  status.classList.remove('hidden');
  status.innerHTML = '<span>' + escapeHtml(message) + '</span>';
  actions.classList.remove('hidden');
  openInAppBtn.classList.remove('hidden');
  downloadBtn.classList.add('hidden');
  openInAppBtn.onclick = () => {
    // Convert https:// link to ciphernest:// custom scheme so the app picks it up.
    const u = new URL(location.href);
    u.protocol = 'ciphernest:';
    location.href = u.toString();
  };
}

function hide(el) { el.classList.add('hidden'); }

function escapeHtml(s) {
  return String(s)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function humanSize(n) {
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
  if (n < 1024 * 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
  return (n / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

function parseFragment(frag) {
  const out = {};
  for (const part of frag.split('&')) {
    const eq = part.indexOf('=');
    if (eq <= 0) continue;
    out[part.substring(0, eq)] = part.substring(eq + 1);
  }
  return out;
}

function b64UrlToB64(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  return s;
}

function b64UrlDecodeBytes(s) {
  const bin = atob(b64UrlToB64(s));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function b64UrlDecodeUtf8(s) {
  const bytes = b64UrlDecodeBytes(s);
  return new TextDecoder('utf-8').decode(bytes);
}

function readU32BE(buf, offset) {
  return ((buf[offset] << 24) |
          (buf[offset + 1] << 16) |
          (buf[offset + 2] << 8) |
          (buf[offset + 3])) >>> 0;
}
