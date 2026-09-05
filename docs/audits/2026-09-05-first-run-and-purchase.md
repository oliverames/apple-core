# First-run, purchase, and distribution verification

Author: Oliver Ames

## Task list

- [ ] In progress: audit first-run tunnel, authentication, license enforcement, and live distribution.
- [ ] Fix confirmed gaps and add focused regression coverage.
- [ ] Verify clean installation, checkout, and buyer delivery without a real charge.
- [ ] Build, sign, notarize, and publish the DMG through Gumroad and source release through GitHub.
- [ ] Verify published downloads, update feed, license enforcement, and CI.

## Scope

The official application must be delivered by Gumroad after payment and require a valid license. GitHub publishes source and release notes. The user authorized fixes and a release on September 4, 2026, and resumed work on September 5.

## Initial observations

- September 4: Gumroad buyer content contains the EULA, the 1.7.2 ZIP, and a license-key block. It must deliver a DMG.
- September 4: current GitHub release automation creates source-only releases, but historical releases still contain downloadable binaries.
- Source review: Sparkle currently uses public R2 ZIP URLs. The distribution review will determine how to protect official update downloads.
- Source review: Gumroad activation persists an unsigned JSON entitlement. Its authenticity needs verification before it can authorize serving.

## Verification evidence

Pending. No real purchase has been made.
