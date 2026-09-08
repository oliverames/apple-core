// SPDX-License-Identifier: GPL-3.0-or-later
// Routing is never authorization: the destination Mac verifies the inner token.
export const ORIGIN = "https://mcp.applecore.app";
export const RESOURCE = `${ORIGIN}/mcp`;
export const MAX_BODY = 1024 * 1024;
export const MAX_RESPONSE = 8 * 1024 * 1024;
export const TENANT = /^[a-f0-9]{32}$/;
export const REQUEST_HEADERS = ["authorization", "content-type", "accept", "mcp-session-id", "mcp-protocol-version"];
export const RESPONSE_HEADERS = ["content-type", "mcp-session-id", "www-authenticate", "location", "allow"];

export function routed(value) {
  if (typeof value !== "string" || value.length > 16384) return null;
  const index = value.indexOf("~");
  const id = value.slice(0, index);
  const token = value.slice(index + 1);
  return TENANT.test(id) && token && index === 32 ? { id, token } : null;
}

export function wrap(id, token) {
  if (!TENANT.test(id) || typeof token !== "string" || !token) throw new Error("Invalid route");
  return `${id}~${token}`;
}

export function relayPathAllowed(method, path) {
  return (path === "/mcp" && ["POST", "DELETE"].includes(method))
    || (path === "/oauth/authorize" && ["GET", "POST"].includes(method))
    || (["/oauth/token", "/oauth/revoke"].includes(path) && method === "POST");
}

export function pickHeaders(headers, names) {
  return Object.fromEntries(names.flatMap(name => headers.has(name) ? [[name, headers.get(name)]] : []));
}

export function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

export async function readBounded(request, limit = MAX_BODY) {
  if (Number(request.headers.get("content-length")) > limit) throw new Error("Body too large");
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > limit) { await reader.cancel(); throw new Error("Body too large"); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}

export function base64(bytes) {
  let result = "";
  for (let i = 0; i < bytes.length; i += 8192) result += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(result);
}

export function unbase64(value) {
  return Uint8Array.from(atob(value), c => c.charCodeAt(0));
}

export function secret() {
  return base64(crypto.getRandomValues(new Uint8Array(32))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export async function digest(value) {
  return base64(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))));
}

export async function matchesSecret(value, hash) {
  if (!hash || typeof value !== "string" || value.length > 512) return false;
  const actual = await digest(value);
  let mismatch = actual.length ^ hash.length;
  for (let i = 0; i < actual.length; i++) mismatch |= actual.charCodeAt(i) ^ (hash.charCodeAt(i) || 0);
  return mismatch === 0;
}

// The Mac validates the registered redirect before presenting authorization.
// Browsers also apply form-action to the subsequent OAuth redirect.
export function authorizationCSP(redirectURI) {
  let destination = "";
  try {
    const url = new URL(redirectURI);
    if (url.protocol === "https:" || (url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname))) destination = ` ${url.origin}`;
  } catch {}
  return `default-src 'none'; style-src 'unsafe-inline'; img-src 'self'; form-action 'self'${destination}; frame-ancestors 'none'; base-uri 'none'`;
}
