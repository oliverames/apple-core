# Releasing Apple Core

Apple Core uses two separate automation paths, mirrored from `bridgeport`:

- **CI** (`.github/workflows/ci.yml`) runs on `main`, pull requests, manual dispatch, and as a reusable release gate. It lints (`swift format`), builds, and runs unit tests via `xcodebuild` on the GitHub-hosted `macos-26` image, and scans full Git history with Gitleaks. Runtime Apple-account write tests require named disposable containers and run manually, not in CI.
- **Release** (`.github/workflows/release.yml`) runs for `v*` tags or manual dispatch. It calls the CI workflow first, then creates the GitHub release. Developer ID signing and notarization happen locally because those credentials are held in 1Password and the local keychain, never in CI.

The runtime write harness is `Scripts/integration_test.py`. Its default mode only performs authenticated enumeration. `--writes` requires the exact `APPLE_CORE_INTEGRATION_ACK=I_AM_USING_DISPOSABLE_ACCOUNTS` acknowledgement. Calendar, Reminders, Notes, and Mail mailbox mutations run only when their corresponding `APPLE_CORE_TEST_*` disposable-container variable is set, and the harness cleans up every fixture it creates.

```bash
APPLE_CORE_INTEGRATION_ACK=I_AM_USING_DISPOSABLE_ACCOUNTS \
APPLE_CORE_TEST_CALENDAR="Apple Core Test" \
APPLE_CORE_TEST_REMINDER_LIST="Apple Core Test" \
APPLE_CORE_TEST_NOTES_ACCOUNT="Disposable iCloud" \
APPLE_CORE_TEST_MAIL_ACCOUNT="Disposable Mail" \
Scripts/integration_test.py --writes
```

## Release Gate

Apple Core is licensed GPL-3.0-or-later (see `LICENSE.md`, `NOTICE`, and `docs/planning/BUILD_PLAN.md` §4 for the full attribution discipline). Before publishing a binary:

- Confirm every donor whose code or substantially-derived design has actually been lifted into a surface implementation (not just researched) has a corresponding entry in `NOTICE` and a license copy in `THIRD_PARTY_LICENSES/`, per §4.2.
- Confirm the current tree contains no private deployment values (API keys, personal iCloud account identifiers used in test fixtures, etc.).
- Confirm `security find-identity -v -p codesigning` sees the intended Developer ID Application identity and the Team ID matches the project.
- Validate the exported app with `codesign`, `spctl`, `stapler`, and a clean-machine installation smoke test.

## Local Preflight

From a clean worktree on a supported Mac:

```bash
swift format lint --strict --recursive .
xcodebuild -project "Apple Core.xcodeproj" -scheme "Apple Core" -configuration Debug -destination "platform=macOS" build
xcodebuild -project "Apple Core.xcodeproj" -scheme "Apple Core" -configuration Debug -destination "platform=macOS" test
gitleaks git --redact
```

## Build, Sign, Notarize, and Package

Choose the next version, then run `Scripts/release.sh` (defaults to `APP_NAME`/`SCHEME` of "Apple Core"; override via env vars documented in `Scripts/release.sh help`):

```bash
VERSION=1.0.0 Scripts/release.sh check      # quick release-build check
VERSION=1.0.0 Scripts/release.sh bump       # bump MARKETING_VERSION / CURRENT_PROJECT_VERSION
VERSION=1.0.0 Scripts/release.sh archive    # xcodebuild archive
VERSION=1.0.0 Scripts/release.sh export     # export Developer ID signed app (requires TEAM_ID / signing identity)
VERSION=1.0.0 Scripts/release.sh package    # zip + sha256
```

`Scripts/release.sh all` uses the verified `notarytool-profile` keychain profile by default and performs the complete signed, notarized, stapled, and validated local preparation. Override `KEYCHAIN_PROFILE` if another Mac uses a different profile name. Individual subcommands remain available for diagnosis, but `commit` also refuses to tag an app that fails Developer ID, Gatekeeper, or stapler validation.

Notarization (`Scripts/release.sh notarize`, `staple`) requires `KEYCHAIN_PROFILE` pointing at App Store Connect credentials. A public release must be Developer ID signed, notarized, stapled, and validated before packaging. Ad hoc or unnotarized builds are for local development only.

## Publish

```bash
VERSION=1.0.0 Scripts/release.sh commit     # commit version bump, tag v1.0.0
VERSION=1.0.0 Scripts/release.sh push-tags  # push the tag (prompts for confirmation)
```

Pushing the tag triggers `release.yml`, which re-runs CI as a gate and creates the GitHub release (using `docs/release-notes/vX.Y.Z.md` if present, otherwise auto-generated notes).

If a signed/notarized DMG or zip was produced locally, attach it:

```bash
VERSION=1.0.0 Scripts/release.sh upload
```

## Sparkle Auto-Updates

Apple Core ships Sparkle 2 (mirroring ping-warden's setup): `SPUStandardUpdaterController` in the app, "Check for Updates…" in the status menu, and a signed appcast served from GitHub Pages at `https://oliverames.github.io/apple-core/appcast.xml` (the `SUFeedURL` in `App/Info.plist`).

- **Keys (one-time, done 2026-07-20):** the EdDSA keypair was generated with Sparkle's `generate_keys`; the public key is in `App/Info.plist` (`SUPublicEDKey`) and the private key lives in the login Keychain as "Private key for signing Sparkle updates". Never export or commit the private key.
- **Per release**, after `package` (and `notarize`/`staple` if signing):

```bash
VERSION=1.0.0 Scripts/release.sh appcast   # signs dist/Apple Core-1.0.0.zip, prepends an item to appcast.xml
```

  The item's release notes come from `docs/release-notes/v<version>.md`, rendered to HTML by `Scripts/render_release_notes.sh` — write that file first. The enclosure URL points at the GitHub release asset, so `upload` must publish the same zip that was signed.

- **Publish the appcast** by copying the updated `appcast.xml` to the `gh-pages` branch and pushing (Pages serves that branch, matching ping-warden):

```bash
git worktree add /tmp/apple-core-pages gh-pages
cp appcast.xml /tmp/apple-core-pages/ && cd /tmp/apple-core-pages
git add appcast.xml && git commit -m "appcast: v<version>" && git push origin gh-pages
cd - && git worktree remove /tmp/apple-core-pages
```

Updates are EdDSA-verified before extraction (`SURequireSignedFeed`/`SUVerifyUpdateBeforeExtraction` are enabled), so an appcast item with a bad or missing signature is rejected by clients.

**Do not run any of the publish steps without explicit confirmation for each release** — this file documents the mechanism, it is not a standing authorization to cut releases.
