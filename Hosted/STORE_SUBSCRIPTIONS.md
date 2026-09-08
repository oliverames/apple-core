# Store hosting subscription implementation

Status: September 8, 2026. Verification foundation implemented and tested with
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
Enrollment rejects expired, revoked, or upgraded transactions. Notification
verification preserves inactive records so subsequent access reconciliation can
process refunds and expiration. Verification failures return sanitized error
codes. Retryable certificate-check failures remain distinguishable from invalid
purchases. Never log signed transactions or notifications.

This module verifies a signed snapshot. It does not by itself establish current
subscription status or grant hosting. Before enrollment, reconcile with Apple's
Server API and atomically bind the original transaction to the hosting account.
Do not call the pure `recordFromVerifiedTransaction` policy with unverified data.

## Current evidence and remaining tests

Node policy tests cover product/environment confusion, malformed identifiers,
account-token requirements, expired/refunded/upgraded records, timestamp bounds,
unsigned and oversized input, and forged signatures. A real Miniflare Worker
loads the Apple verifier and rejects forged certificate chains in Production and
Sandbox, and rejects Xcode mode. These are isolated backend tests, not app runtime
tests on the MacBook Pro.

A genuine sandbox purchase and Apple-signed notification have not yet passed
through this implementation. Before release, prove successful verification,
restore, current-status reconciliation, renewal, cancellation through the paid
period, refund, expiry, billing retry/grace period, reordered/duplicate
notifications, and account/installation ownership. Configure the In-App Purchase
server key through 1Password and Worker secrets. Implement the StoreKit client,
transaction updates, restore and management UI, server enrollment, revocation,
and reconciliation before allowing purchases or submitting the app for review.

The fixture Worker in `tests/` exists only for local tests. It must never be used
as a production route or deployed as the billing service.

## Primary references

- https://github.com/apple/app-store-server-library-node
- https://www.apple.com/certificateauthority/
- https://developer.apple.com/documentation/appstoreserverapi
- https://developer.apple.com/documentation/appstoreservernotifications
- https://developers.cloudflare.com/workers/runtime-apis/nodejs/crypto/
- https://developers.cloudflare.com/workers/best-practices/workers-best-practices/
