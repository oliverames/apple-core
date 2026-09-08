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
  const record = await verifyOwnedTransaction(jws, { environment, accountToken });
  if (!record.active) throw new StoreVerificationError("subscription_inactive");
  return record;
}

async function verifyOwnedTransaction(jws, { environment, accountToken }) {
  return verified(async () => {
    environmentChecked(environment);
    if (typeof accountToken !== "string" || !UUID.test(accountToken)) throw new StoreVerificationError();
    checkJWS(jws);
    const transaction = await (await verifier(environment)).verifyAndDecodeTransaction(jws);
    const record = recordFromVerifiedTransaction(transaction, environment);
    if (record.accountToken !== accountToken.toLowerCase()) throw new StoreVerificationError("account_mismatch");
    return record;
  });
}

/** Pure policy for a current Apple API result whose transaction and renewal
 * signatures have ALREADY been verified. Never pass client-decoded payloads.
 */
export function entitlementFromVerifiedStatus(transaction, renewal, status, expected, now = Date.now()) {
  const record = recordFromVerifiedTransaction(transaction, expected.environment, now);
  if (record.originalTransactionID !== expected.originalTransactionID ||
      record.accountToken !== expected.accountToken) throw new StoreVerificationError("account_mismatch");
  if (![1, 2, 3, 4, 5].includes(status) || !renewal ||
      renewal.environment !== expected.environment || renewal.productId !== HOSTING_PRODUCT_ID ||
      renewal.originalTransactionId !== record.originalTransactionID ||
      !Number.isSafeInteger(renewal.signedDate) || renewal.signedDate <= 0 || renewal.signedDate > now + 60000 ||
      (renewal.appAccountToken != null && (typeof renewal.appAccountToken !== "string" ||
        renewal.appAccountToken.toLowerCase() !== record.accountToken))) throw new StoreVerificationError();
  let accessUntil = record.expiresAt;
  if (status === 4) {
    if (!Number.isSafeInteger(renewal.gracePeriodExpiresDate) || renewal.gracePeriodExpiresDate <= 0) {
      throw new StoreVerificationError();
    }
    accessUntil = renewal.gracePeriodExpiresDate;
  }
  return {
    ...record, status, checkedAt: now, accessUntil,
    active: (status === 1 || status === 4) && accessUntil > now && record.revokedAt === null && !record.upgraded,
  };
}

/** Verify ownership before querying Apple. An older signed receipt can identify
 * a subscription that subsequently renewed or entered billing grace. Its old
 * expiry never grants access: only the fresh API result determines entitlement.
 * Callers must still bind the original transaction atomically to their account.
 */
export async function reconcileStorePurchase(jws, { environment, accountToken, credentials }) {
  const expected = await verifyOwnedTransaction(jws, { environment, accountToken });
  if (!credentials || typeof credentials.privateKey !== "string" ||
      !/^[A-Z0-9]{10}$/.test(credentials.keyID ?? "") || !UUID.test(credentials.issuerID ?? "")) {
    throw new StoreVerificationError("verification_unavailable");
  }
  const { AppStoreServerAPIClient } = await import("@apple/app-store-server-library");
  let response;
  try {
    const client = new AppStoreServerAPIClient(credentials.privateKey, credentials.keyID,
      credentials.issuerID, STORE_BUNDLE_ID, environmentChecked(environment));
    // Include inactive states so a refund or expiration cannot be hidden by a filter.
    response = await client.getAllSubscriptionStatuses(expected.originalTransactionID);
  } catch {
    // Authentication, throttling, and network failures are not cancellation.
    // Do not persist an inactive entitlement on a failed status refresh.
    throw new StoreVerificationError("verification_unavailable");
  }
  return verified(async () => {
    if (response.environment !== environment || response.bundleId !== STORE_BUNDLE_ID ||
        (response.appAppleId != null && response.appAppleId !== STORE_APP_ID) || !Array.isArray(response.data)) {
      throw new StoreVerificationError();
    }
    const matches = response.data.flatMap(group => Array.isArray(group.lastTransactions) ? group.lastTransactions : [])
      .filter(item => item.originalTransactionId === expected.originalTransactionID);
    // Do not arbitrarily pick one of conflicting records or silently grant access.
    if (matches.length !== 1) throw new StoreVerificationError();
    const item = matches[0];
    checkJWS(item.signedTransactionInfo);
    checkJWS(item.signedRenewalInfo);
    const check = await verifier(environment);
    const transaction = await check.verifyAndDecodeTransaction(item.signedTransactionInfo);
    const renewal = await check.verifyAndDecodeRenewalInfo(item.signedRenewalInfo);
    return entitlementFromVerifiedStatus(transaction, renewal, item.status, expected);
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
