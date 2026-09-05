# First-run, purchase, and distribution verification

Author: Oliver Ames

## Task list

- [x] Audit first-run tunnel, authentication, license enforcement, and live distribution.
- [x] Fix confirmed gaps and add focused regression coverage.
- [ ] Verify clean installation, checkout, and buyer delivery without a real charge.
- [ ] In progress: build, sign, notarize, and publish the DMG through Gumroad and source release through GitHub.
- [ ] Verify published downloads, update feed, license enforcement, and CI.

## Scope

The official application must be delivered by Gumroad after payment and require a valid license. GitHub publishes source and release notes. The user authorized fixes and a release on September 4, 2026, and resumed work on September 5.

## Initial observations

- September 4: Gumroad buyer content contains the EULA, the 1.7.2 ZIP, and a license-key block. It must deliver a DMG.
- September 4: current GitHub release automation creates source-only releases, but historical releases still contain downloadable binaries.
- Source review: Sparkle currently uses public R2 ZIP URLs. The distribution review will determine how to protect official update downloads.
- Source review: Gumroad activation persists an unsigned JSON entitlement. Its authenticity needs verification before it can authorize serving.

## Verification evidence

Observed September 5, 2026. No real purchase has been made.

- The final Debug app build and all 208 Swift tests passed. The seven distribution-worker tests passed, Swift formatting and shell checks passed, and the full-history Gitleaks scan found no secrets in 317 commits.
- The production cloudflared installer downloaded version 2026.8.3 into an isolated temporary folder. GitHub SHA-256 verification, Cloudflare Developer ID verification, extraction, installation, and execution all passed.
- The running app, with temporary configuration and a separate port, displayed the welcome and activation screens. Continue remained disabled without a license.
- Full local HTTP verification passed: discovery, client registration, wrong master-token denial, PKCE rejection and successful exchange, unlicensed MCP rejection, short-lived signed test activation, one-time native client approval, MCP initialization and ping, refresh rotation and replay denial, and revocation of both access-token generations. The temporary activation was removed. No Apple service data was queried.
- Apple's profile API initially returned HTTP 500. A later retry created `Apple Core Developer ID`, authorizing this app's Keychain group. A Developer ID signed probe using the production receipt code wrote a temporary protected Keychain entry, read it in another process, and removed it successfully.
- The public Gumroad product and checkout are reachable. The seller session in the available in-app browser is signed out. Receipt and no-charge seller test checkout remain pending user sign-in.

## Fixes

- First-run activation, a stated Cloudflare domain prerequisite, public OAuth readiness checks, and surfaced tunnel/DNS errors.
- Bounded asynchronous Cloudflare login, including failed exit, cancellation, timeout, and child cleanup.
- Paid purchase checks, protected offline receipt storage, old-cache online migration, future-date rejection, immediate revocation when the installed key is re-entered, and removal of buyer email from public status.
- A signed/notarized DMG packaging command, source-only release safeguards, licensed update downloads, and a manual Gumroad update path for older clients.

## Remaining verification

- Complete Gumroad's no-charge seller checkout and inspect its receipt/download after sign-in. Real payment processing has not been exercised.
- Verify the signed release, DMG, Gumroad upload, protected distribution routes, GitHub release inventory, appcast, and CI.
- A fresh external Cloudflare account's interactive browser authorization and live DNS provisioning have not been exercised. Installer, readiness, ownership, DNS policy, and OAuth behavior were checked separately without altering the production tunnel.

