// SPDX-License-Identifier: GPL-3.0-or-later
import { DurableObject } from "cloudflare:workers";

const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;

export function ownershipKey(environment, originalTransactionID) {
  if (!["Production", "Sandbox"].includes(environment) ||
      typeof originalTransactionID !== "string" || !/^[0-9]{1,64}$/.test(originalTransactionID)) {
    throw new Error("invalid_subscription_identity");
  }
  return `${environment}:${originalTransactionID}`;
}

/** Internal RPC only. Route by ownershipKey, AFTER verifying Apple signatures
 * and matching the transaction account token to an authenticated account.
 * Claiming ownership never grants an entitlement or provisions a Mac.
 */
export class StoreOwnership extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS ownership (
      singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
      subscription TEXT NOT NULL, account TEXT NOT NULL
    )`);
  }

  claim(environment, originalTransactionID, accountToken) {
    const subscription = ownershipKey(environment, originalTransactionID);
    if (typeof accountToken !== "string" || !UUID.test(accountToken)) throw new Error("invalid_account");
    const account = accountToken.toLowerCase();
    // No await between related statements. The synchronous transaction keeps
    // retries and concurrent claims from transferring an existing subscription.
    return this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(
        "INSERT OR IGNORE INTO ownership (singleton, subscription, account) VALUES (1, ?, ?)",
        subscription, account,
      );
      const stored = this.ctx.storage.sql.exec("SELECT subscription, account FROM ownership WHERE singleton = 1").one();
      if (stored.subscription !== subscription) throw new Error("subscription_identity_mismatch");
      if (stored.account !== account) throw new Error("subscription_already_owned");
      return { owned: true };
    });
  }
}
