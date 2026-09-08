import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, X509Certificate } from "node:crypto";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";
import { APPLE_ROOTS_BASE64 } from "./apple-roots.mjs";
import { STORE_BUNDLE_ID, HOSTING_PRODUCT_ID, recordFromVerifiedTransaction, verifyStorePurchase, verifyStoreNotification } from "./store-verification.mjs";

const now = 1788890000000;
const accountToken = "08000000-1234-4567-89ab-000000000001";
const transaction = {
  bundleId: STORE_BUNDLE_ID, environment: "Production", productId: HOSTING_PRODUCT_ID,
  type: "Auto-Renewable Subscription", originalTransactionId: "123456789", transactionId: "123456790",
  appAccountToken: accountToken, expiresDate: now + 60000, signedDate: now - 1000,
};
const encoded = value => Buffer.from(JSON.stringify(value)).toString("base64url");
const forged = `${encoded({ alg: "ES256", x5c: Array(3).fill(APPLE_ROOTS_BASE64[2]) })}.${encoded(transaction)}.ZmFrZQ`;

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

test("Apple verifier executes in Workers and rejects forged trust chains", async t => {
  const runtime = new Miniflare(convertV4MiniflareOptions({ workers: [{
    name: "apple-core-verification-tests", modules: true,
    scriptPath: fileURLToPath(new URL("tests/build-verification/store-verification.worker.js", import.meta.url)),
    compatibilityDate: "2026-09-08", compatibilityFlags: ["nodejs_compat"],
  }] }));
  t.after(() => runtime.dispose());
  for (const environment of ["Production", "Sandbox", "Xcode"]) {
    const response = await runtime.dispatchFetch("https://verification.test/", {
      method: "POST", body: JSON.stringify({ jws: forged, environment, accountToken }),
    });
    assert.equal(response.status, 400);
    assert.deepEqual(await response.json(), { error: environment === "Xcode" ? "invalid_environment" : "invalid_purchase" });
  }
});
