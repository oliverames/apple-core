import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, X509Certificate } from "node:crypto";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { APPLE_ROOTS_BASE64 } from "./apple-roots.mjs";
import { STORE_BUNDLE_ID, HOSTING_PRODUCT_ID, recordFromVerifiedTransaction, verifyStorePurchase, verifyStoreNotification, entitlementFromVerifiedStatus, reconcileStorePurchase } from "./store-verification.mjs";

const now = 1788890000000;
const accountToken = "08000000-1234-4567-89ab-000000000001";
const transaction = {
  bundleId: STORE_BUNDLE_ID, environment: "Production", productId: HOSTING_PRODUCT_ID,
  type: "Auto-Renewable Subscription", originalTransactionId: "123456789", transactionId: "123456790",
  appAccountToken: accountToken, expiresDate: now + 60000, signedDate: now - 1000,
};
const encoded = value => Buffer.from(JSON.stringify(value)).toString("base64url");
const forged = `${encoded({ alg: "ES256", x5c: Array(3).fill(APPLE_ROOTS_BASE64[2]) })}.${encoded(transaction)}.ZmFrZQ`;
const expected = { environment: "Production", originalTransactionID: transaction.originalTransactionId, accountToken };
const renewal = { environment: "Production", productId: HOSTING_PRODUCT_ID,
  originalTransactionId: transaction.originalTransactionId, signedDate: now - 1000, autoRenewStatus: 0 };

test("current subscription state retains paid access after cancellation and removes inactive states", () => {
  assert.equal(entitlementFromVerifiedStatus(transaction, renewal, 1, expected, now).active, true);
  for (const status of [2, 3, 5]) {
    assert.equal(entitlementFromVerifiedStatus(transaction, renewal, status, expected, now).active, false);
  }
  assert.equal(entitlementFromVerifiedStatus({ ...transaction, expiresDate: now }, renewal, 1, expected, now).active, false);
});

test("billing grace uses Apple's signed deadline but cannot override refunds or upgrades", () => {
  const expired = { ...transaction, expiresDate: now - 1000 };
  const grace = { ...renewal, gracePeriodExpiresDate: now + 60000 };
  const result = entitlementFromVerifiedStatus(expired, grace, 4, expected, now);
  assert.equal(result.active, true);
  assert.equal(result.accessUntil, grace.gracePeriodExpiresDate);
  for (const change of [{ revocationDate: now }, { isUpgraded: true }]) {
    assert.equal(entitlementFromVerifiedStatus({ ...expired, ...change }, grace, 4, expected, now).active, false);
  }
  assert.equal(entitlementFromVerifiedStatus(expired, { ...grace, gracePeriodExpiresDate: now }, 4, expected, now).active, false);
  for (const gracePeriodExpiresDate of [undefined, "9999999999999", -1]) {
    assert.throws(() => entitlementFromVerifiedStatus(expired, { ...grace, gracePeriodExpiresDate }, 4, expected, now));
  }
});

test("status reconciliation rejects cross-account, cross-subscription, and mismatched renewal data", () => {
  for (const change of [{ accountToken: "08000000-1234-4567-89ab-000000000002" }, { originalTransactionID: "456" }]) {
    assert.throws(() => entitlementFromVerifiedStatus(transaction, renewal, 1, { ...expected, ...change }, now), { code: "account_mismatch" });
  }
  for (const change of [{ environment: "Sandbox" }, { productId: "other" }, { originalTransactionId: "456" },
    { signedDate: now + 60001 }, { signedDate: "invalid" }, { appAccountToken: "other" }]) {
    assert.throws(() => entitlementFromVerifiedStatus(transaction, { ...renewal, ...change }, 1, expected, now));
  }
  assert.throws(() => entitlementFromVerifiedStatus(transaction, renewal, 6, expected, now));
});

test("reconciliation rejects forged ownership before requesting Apple status", async () => {
  await assert.rejects(reconcileStorePurchase(forged, { environment: "Production", accountToken }), { code: "invalid_purchase" });
});

