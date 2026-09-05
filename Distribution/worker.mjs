// SPDX-License-Identifier: GPL-3.0-or-later
const PRODUCT = 'H5iMAgmqjSc9_p61iSwApA==';
const PUBLIC_KEY = 'qBn20Q2xAdkaU3U/wonWVTSTrbphkWCgnDldhI6RAsk=';
const HEADER = 'X-Apple-Core-License';
const encoder = new TextEncoder();

export function isProtectedPath(path) {
  // Both R2 custom domains route through this worker. Decode before deciding
  // whether a request targets the protected prefix, including encoded slashes.
  for (let i = 0; i < 4; i++) {
    const decoded = decodeURIComponent(path);
    if (decoded === path) break;
    path = decoded;
  }
  return path.split('/').filter(Boolean).includes('apple-core');
}

export function paidPurchase(result) {
  const p = result?.purchase;
  if (result?.success !== true || !p || p.product_id !== PRODUCT ||
      typeof (p.sale_id ?? p.id) !== 'string' || !(p.sale_id ?? p.id)) return false;
  for (const flag of ['refunded', 'chargebacked', 'disputed', 'test', 'is_preorder_authorization']) {
    if (p[flag] != null && p[flag] !== false) return false;
  }
  for (const field of ['subscription_ended_at', 'subscription_cancelled_at', 'subscription_failed_at']) {
    if (p[field] != null) return false;
  }
  return Number.isSafeInteger(p.price) && (p.price > 0 ||
    (p.is_gift_receiver_purchase === true && Number.isSafeInteger(p.gift_price) && p.gift_price > 0));
}

function bytes(base64) {
  return Uint8Array.from(atob(base64), c => c.charCodeAt(0));
}

export async function signedLicense(value, publicKey = PUBLIC_KEY, now = Date.now()) {
  try {
    const envelope = new TextDecoder('utf-8', {fatal: true}).decode(bytes(value));
    const lines = envelope.trim().split(/\r?\n/);
    if (lines.length !== 3 || lines[0] !== 'APPLE-CORE-LICENSE-1') return false;
    const payload = bytes(lines[1]);
    const signature = bytes(lines[2]);
    if (payload.length > 8192 || signature.length !== 64) return false;
    const key = await crypto.subtle.importKey('raw', bytes(publicKey), 'Ed25519', false, ['verify']);
    if (!await crypto.subtle.verify('Ed25519', key, signature, payload)) return false;
    const document = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(payload));
    return document.product === 'apple-core' && typeof document.license_id === 'string' &&
      document.license_id.length > 0 &&
      (document.expires_at == null || Date.parse(document.expires_at) >= now);
  } catch { return false; }
}

async function boundedJSON(response) {
  if (!response.body) throw new Error('Empty response');
  const reader = response.body.getReader();
  const chunks = [];
  let length = 0;
  try {
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > 65536) throw new Error('Oversized response');
      chunks.push(value);
    }
  } finally { await reader.cancel(); }
  const data = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
  return JSON.parse(new TextDecoder().decode(data));
}

function failure(status, message) {
  return new Response(message + '\n', {status, headers: {'Cache-Control': 'private, no-store', 'Content-Type': 'text/plain; charset=utf-8'}});
}

export async function handle(request, fetcher = fetch) {
  const url = new URL(request.url);
  let protectedPath;
  try { protectedPath = isProtectedPath(url.pathname); }
  catch { return failure(400, 'Invalid download path.'); }
  if (!protectedPath) return fetcher(request);
  if (url.protocol !== 'https:') return failure(400, 'HTTPS is required.');
  if (!['GET', 'HEAD'].includes(request.method)) return failure(405, 'Use GET or HEAD.');
  const credential = request.headers.get(HEADER);
  if (!credential || credential.length > 16384) {
    return failure(402, 'Purchase and download Apple Core at https://amesconsulting.gumroad.com/l/applecore');
  }
  let valid = false;
  if (/^[A-Z0-9]{8}(?:-[A-Z0-9]{8}){3}$/.test(credential)) {
    try {
      const result = await fetcher('https://api.gumroad.com/v2/licenses/verify', {
        method: 'POST',
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: new URLSearchParams({product_id: PRODUCT, license_key: credential, increment_uses_count: 'false'}),
        signal: AbortSignal.timeout(15000),
        redirect: 'error',
      });
      if (result.status !== 200 && result.status !== 404) return failure(503, 'License verification is temporarily unavailable.');
      valid = paidPurchase(await boundedJSON(result));
    } catch { return failure(503, 'License verification is temporarily unavailable.'); }
  } else {
    valid = await signedLicense(credential);
  }
  if (!valid) return failure(403, 'A valid paid Apple Core license is required.');
  // Never send the buyer credential to R2, and never cache an authorized
  // response where a later anonymous request could retrieve it.
  const origin = new Request(request);
  origin.headers.delete(HEADER);
  origin.headers.delete('Authorization');
  const response = await fetcher(origin, {cf: {cacheTtl: 0, cacheEverything: false}});
  const headers = new Headers(response.headers);
  headers.set('Cache-Control', 'private, no-store');
  headers.set('Vary', HEADER);
  return new Response(response.body, {status: response.status, statusText: response.statusText, headers});
}

export default {fetch: request => handle(request)};
