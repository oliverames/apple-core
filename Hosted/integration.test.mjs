import { test } from "node:test";
import assert from "node:assert/strict";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { ORIGIN, base64 } from "./protocol.mjs";
import { fileURLToPath } from "node:url";

test("hosted enrollment and isolated device relays", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({
    workers: [{
    name: "apple-core-hosted-test",
    modules: true,
    scriptPath: fileURLToPath(new URL("build/worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08",
    compatibilityFlags: ["nodejs_compat"],
    durableObjects: { MACS: { className: "MacRelay", useSQLite: true } },
    bindings: { HOSTED_DAILY_LIMIT: "2000", HOSTED_MONTHLY_LIMIT: "20000", ADMIN_SECRET: "test-admin-credential-only", METADATA_SECRET: "test-metadata-signing-credential-only" },
    ratelimits: { REQUEST_LIMITER: { namespace_id: "1001", simple: { limit: 1000, period: 60 } } },
    }],
  }));
  t.after(() => runtime.dispose());
  const call = (path, init = {}) => runtime.dispatchFetch(`${ORIGIN}${path}`, init);
  const invite = async () => {
    const response = await call("/admin/invitations", { method: "POST", headers: { authorization: "Bearer test-admin-credential-only" } });
    assert.equal(response.status, 201);
    return (await response.json()).setup_code;
  };
  const pair = code => call("/pair", { method: "POST", body: JSON.stringify({ setup_code: code }) });

  assert.equal((await call("/admin/invitations", { method: "POST" })).status, 401);
  const anonymous = await call("/mcp", { method: "POST", body: "{}" });
  assert.equal(anonymous.status, 401);
  assert.match(anonymous.headers.get("www-authenticate"), /oauth-protected-resource\/mcp/);
  const code = await invite();
  assert.equal((await pair("not-a-routed-setup-code")).status, 400);
  assert.equal((await pair(`${code.split("~")[0]}~wrong-secret`)).status, 400);
  const attempts = await Promise.all([pair(code), pair(code)]);
  assert.deepEqual(attempts.map(r => r.status).sort(), [200, 400]);
  const first = await attempts.find(r => r.status === 200).json();
  assert.equal((await pair(code)).status, 400);
  const second = await (await pair(await invite())).json();

  const connect = device => call(`/bridge/${device.tenant_id}`, { headers: { upgrade: "websocket", authorization: `Bearer ${device.relay_credential}` } });
  assert.equal((await connect({ ...second, relay_credential: first.relay_credential })).status, 401);
  const connection = await connect(first);
  assert.equal(connection.status, 101);
  const socket = connection.webSocket;
  socket.accept();
  t.after(() => socket.close());
  assert.equal((await connect(first)).status, 409);
  const seen = [];
  socket.addEventListener("message", event => {
    const request = JSON.parse(event.data);
    seen.push(request);
    const approval = request.path === "/oauth/authorize" && request.method === "POST";
    const body = request.path === "/oauth/token" ? '{"access_token":"inner-access","refresh_token":"inner-refresh","token_type":"Bearer"}' : '{"ok":true}';
    const headers = { "content-type": "application/json", "set-cookie": "must-not-forward" };
    if (approval) headers.location = "http://127.0.0.1:12345/callback?code=inner-code&state=unchanged-state";
    socket.send(JSON.stringify({ id: request.id, status: approval ? 303 : 200, headers }));
    socket.send(JSON.stringify({ id: request.id, chunk: base64(new TextEncoder().encode(body)), done: true }));
  });
  const response = await call("/mcp", { method: "POST", headers: { authorization: `Bearer ${first.tenant_id}~inner-token`, "x-forwarded-for": "127.0.0.1", cookie: "must-not-forward" }, body: "{}" });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(seen[0].headers.authorization, "Bearer inner-token");
  assert.equal(seen[0].headers.cookie, undefined);
  assert.equal(seen[0].headers["x-forwarded-for"], undefined);
  const other = await call("/mcp", { method: "POST", headers: { authorization: `Bearer ${second.tenant_id}~inner-token` }, body: "{}" });
  assert.equal(other.status, 503);
  assert.equal(seen.length, 1);

  const adminHeaders = { authorization: "Bearer test-admin-credential-only" };
  const usagePath = `/admin/tenants/${first.tenant_id}/usage`;
  assert.equal((await call(usagePath)).status, 401);
  assert.equal((await (await call(usagePath, { headers: adminHeaders })).json()).dayCount, 1);
  const pausePath = `/admin/tenants/${first.tenant_id}/pause`;
  assert.equal((await call(pausePath, { method: "POST", headers: adminHeaders, body: JSON.stringify({ paused: true }) })).status, 200);
  assert.equal((await call("/mcp", { method: "POST", headers: { authorization: `Bearer ${first.tenant_id}~inner-token` }, body: "{}" })).status, 503);
  assert.equal(seen.length, 1);
  assert.equal((await call("/oauth/revoke", { method: "POST", body: new URLSearchParams({ token: `${first.tenant_id}~inner-token` }).toString() })).status, 200);
  assert.equal(seen.at(-1).path, "/oauth/revoke");
  assert.equal((await (await call(usagePath, { headers: adminHeaders })).json()).dayCount, 1);
  assert.equal((await call(pausePath, { method: "POST", headers: adminHeaders, body: JSON.stringify({ paused: false }) })).status, 200);

  const registration = await call("/oauth/register", { method: "POST", body: JSON.stringify({ client_name: "Test client", redirect_uris: ["http://127.0.0.1:12345/callback"] }) });
  assert.equal(registration.status, 201);
  const client = await registration.json();
  const metadata = await runtime.dispatchFetch(client.client_id);
  assert.equal(metadata.status, 200);
  assert.equal((await metadata.json()).client_id, client.client_id);
  assert.equal((await runtime.dispatchFetch(`${client.client_id}tampered`)).status, 404);
  // Hosted OAuth clients such as Muse can omit the RFC 8707 resource.
  // The relay must bind that omission to its single advertised audience.
  const authorization = new URLSearchParams({ response_type: "code", client_id: client.client_id, redirect_uri: "http://127.0.0.1:12345/callback", code_challenge_method: "S256", code_challenge: "test-challenge", state: "preserved-state", scope: "mcp" });
  const routingForm = await call(`/oauth/authorize?${authorization}`);
  assert.equal(routingForm.status, 200);
  const routingHTML = await routingForm.text();
  assert.match(routingHTML, /Settings &gt; Access &gt; Remote Access and choose Copy Connection ID/);
  assert.match(routingHTML, /32-character prefix before the <code>~<\/code>/);
  assert.match(routingHTML, /Do not enter the full token here/);
  assert.ok(routingHTML.includes(`name="resource" value="${ORIGIN}/mcp"`));
  authorization.set("connection", first.tenant_id);
  for (const resource of [undefined, `${ORIGIN}/mcp`, "https://other.example/mcp", ""]) {
    if (resource === undefined) authorization.delete("resource");
    else authorization.set("resource", resource);
    assert.equal((await call(`/oauth/authorize?${authorization}`)).status, 200);
    const forwarded = new URLSearchParams(seen.at(-1).query);
    assert.equal(forwarded.get("resource"), resource ?? `${ORIGIN}/mcp`);
    for (const name of ["response_type", "client_id", "redirect_uri", "code_challenge_method", "code_challenge", "state", "scope"]) assert.equal(forwarded.get(name), authorization.get(name));
    assert.equal(forwarded.has("connection"), false);
  }
  const beforeInvalidConnection = seen.length;
  for (const connection of ["invalid", `${first.tenant_id}~ames_test-secret`]) {
    authorization.set("connection", connection);
    assert.equal((await call(`/oauth/authorize?${authorization}`)).status, 400);
  }
  assert.equal(seen.length, beforeInvalidConnection);
  for (const grant_type of ["authorization_code", "refresh_token"]) {
    for (const resource of [undefined, `${ORIGIN}/mcp`, "https://other.example/mcp", ""]) {
      const form = new URLSearchParams({ grant_type, client_id: client.client_id, code_verifier: "preserved-verifier", [grant_type === "authorization_code" ? "code" : "refresh_token"]: `${first.tenant_id}~test-grant` });
      if (resource !== undefined) form.set("resource", resource);
      assert.equal((await call("/oauth/token", { method: "POST", body: form.toString() })).status, 200);
      const forwarded = new URLSearchParams(Buffer.from(seen.at(-1).body, "base64").toString());
      assert.equal(forwarded.get("resource"), resource ?? `${ORIGIN}/mcp`);
      assert.equal(forwarded.get("code_verifier"), "preserved-verifier");
      assert.equal(forwarded.get("client_id"), client.client_id);
    }
  }
  // Revocation and approval keep their existing request semantics.
  assert.equal((await call("/oauth/revoke", { method: "POST", body: new URLSearchParams({ token: `${first.tenant_id}~test-grant` }).toString() })).status, 200);
  assert.equal(new URLSearchParams(Buffer.from(seen.at(-1).body, "base64").toString()).has("resource"), false);
  assert.equal((await call(`/t/${first.tenant_id}/oauth/authorize`, { method: "POST", headers: { origin: "https://attacker.example" }, body: "" })).status, 403);
  const approved = await call(`/t/${first.tenant_id}/oauth/authorize`, { method: "POST", redirect: "manual", headers: { origin: ORIGIN }, body: new URLSearchParams({ apple_core_token: `${first.tenant_id}~master-token` }).toString() });
  assert.equal(approved.status, 303);
  const redirect = new URL(approved.headers.get("location"));
  assert.equal(redirect.searchParams.get("code"), `${first.tenant_id}~inner-code`);
  assert.equal(redirect.searchParams.get("state"), "unchanged-state");
  assert.equal(new URLSearchParams(Buffer.from(seen.at(-1).body, "base64").toString()).get("apple_core_token"), "master-token");
  const exchanged = await call("/oauth/token", { method: "POST", body: new URLSearchParams({ grant_type: "authorization_code", code: redirect.searchParams.get("code"), code_verifier: "pkce-verifier", client_id: client.client_id, resource: `${ORIGIN}/mcp` }).toString() });
  assert.equal(exchanged.status, 200);
  const tokenPair = await exchanged.json();
  assert.equal(tokenPair.access_token, `${first.tenant_id}~inner-access`);
  assert.equal(tokenPair.refresh_token, `${first.tenant_id}~inner-refresh`);
  const passedForm = new URLSearchParams(Buffer.from(seen.at(-1).body, "base64").toString());
  assert.equal(passedForm.get("code"), "inner-code");
  assert.equal(passedForm.get("code_verifier"), "pkce-verifier");
  assert.equal(passedForm.get("resource"), `${ORIGIN}/mcp`);
  const refreshed = await call("/oauth/token", { method: "POST", body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: tokenPair.refresh_token, client_id: client.client_id, resource: `${ORIGIN}/mcp` }).toString() });
  assert.equal(refreshed.status, 200);
  assert.equal(new URLSearchParams(Buffer.from(seen.at(-1).body, "base64").toString()).get("refresh_token"), "inner-refresh");
  assert.equal((await call(`/admin/tenants/${first.tenant_id}`, { method: "DELETE", headers: { authorization: "Bearer test-admin-credential-only" } })).status, 204);
  assert.equal((await connect(first)).status, 401);
});