test("Apple trust anchors match the retrieved public certificates", () => {
  const expected = [
    "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
    "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
  ];
  APPLE_ROOTS_BASE64.forEach((root, index) => {
    const bytes = Buffer.from(root, "base64");
    assert.equal(createHash("sha256").update(bytes).digest("hex"), expected[index]);
    const certificate = new X509Certificate(bytes);
    assert.equal(certificate.ca, true);
    assert.equal(certificate.verify(certificate.publicKey), true);
  });
});

test("verified transaction policy preserves inactive refund, expiry, and upgrade records", () => {
  assert.equal(recordFromVerifiedTransaction(transaction, "Production", now).active, true);
  for (const change of [{ expiresDate: now }, { revocationDate: now }, { isUpgraded: true }]) {
    assert.equal(recordFromVerifiedTransaction({ ...transaction, ...change }, "Production", now).active, false);
  }
  // Turning auto-renew off does not remove a paid-for period.
  assert.equal(recordFromVerifiedTransaction({ ...transaction, autoRenewStatus: 0 }, "Production", now).active, true);
});

test("verified transaction policy rejects unrelated or malformed entitlements", () => {
  for (const change of [
    { bundleId: "com.attacker.app" }, { productId: "unrelated" }, { environment: "Sandbox" },
    { type: "Consumable" }, { appAccountToken: undefined }, { appAccountToken: "not-a-uuid" },
    { originalTransactionId: "../another" }, { originalTransactionId: 123 }, { transactionId: 123 }, { transactionId: "" }, { expiresDate: "9999999999999" },
    { signedDate: now + 60001 }, { revocationDate: "invalid" }, { isUpgraded: "false" },
  ]) assert.throws(() => recordFromVerifiedTransaction({ ...transaction, ...change }, "Production", now));
});

test("purchase verification rejects unsigned, forged, oversized, and local-test receipts", async () => {
  for (const jws of ["", "not-a-jws", "x".repeat(32769), forged]) {
    await assert.rejects(verifyStorePurchase(jws, { environment: "Production", accountToken }), { code: "invalid_purchase" });
  }
  for (const environment of ["Xcode", "LocalTesting", undefined, "sandbox"]) {
    await assert.rejects(verifyStorePurchase(forged, { environment, accountToken }), { code: "invalid_environment" });
  }
  await assert.rejects(verifyStoreNotification(forged, "Production"), { code: "invalid_purchase" });
});

test("Worker ownership is exclusive and Apple verification rejects forged trust chains", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: "apple-core-verification-tests", modules: true,
    scriptPath: fileURLToPath(new URL("tests/build-verification/store-verification.worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08", compatibilityFlags: ["nodejs_compat"],
    durableObjects: { OWNERSHIP: { className: "StoreOwnership", useSQLite: true } },
  }] }));
  t.after(() => runtime.dispose());
  const claim = (owner, environment = "Production", originalTransactionID = "1000001") =>
    runtime.dispatchFetch("https://verification.test/", {
      method: "POST", body: JSON.stringify({ claim: true, environment, originalTransactionID, accountToken: owner }),
    });
  const owners = [accountToken, "08000000-1234-4567-89ab-000000000002"];
  const raced = await Promise.all(owners.map(owner => claim(owner)));
  assert.deepEqual(raced.map(r => r.status).sort(), [200, 400]);
  const winner = owners[raced.findIndex(r => r.status === 200)];
  const loser = owners.find(owner => owner !== winner);
  assert.equal((await claim(winner.toUpperCase())).status, 200);
  assert.equal((await claim(loser)).status, 400);
  assert.equal((await claim(loser, "Sandbox")).status, 200);
  assert.equal((await claim(loser, "Production", "1000002")).status, 200);
  assert.equal((await claim(winner, "Xcode")).status, 400);
  assert.equal((await claim("invalid-account", "Production", "1000003")).status, 400);
  assert.equal((await claim(winner, "Production", "1000003")).status, 200);
  for (const [environment, reconcile] of [
    ["Production", false], ["Sandbox", false], ["Xcode", false],
    ["Production", true], ["Sandbox", true], ["Xcode", true],
  ]) {
    const response = await runtime.dispatchFetch("https://verification.test/", {
      method: "POST", body: JSON.stringify({ jws: forged, environment, accountToken, reconcile }),
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: environment === "Xcode" ? "invalid_environment" : "invalid_purchase" });
  }
});
