# First-run, purchase, and distribution verification

Author: Oliver Ames

## Task list

- [x] Audit first-run tunnel, authentication, license enforcement, and live distribution.
- [x] Fix confirmed gaps and add focused regression coverage.
- [x] Verify clean installation, checkout, and buyer delivery without a real charge.
- [x] Build, sign, notarize, and publish the DMG through Gumroad and source release through GitHub.
- [ ] In progress: finish publication verification and remove historical GitHub assets after explicit approval.
- [ ] Publish authorized community announcements where local rules permit.

## Scope

The official application must be delivered by Gumroad after payment and require a valid license. GitHub publishes source and release notes. The user authorized fixes and a release on September 4, 2026, and resumed work on September 5.

## Initial observations

- September 4: Gumroad buyer content contains the EULA, the 1.7.2 ZIP, and a license-key block. It must deliver a DMG.
- September 4: current GitHub release automation creates source-only releases, but historical releases still contain downloadable binaries.
- Source review: Sparkle currently uses public R2 ZIP URLs. The distribution review will determine how to protect official update downloads.
- Source review: Gumroad activation persists an unsigned JSON entitlement. Its authenticity needs verification before it can authorize serving.

## Verification evidence

Observed September 5, 2026. No real purchase has been made.

- The final Debug app build and all 208 Swift tests passed. The eight distribution-worker tests passed, Swift formatting and shell checks passed, and the full-history Gitleaks scan found no secrets in 317 commits.
- The production cloudflared installer downloaded version 2026.8.3 into an isolated temporary folder. GitHub SHA-256 verification, Cloudflare Developer ID verification, extraction, installation, and execution all passed.
- The running app, with temporary configuration and a separate port, displayed the welcome and activation screens. Continue remained disabled without a license.
- Full local HTTP verification passed against the app installed from the release DMG: discovery, client registration, wrong master-token denial, PKCE rejection and successful exchange, unlicensed MCP rejection, short-lived signed test activation, one-time native client approval, MCP initialization and ping, refresh rotation and replay denial, and revocation of both access-token generations. The temporary activation was removed. No Apple service data was queried.
- Apple's profile API initially returned HTTP 500. A later retry created `Apple Core Developer ID`, authorizing this app's Keychain group. A Developer ID signed probe using the production receipt code wrote a temporary protected Keychain entry, read it in another process, and removed it successfully.
- The authenticated seller checkout completed using Gumroad's test-purchase mode. Both checkout and receipt explicitly confirmed no charge. The buyer page displayed the EULA, Apple.Core-1.7.3.dmg, and a license key. The receipt displayed that key and a View content link. The DMG downloaded through the buyer page matched the locally signed release byte for byte.
- Gumroad's live verification API marked the resulting purchase `test: true`. Both protected download domains rejected that actual test key with HTTP 403. The installed release rejected activation and kept Continue disabled. No paid entitlement was fabricated.

## Published release

- [Version 1.7.3, build 27](https://github.com/oliverames/apple-core/releases/tag/v1.7.3), source commit `8700879115eb5456939230ae987730057af5db3b`, has zero attached assets. It contains source archives and release notes.
- The universal Intel/Apple Silicon app and DMG passed signature, Gatekeeper, and stapled-ticket validation. Apple accepted app notarization `07a74c10-0292-44d5-bcb7-21d223011dfd` and DMG notarization `52038975-7d4d-4ed6-90ae-ed54f75f348e`.
- [Gumroad](https://amesconsulting.gumroad.com/l/applecore) remains published at $15. Its buyer page serves the DMG after checkout, with activation and installation instructions. Old ZIP embeds were removed from the buyer page.
- DMG: 10,737,481 bytes, SHA-256 `08cd14d096f46f9e11b906f35a5f3de18433b145229335782442ee6a4b533ae3`.
- Protected update ZIP: 9,777,491 bytes, SHA-256 `db89014993661065cbb292227e20ae3c5fd928ed21cd901dcdb26c0a695146ee`.
- [Release CI](https://github.com/oliverames/apple-core/actions/runs/33973470579), [main CI](https://github.com/oliverames/apple-core/actions/runs/33973470587), and [Pages deployment](https://github.com/oliverames/apple-core/actions/runs/33973582928) passed. The live signed appcast matched the verified source bytes. Older clients receive an informational Gumroad reinstall link; build 27 and later authenticate automatic update downloads.
- Cloudflare Worker version `52202004-2749-4993-83b4-a588c7e3972c` protects the complete `assets.amesvt.com` and `assets.ames.consulting` host routes. The R2 managed public URL is disabled. Both domains passed anonymous, encoded-path, forged-key, range, HEAD, and cache-isolation checks. Authorized downloads matched the ZIP. An unrelated existing site asset remained available.
- A real Workers runtime exposed unsupported `redirect: 'error'` handling, which Node mocks had missed. The final server fix uses manual redirects and rejects all redirect responses without forwarding the license. A real Gumroad invalid-key lookup now returns HTTP 403 through both deployed routes. The regression suite covers redirect refusal.
- The last distribution audit found that CI cached the complete DerivedData directory after building the Debug app. Public fork workflows can restore those caches. Both generated build caches (`7342609214` and `7068297119`) were deleted, and CI now caches only Swift package dependencies under a new key namespace. Only the unrelated secret-scanner cache remained immediately after deletion.
- A read-only inventory covered both published branches, all 23 tags, 1,063 historical blobs, repository packages, historical workflows, and 173 Actions artifacts. No additional application-package route appeared. The two unexpired Pages archives were inspected and contained only the appcast and stylesheet.

## Fixes

- First-run activation, a stated Cloudflare domain prerequisite, public OAuth readiness checks, and surfaced tunnel/DNS errors.
- Bounded asynchronous Cloudflare login, including failed exit, cancellation, timeout, and child cleanup.
- Paid purchase checks, protected offline receipt storage, old-cache online migration, future-date rejection, immediate revocation when the installed key is re-entered, and removal of buyer email from public status.
- A signed/notarized DMG packaging command, source-only release safeguards, licensed update downloads, and a manual Gumroad update path for older clients.

## Remaining verification

- Real payment processing has not been exercised. The no-charge seller test verified checkout, receipt, buyer delivery, and rejection of unpaid test licenses.
- Historical GitHub releases still contain 28 ZIP/checksum assets. Automatic approval review rejected deletion without explicit approval of existing assets. The user was asked to authorize removing those exact assets while preserving source archives, tags, and release notes.
- A fresh external Cloudflare account's interactive browser authorization and live DNS provisioning have not been exercised. Installer, readiness, ownership, DNS policy, and OAuth behavior were checked separately without altering the production tunnel.
- The existing Mac cannot represent a fully fresh user: cloudflared is already installed, its login writes the current user's default certificate path, and app preferences are shared beyond the configuration-profile override. VirtualBuddy's current library is empty. UTM's inventory call timed out. A clean Mac/VM is needed for the remaining combined browser-login and DNS-provisioning acceptance test.
- Public GPL source permits independent builds. Protection applies to official downloads and the official app's licensing, not third-party builds or copies already downloaded.
