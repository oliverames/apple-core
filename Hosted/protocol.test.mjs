import { test } from "node:test";
import assert from "node:assert/strict";
import { routed, wrap, relayPathAllowed, pickHeaders, readBounded, matchesSecret, digest, authorizationCSP } from "./protocol.mjs";

test("routing rejects malformed and empty credentials", () => {
  for (const token of [null, "", "a~secret", `${"a".repeat(32)}~`, `${"g".repeat(32)}~secret`]) assert.equal(routed(token), null);
  const id = "a".repeat(32);
  assert.deepEqual(routed(wrap(id, "secret")), { id, token: "secret" });
});

test("relay cannot become a general local HTTP proxy", () => {
  for (const path of ["/", "/license-status", "/oauth/register", "/mcp/../admin", "https://example.com/mcp", "/favicon.ico"])
    assert.equal(relayPathAllowed("POST", path), false);
  assert.equal(relayPathAllowed("POST", "/mcp"), true);
  assert.equal(relayPathAllowed("GET", "/mcp"), false);
  assert.equal(relayPathAllowed("DELETE", "/oauth/authorize"), false);
});

test("caller cannot inject forwarding or cookie headers", () => {
  const headers = new Headers({ authorization: "Bearer sample", cookie: "session=sample", "x-forwarded-for": "127.0.0.1" });
  assert.deepEqual(pickHeaders(headers, ["authorization"]), { authorization: "Bearer sample" });
});

test("bodies are bounded even without content length", async () => {
  await assert.rejects(readBounded(new Request("https://example.com", { method: "POST", body: "12345" }), 4));
  assert.equal((await readBounded(new Request("https://example.com", { method: "POST", body: "1234" }), 4)).length, 4);
});

test("device secrets are checked against hashes", async () => {
  const hash = await digest("one device");
  assert.equal(await matchesSecret("one device", hash), true);
  assert.equal(await matchesSecret("another device", hash), false);
  assert.equal(await matchesSecret("one device", null), false);
});

test("authorization CSP permits only the specified web callback origin", () => {
  assert.match(authorizationCSP("http://127.0.0.1:56719/callback"), /form-action 'self' http:\/\/127\.0\.0\.1:56719;/);
  assert.match(authorizationCSP("https://chatgpt.com/callback?x=1"), /form-action 'self' https:\/\/chatgpt\.com;/);
  for (const uri of ["javascript:alert(1)", "http://evil.example/callback", "invalid"]) assert.match(authorizationCSP(uri), /form-action 'self';/);
});
