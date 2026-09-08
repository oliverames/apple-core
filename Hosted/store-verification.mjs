// SPDX-License-Identifier: GPL-3.0-or-later
import { Buffer } from "node:buffer";
import { APPLE_ROOTS_BASE64 } from "./apple-roots.mjs";

export const STORE_BUNDLE_ID = "com.oliverames.applecore.appstore";
export const STORE_APP_ID = 6809879931;
export const HOSTING_PRODUCT_ID = "com.oliverames.applecore.appstore.hosting.monthly";
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
const ID = /^[0-9]{1,64}$/;

export class StoreVerificationError extends Error {
  constructor(code = "invalid_purchase") { super(code); this.code = code; }
}

function environmentChecked(environment) {
  // Apple's library deliberately skips signatures for Xcode/local testing.
  // Those environments must never be selectable on the hosting server.
  if (!["Production", "Sandbox"].includes(environment)) throw new StoreVerificationError("invalid_environment");
  return environment;
}

async function verifier(environment) {
  // A transitive Apple dependency seeds its RNG during module initialization.
  // Load it within a request, where Workers permits secure randomness.
  const { SignedDataVerifier } = await import("@apple/app-store-server-library");
  return new SignedDataVerifier(
    APPLE_ROOTS_BASE64.map(value => Buffer.from(value, "base64")),
    true, // Check current certificate validity and online revocation status.
    environmentChecked(environment), STORE_BUNDLE_ID, STORE_APP_ID,
  );
}

function checkJWS(jws) {
  if (typeof jws !== "string" || jws.length > 32768 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(jws)) {
    throw new StoreVerificationError();
  }
}

async function verified(operation) {
  try { return await operation(); }
  catch (error) {
    if (error instanceof StoreVerificationError) throw error;
    const { VerificationException, VerificationStatus } = await import("@apple/app-store-server-library");
    if (error instanceof VerificationException && error.status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
      throw new StoreVerificationError("verification_unavailable");
    }
    // Do not expose Apple payloads, certificates, or underlying network errors.
    throw new StoreVerificationError();
  }
}

/** Pure policy applied ONLY after Apple's cryptographic verification succeeds.
 * This function alone is not proof of purchase. Notifications retain inactive
 * records so refunds and expiry can revoke access instead of being discarded.
 */
export function recordFromVerifiedTransaction(transaction, environment, now = Date.now()) {
  environmentChecked(environment);
  if (!transaction || transaction.bundleId !== STORE_BUNDLE_ID || transaction.environment !== environment ||
      transaction.productId !== HOSTING_PRODUCT_ID || transaction.type !== "Auto-Renewable Subscription" ||
      typeof transaction.originalTransactionId !== "string" || !ID.test(transaction.originalTransactionId) ||
      typeof transaction.transactionId !== "string" || !ID.test(transaction.transactionId) ||
      typeof transaction.appAccountToken !== "string" || !UUID.test(transaction.appAccountToken) ||
      !Number.isSafeInteger(transaction.expiresDate) || transaction.expiresDate <= 0 ||
      !Number.isSafeInteger(transaction.signedDate) || transaction.signedDate <= 0 || transaction.signedDate > now + 60000 ||
      (transaction.revocationDate != null && (!Number.isSafeInteger(transaction.revocationDate) || transaction.revocationDate < 0)) ||
      (transaction.isUpgraded != null && typeof transaction.isUpgraded !== "boolean")) throw new StoreVerificationError();
  return {
    originalTransactionID: transaction.originalTransactionId,
    transactionID: transaction.transactionId,
    accountToken: transaction.appAccountToken.toLowerCase(),
    environment,
    expiresAt: transaction.expiresDate,
    signedAt: transaction.signedDate,
    revokedAt: transaction.revocationDate ?? null,
    upgraded: transaction.isUpgraded === true,
    active: transaction.expiresDate > now && transaction.revocationDate == null && transaction.isUpgraded !== true,
  };
}

/** The caller selects a server-configured environment, never a client-supplied
 * verifier mode. Enrollment must also reconcile current status with Apple and
 * bind the original transaction to the authenticated hosting account.
 */
export async function verifyStorePurchase(jws, { environment, accountToken }) {
  return verified(async () => {
    environmentChecked(environment);
    if (typeof accountToken !== "string" || !UUID.test(accountToken)) throw new StoreVerificationError();
    checkJWS(jws);
    const transaction = await (await verifier(environment)).verifyAndDecodeTransaction(jws);
    const record = recordFromVerifiedTransaction(transaction, environment);
    if (record.accountToken !== accountToken.toLowerCase()) throw new StoreVerificationError("account_mismatch");
    if (!record.active) throw new StoreVerificationError("subscription_inactive");
    return record;
  });
}

export async function verifyStoreNotification(jws, environment) {
  return verified(async () => {
    environmentChecked(environment);
    checkJWS(jws);
    const check = await verifier(environment);
    const notification = await check.verifyAndDecodeNotification(jws);
    if (!UUID.test(notification.notificationUUID ?? "") || !Number.isSafeInteger(notification.signedDate) ||
        notification.signedDate <= 0 || notification.signedDate > Date.now() + 60000) throw new StoreVerificationError();
    let transaction = null;
    if (notification.data?.signedTransactionInfo) {
      checkJWS(notification.data.signedTransactionInfo);
      transaction = recordFromVerifiedTransaction(
        await check.verifyAndDecodeTransaction(notification.data.signedTransactionInfo), environment,
      );
    }
    return {
      id: notification.notificationUUID, type: notification.notificationType,
      subtype: notification.subtype ?? null, signedAt: notification.signedDate,
      transaction,
    };
  });
}
