// SPDX-License-Identifier: GPL-3.0-or-later
import { ORIGIN, RESOURCE, TENANT, REQUEST_HEADERS, RESPONSE_HEADERS, routed, wrap, pickHeaders, escapeHTML, readBounded, base64, unbase64, digest, matchesSecret, authorizationCSP } from "./protocol.mjs";
export { MacRelay } from "./relay.mjs";

const json = (value, status = 200) => Response.json(value, { status, headers: { "cache-control": "no-store", "access-control-allow-origin": "*" } });
const error = (name, status = 400) => json({ error: name }, status);
const text = bytes => new TextDecoder().decode(bytes);
const html = body => new Response(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Apple Core</title><link rel="icon" href="/favicon.ico"></head><body><main><h1>Apple Core</h1>${body}</main></body></html>`, {
  headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "content-security-policy": "default-src 'none'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'", "referrer-policy": "no-referrer", "x-content-type-options": "nosniff" },
});

async function signedMetadata(metadata, key) {
  const payload = base64(new TextEncoder().encode(JSON.stringify(metadata))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  const cryptoKey = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = base64(new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(payload)))).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
  return `${payload}.${signature}`;
}

async function verifyMetadata(value, key) {
  const [payload, signature, extra] = value.split(".");
  if (!payload || !signature || extra || value.length > 6000) return null;
  try {
    const cryptoKey = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
    if (!(await crypto.subtle.verify("HMAC", cryptoKey, unbase64(signature.replaceAll("-", "+").replaceAll("_", "/")), new TextEncoder().encode(payload)))) return null;
    return JSON.parse(text(unbase64(payload.replaceAll("-", "+").replaceAll("_", "/"))));
  } catch { return null; }
}

async function relay(env, id, method, path, query, headers, body) {
  const result = await env.MACS.getByName(id).exchange({ method, path, query, headers, body: base64(body) });
  const responseHeaders = new Headers();
  for (const name of RESPONSE_HEADERS) {
    const value = result.headers?.[name];
    if (typeof value === "string" && value.length < 8192) responseHeaders.set(name, value);
  }
  responseHeaders.set("cache-control", "no-store");
  responseHeaders.set("access-control-allow-origin", "*");
  responseHeaders.set("access-control-expose-headers", "mcp-session-id, www-authenticate");
  const chunks = (result.chunks ?? []).map(unbase64);
  return new Response([204, 304].includes(result.status) ? null : new Blob(chunks), { status: result.status, headers: responseHeaders });
}

async function handle(request, env) {
  const url = new URL(request.url);
  if (url.origin !== ORIGIN) return error("invalid_host", 421);
  const path = url.pathname;
  if (request.method === "OPTIONS" && ["/mcp", "/oauth/token", "/oauth/register", "/oauth/revoke"].includes(path)) {
    return new Response(null, { status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET, POST, DELETE, OPTIONS", "access-control-allow-headers": "authorization, content-type, mcp-session-id, mcp-protocol-version", "cache-control": "no-store" } });
  }
  if (path === "/" && request.method === "GET") return html("<p>Connect your Mac to your AI client at <code>https://mcp.applecore.app/mcp</code>.</p><p>Hosted access is in private beta. Your Mac must remain running and connected. Only services you enable are available.</p>");
  if (["/favicon.ico", "/favicon-32x32.png"].includes(path) && ["GET", "HEAD"].includes(request.method)) return env.ASSETS.fetch(request);
  if (path.startsWith("/.well-known/oauth-protected-resource") && request.method === "GET" && ["/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"].includes(path)) return json({ resource: RESOURCE, resource_name: "Apple Core", authorization_servers: [ORIGIN], bearer_methods_supported: ["header"], scopes_supported: ["mcp"] });
  if (path === "/.well-known/oauth-authorization-server" && request.method === "GET") return json({ issuer: ORIGIN, authorization_endpoint: `${ORIGIN}/oauth/authorize`, token_endpoint: `${ORIGIN}/oauth/token`, registration_endpoint: `${ORIGIN}/oauth/register`, revocation_endpoint: `${ORIGIN}/oauth/revoke`, response_types_supported: ["code"], grant_types_supported: ["authorization_code", "refresh_token"], code_challenge_methods_supported: ["S256"], token_endpoint_auth_methods_supported: ["none"], client_id_metadata_document_supported: true, scopes_supported: ["mcp"] });

  // Emergency stop leaves authenticated administration and discovery available.
  if (env.HOSTED_PAUSED === "true" && !path.startsWith("/admin/") && !(path === "/oauth/revoke" && request.method === "POST")) return error("hosting_paused", 503);

  // The rate limiter is applied before storage/RPC/cryptographic work. Never log keys.
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  const mcpRoute = path === "/mcp" ? routed(request.headers.get("authorization")?.replace(/^Bearer /, "")) : null;
  const limit = await env.REQUEST_LIMITER.limit({ key: mcpRoute ? `mcp:${mcpRoute.id}` : `public:${ip}` });
  if (!limit.success) return error("rate_limited", 429);

  if (path.startsWith("/admin/")) {
    if (!env.ADMIN_SECRET || !(await matchesSecret(request.headers.get("authorization")?.replace(/^Bearer /, "") ?? "", await digest(env.ADMIN_SECRET)))) return error("unauthorized", 401);
    if (path === "/admin/invitations" && request.method === "POST") {
      const id = crypto.randomUUID().replaceAll("-", "");
      const code = await env.MACS.getByName(id).invite();
      return json({ setup_code: wrap(id, code), expires_in: 1800 }, 201);
    }
    const usageRoute = /^\/admin\/tenants\/([a-f0-9]{32})\/(usage|pause)$/.exec(path);
    if (usageRoute) {
      const relay = env.MACS.getByName(usageRoute[1]);
      if (usageRoute[2] === "usage" && request.method === "GET") return json(await relay.usageStatus());
      if (usageRoute[2] === "pause" && request.method === "POST") {
        const input = JSON.parse(text(await readBounded(request, 128)));
        if (typeof input.paused !== "boolean") return error("invalid_pause");
        await relay.setPaused(input.paused);
        return json({ paused: input.paused });
      }
      return error("not_found", 404);
    }
    const id = path.slice("/admin/tenants/".length);
    if (path.startsWith("/admin/tenants/") && TENANT.test(id) && request.method === "DELETE") { await env.MACS.getByName(id).revoke(); return new Response(null, { status: 204 }); }
    return error("not_found", 404);
  }

  if (path === "/pair" && request.method === "POST") {
    const input = JSON.parse(text(await readBounded(request, 2048)));
    const route = routed(input.setup_code);
    if (!route) return error("invalid_invitation");
    const credential = await env.MACS.getByName(route.id).pair(route.token);
    if (!credential) return error("invalid_invitation");
    return json({ tenant_id: route.id, relay_credential: credential, endpoint: RESOURCE });
  }
  if (path.startsWith("/bridge/") && request.method === "GET") {
    const id = path.slice(8);
    if (!TENANT.test(id)) return error("not_found", 404);
    return env.MACS.getByName(id).fetch(request);
  }
  if (path === "/oauth/register" && request.method === "POST") {
    if (!env.METADATA_SECRET) return error("temporarily_unavailable", 503);
    const input = JSON.parse(text(await readBounded(request, 4096)));
    if (!Array.isArray(input.redirect_uris) || !input.redirect_uris.length || input.redirect_uris.length > 8 || input.token_endpoint_auth_method && input.token_endpoint_auth_method !== "none") return error("invalid_client_metadata");
    for (const uri of input.redirect_uris) {
      if (typeof uri !== "string" || uri.length > 1024) return error("invalid_redirect_uri");
      const target = new URL(uri);
      if (target.username || target.password || target.hash || !(target.protocol === "https:" || target.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(target.hostname))) return error("invalid_redirect_uri");
    }
    const metadata = { client_name: String(input.client_name ?? "MCP client").slice(0, 128), redirect_uris: input.redirect_uris, token_endpoint_auth_method: "none" };
    const client_id = `${ORIGIN}/clients/${await signedMetadata(metadata, env.METADATA_SECRET)}`;
    return json({ ...metadata, client_id, grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] }, 201);
  }
  if (path.startsWith("/clients/") && request.method === "GET") {
    if (!env.METADATA_SECRET) return error("temporarily_unavailable", 503);
    const metadata = await verifyMetadata(path.slice(9), env.METADATA_SECRET);
    return metadata ? json({ ...metadata, client_id: request.url }) : error("not_found", 404);
  }
  if (path === "/oauth/authorize" && request.method === "GET") {
    const fields = [...url.searchParams].filter(([name]) => ["response_type", "client_id", "redirect_uri", "code_challenge", "code_challenge_method", "state", "resource", "scope"].includes(name));
    if (url.search.length > 12000) return error("invalid_request");
    const id = url.searchParams.get("connection");
    if (!id) return html(`<p>Enter the Connection ID shown in Apple Core on your Mac.</p><form method="get" action="/oauth/authorize">${fields.map(([name, value]) => `<input type="hidden" name="${escapeHTML(name)}" value="${escapeHTML(value)}">`).join("")}<label>Connection ID <input name="connection" required pattern="[a-f0-9]{32}" autocomplete="off"></label><button type="submit">Continue</button></form>`);
    if (!TENANT.test(id)) return error("invalid_connection");
    const response = await relay(env, id, "GET", "/oauth/authorize", new URLSearchParams(fields).toString(), {}, new Uint8Array());
    if (response.headers.get("content-type")?.includes("text/html")) {
      const body = await response.text();
      return new Response(body.replace('action="/oauth/authorize"', `action="/t/${id}/oauth/authorize"`), { status: response.status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "strict-origin", "content-security-policy": authorizationCSP(url.searchParams.get("redirect_uri")) } });
    }
    return response;
  }
  const approval = /^\/t\/([a-f0-9]{32})\/oauth\/authorize$/.exec(path);
  if (approval && request.method === "POST") {
    if (request.headers.get("origin") !== ORIGIN) return error("invalid_origin", 403);
    const form = new URLSearchParams(text(await readBounded(request, 16384)));
    const copiedToken = routed(form.get("apple_core_token"));
    if (copiedToken) {
      if (copiedToken.id !== approval[1]) return error("invalid_connection", 403);
      form.set("apple_core_token", copiedToken.token);
    }
    const response = await relay(env, approval[1], "POST", "/oauth/authorize", "", { "content-type": "application/x-www-form-urlencoded" }, new TextEncoder().encode(form.toString()));
    const location = response.headers.get("location");
    if (response.status === 303 && location) {
      const redirect = new URL(location);
      const code = redirect.searchParams.get("code");
      if (!code) return error("invalid_response", 502);
      redirect.searchParams.set("code", wrap(approval[1], code));
      return new Response(null, { status: 303, headers: { location: redirect.toString(), "cache-control": "no-store", "referrer-policy": "no-referrer" } });
    }
    // Keep retries on the same tenant, including incorrect-token responses.
    if (response.headers.get("content-type")?.includes("text/html")) return new Response((await response.text()).replace('action="/oauth/authorize"', `action="/t/${approval[1]}/oauth/authorize"`), { status: response.status, headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "strict-origin", "content-security-policy": authorizationCSP(form.get("redirect_uri")) } });
    return response;
  }
  if (["/oauth/token", "/oauth/revoke"].includes(path) && request.method === "POST") {
    const form = new URLSearchParams(text(await readBounded(request, 16384)));
    const field = path === "/oauth/revoke" ? "token" : form.get("grant_type") === "authorization_code" ? "code" : "refresh_token";
    const route = routed(form.get(field));
    if (!route) return error("invalid_grant");
    form.set(field, route.token);
    const response = await relay(env, route.id, "POST", path, "", { "content-type": "application/x-www-form-urlencoded" }, new TextEncoder().encode(form.toString()));
    if (path === "/oauth/token" && response.status === 200) {
      const pair = await response.json();
      if (!pair.access_token || !pair.refresh_token) return error("invalid_response", 502);
      return json({ ...pair, access_token: wrap(route.id, pair.access_token), refresh_token: wrap(route.id, pair.refresh_token) });
    }
    return response;
  }
  if (path === "/mcp") {
    const route = routed(request.headers.get("authorization")?.replace(/^Bearer /, ""));
    if (!route) return new Response(null, { status: 401, headers: { "www-authenticate": `Bearer resource_metadata="${ORIGIN}/.well-known/oauth-protected-resource/mcp"`, "cache-control": "no-store", "access-control-allow-origin": "*" } });
    if (!["POST", "DELETE"].includes(request.method)) return new Response(null, { status: 405, headers: { allow: "POST, DELETE", "cache-control": "no-store" } });
    const headers = pickHeaders(request.headers, REQUEST_HEADERS);
    headers.authorization = `Bearer ${route.token}`;
    return relay(env, route.id, request.method, "/mcp", "", headers, await readBounded(request));
  }
  return error("not_found", 404);
}

export default {
  async fetch(request, env) {
    try { return await handle(request, env); }
    catch { return error("invalid_request"); }
  },
};