test("global pause blocks new work while discovery and administrator authentication remain available", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: "apple-core-paused-test", modules: true,
    scriptPath: fileURLToPath(new URL("build/worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08", compatibilityFlags: ["nodejs_compat"],
    durableObjects: { MACS: { className: "MacRelay", useSQLite: true } },
    bindings: { HOSTED_PAUSED: "true", ADMIN_SECRET: "test-admin-credential-only" },
    ratelimits: { REQUEST_LIMITER: { namespace_id: "1002", simple: { limit: 1000, period: 60 } } },
  }] }));
  t.after(() => runtime.dispose());
  for (const path of ["/mcp", "/pair", "/oauth/token", "/oauth/authorize", "/bridge/" + "a".repeat(32)]) {
    assert.equal((await runtime.dispatchFetch(`${ORIGIN}${path}`, { method: "POST" })).status, 503);
  }
  assert.equal((await runtime.dispatchFetch(`${ORIGIN}/oauth/revoke`, { method: "POST", body: "token=invalid" })).status, 400);
  assert.equal((await runtime.dispatchFetch(`${ORIGIN}/.well-known/oauth-authorization-server`)).status, 200);
  assert.equal((await runtime.dispatchFetch(`${ORIGIN}/admin/tenants/${"a".repeat(32)}/usage`)).status, 401);
  assert.equal((await runtime.dispatchFetch(`${ORIGIN}/admin/tenants/${"a".repeat(32)}/usage`, {
    headers: { authorization: "Bearer test-admin-credential-only" },
  })).status, 200);
});
