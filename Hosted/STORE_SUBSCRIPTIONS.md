# Store hosting subscription implementation

Status: September 8, 2026. Verification and ownership foundations implemented and tested with
isolated fixtures. No purchase endpoint, billing enforcement, or subscription
provisioning has been deployed. The existing invitation-only relay is unchanged.

## Product

- Bundle: `com.oliverames.applecore.appstore`
- App Store Connect app: `6809879931`
- Product: `com.oliverames.applecore.appstore.hosting.monthly`
- Subscription: `6809903305`, group `22369395`, ONE_MONTH
- US price: USD 2.99 monthly, verified in App Store Connect
- Download: USD 15.00, matching Gumroad

The number of Macs covered by a subscription is awaiting Oliver's decision.
Do not infer that policy from the existing one-Mac-per-relay architecture.

## Verification boundary

`store-verification.mjs` uses Apple's official server library 3.1.0, pinned
exactly, with published Apple root certificates bundled in `apple-roots.mjs`.
Certificate fingerprints and self-signatures are checked in tests. Root
certificates never come from clients. Online certificate revocation checks are
enabled. The library's transitive dependency initializes randomness, so its
import occurs inside a request handler rather than Workers global scope.

Only Production and Sandbox verification modes are accepted. Xcode and local
testing modes are rejected because the library intentionally skips signatures
in those modes. The endpoint must select an explicitly configured environment,
not trust a caller's verifier-mode parameter. Keep sandbox entitlements distinct
from production when provisioning and reconciling hosting access.

Verified transactions must match the bundle, hosting product, subscription type,
original/current transaction identifiers, account token, and valid timestamps.
Snapshot purchase checks reject expired, revoked, or upgraded transactions. Notification
verification preserves inactive records so subsequent access reconciliation can
process refunds and expiration. Verification failures return sanitized error
codes. Retryable certificate-check failures remain distinguishable from invalid
purchases. Never log signed transactions or notifications.

`verifyStorePurchase` checks a signed snapshot, not current subscription status.
`reconcileStorePurchase` additionally queries Apple's Get All Subscription
Statuses API and verifies its signed transaction and renewal data. It requires
matching account, original transaction, product, and environment. An old receipt
may identify a renewed subscription, but cannot grant access on its own. Active
paid periods and Apple's signed billing grace deadline can grant access.
Expired, revoked, and billing-retry-only states cannot. Turning auto-renew off
does not end a paid period. API failures return `verification_unavailable` and
must not be persisted as a cancellation. Ambiguous or missing results fail closed.

This module does not provision hosting. Before enrollment, atomically bind the
original transaction to the authenticated hosting account. Never call the pure
`recordFromVerifiedTransaction` or `entitlementFromVerifiedStatus` policies with
unverified data. The reconciliation function is implemented but has not yet been
validated with a real Apple purchase or exposed through a deployed endpoint.

`store-ownership.mjs` provides the internal SQLite-backed `StoreOwnership`
Durable Object for that binding. Route each object using `ownershipKey`, which
includes the server-selected Apple environment and original transaction ID.
Only invoke `claim` after cryptographic verification and an authenticated-account
match. The method validates identity shape, not Apple signatures or login.
It stores only the subscription identity and normalized account UUID, in a
synchronous transaction. Concurrent claims cannot transfer ownership; retries
by the same account succeed. Ownership alone never grants hosted access.

The class is currently exported and bound only in the isolated test Worker.
Production wiring, account authentication, reconciliation, and provisioning are
still pending. Tests cover concurrent competing claims, duplicate retries,
account UUID normalization, environment separation, and invalid input without
poisoning a later valid claim. No Mac-count policy is encoded in this ledger.

## Current evidence and remaining tests

Node policy tests cover product/environment confusion, malformed identifiers,
account-token requirements, expired/refunded/upgraded records, timestamp bounds,
unsigned and oversized input, and forged signatures. A real Miniflare Worker
loads the Apple verifier and rejects forged certificate chains in Production and
Sandbox, and rejects Xcode mode. These are isolated backend tests, not app runtime
tests on the MacBook Pro. Additional policy tests cover current inactive states,
cancellation through the paid period, signed grace deadlines, refunds during
grace, and mismatched account and renewal data.

A genuine sandbox purchase and Apple-signed notification have not yet passed
through this implementation. Before release, prove successful verification,
restore, current-status reconciliation, renewal, cancellation through the paid
period, refund, expiry, billing retry/grace period, reordered/duplicate
notifications, and account/installation ownership. Configure the In-App Purchase
server key through 1Password and Worker secrets. Implement the StoreKit client,
transaction updates, restore and management UI, server enrollment, revocation,
and reconciliation before allowing purchases or submitting the app for review.

## Server credential setup, September 8, 2026

The In-App Purchase key HR3WG2L3B6 is stored as the document
"Apple Core Hosting In-App Purchase Key" in 1Password's Development vault.
The stored document was verified byte-for-byte against the downloaded key.
The hosted Worker now has `APPLE_IAP_PRIVATE_KEY`, `APPLE_IAP_KEY_ID`, and
`APPLE_IAP_ISSUER_ID` secrets. Existing secrets were preserved. No private key
is checked into either repository.

A read-only notification-history request authenticated successfully against
Apple's Sandbox API and returned zero notifications. The equivalent Production
request returned HTTP 401. Its cause remains unresolved. This does not prove
purchase delivery or production readiness. After the secret installation,
anonymous MCP access returned 401 and public OAuth metadata returned 200.

The fixture Worker in `tests/` exists only for local tests. It must never be used
as a production route or deployed as the billing service.

## Primary references

- https://github.com/apple/app-store-server-library-node
- https://www.apple.com/certificateauthority/
- https://developer.apple.com/documentation/appstoreserverapi
- https://developer.apple.com/documentation/appstoreservernotifications
- https://developers.cloudflare.com/workers/runtime-apis/nodejs/crypto/
- https://developers.cloudflare.com/workers/best-practices/workers-best-practices/
