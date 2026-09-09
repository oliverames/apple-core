import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

test("expired invitations cannot enroll and alarm cleanup preserves other tenants", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: "relay-expiry-tests", modules: true,
    scriptPath: fileURLToPath(new URL("build-relay-expiry/relay-expiry.worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08",
    durableObjects: { FIXTURES: { className: "RelayExpiryFixture", useSQLite: true } },
  }] }));
  t.after(() => runtime.dispose());
  const call = async (operation, tenant, code) => {
    const response = await runtime.dispatchFetch("https://fixture.invalid/", {
      method: "POST", body: JSON.stringify({ operation, tenant, code }),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  const expired = await call("invite", "expired");
  const valid = await call("invite", "valid");
  await call("expire", "expired");
  assert.equal(await call("pair", "expired", expired), null);
  assert.deepEqual(await call("state", "expired"), { invitation: true, credential: false });
  await call("alarm", "expired");
  assert.deepEqual(await call("state", "expired"), { invitation: false, credential: false });
  assert.equal(await call("pair", "expired", expired), null);
  await call("alarm", "valid");
  assert.deepEqual(await call("state", "valid"), { invitation: true, credential: false });
  assert.equal(typeof await call("pair", "valid", valid), "string");
  assert.deepEqual(await call("state", "valid"), { invitation: false, credential: true });
});

test("relay quotas are atomic, isolated, roll over UTC windows and survive pause", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: "relay-usage-tests", modules: true,
    scriptPath: fileURLToPath(new URL("build-relay-expiry/relay-expiry.worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08",
    bindings: { HOSTED_DAILY_LIMIT: "3", HOSTED_MONTHLY_LIMIT: "4" },
    durableObjects: { FIXTURES: { className: "RelayExpiryFixture", useSQLite: true } },
  }] }));
  t.after(() => runtime.dispose());
  const call = async (operation, tenant = "first", extra = {}) => {
    const response = await runtime.dispatchFetch("https://fixture.invalid/", {
      method: "POST", body: JSON.stringify({ operation, tenant, ...extra }),
    });
    assert.equal(response.status, 200);
    return response.json();
  };
  const results = await Promise.all(Array.from({ length: 12 }, () => call("admit")));
  assert.equal(results.filter(status => status === 200).length, 3);
  assert.equal(results.filter(status => status === 429).length, 9);
  const first = await call("usage");
  assert.equal(first.dayCount, 3);
  assert.equal(first.monthCount, 3);
  assert.equal(await call("admit", "second"), 200);
  await call("pause", "first", { paused: true });
  assert.equal(await call("admit"), 503);
  await call("pause", "first", { paused: false });
  assert.equal(await call("admit"), 429);
  assert.equal((await call("usage")).monthCount, 3);
  await call("setUsage", "first", { usage: { ...first, day: "2000-01-01" } });
  assert.equal(await call("admit"), 200);
  assert.equal(await call("admit"), 429);
  assert.equal((await call("usage")).dayCount, 1);
  await call("setUsage", "first", { usage: { ...first, day: "2000-01-01", month: "2000-01" } });
  assert.equal(await call("admit"), 200);
  const rolled = await call("usage");
  assert.equal(rolled.monthCount, 1);
  assert.equal(rolled.dayCount, 1);
  assert.deepEqual(Object.keys(rolled).sort(), ["day", "dayCount", "limits", "month", "monthCount", "paused"]);
});

test("missing quota configuration fails closed", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: "relay-missing-policy-tests", modules: true,
    scriptPath: fileURLToPath(new URL("build-relay-expiry/relay-expiry.worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08",
    durableObjects: { FIXTURES: { className: "RelayExpiryFixture", useSQLite: true } },
  }] }));
  t.after(() => runtime.dispose());
  const response = await runtime.dispatchFetch("https://fixture.invalid/", {
    method: "POST", body: JSON.stringify({ operation: "admit", tenant: "missing" }),
  });
  assert.equal(await response.json(), 503);
});
