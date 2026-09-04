# Releasing Apple Core

Apple Core uses two separate automation paths, mirrored from `bridgeport`:

- **CI** (`.github/workflows/ci.yml`) runs on `main`, pull requests, manual dispatch, and as a reusable release gate. It lints (`swift format`), builds, and runs unit tests via `xcodebuild` on the GitHub-hosted `macos-26` image. Gitleaks scans the commit range selected by the event; the local preflight below scans full history. Runtime Apple-account write tests require named disposable containers and run manually, not in CI.
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

Apple Core's source is licensed GPL-3.0-or-later (see `LICENSE.md`, `NOTICE`, and
`docs/planning/BUILD_PLAN.md` §4 for the full attribution discipline; the
signed binary is sold under `EULA.md` — see `docs/licensing.md` for the
dual-license runbook). Before publishing a binary:

- Confirm every donor whose code or substantially-derived design has actually been lifted into a surface implementation (not just researched) has a corresponding entry in `NOTICE` and a license copy in `THIRD_PARTY_LICENSES/`, per §4.2.
- Confirm the binary is **not** incorporating any GPL-licensed third-party code (including any translation of `apple-mail-mcp`; see `docs/planning/BUILD_PLAN.md` §4.4 and `CONTRIBUTING.md`). An unlicensed source build must not ship a licensed payload.
- Confirm the license public key embedded in `App/Services/Serving/LicenseGate.swift` (`AppleCoreLicensePublicKey.base64`) still verifies against the Keychain private key: `swift Scripts/sign_license.swift pubkey` must reproduce the embedded string, and a round-trip test (`sign` with a test payload then `verify` with `--public-key` on that payload) must pass.
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
VERSION=1.0.0 Scripts/release.sh package    # creates Apple.Core-1.0.0.zip + sha256
```

`Scripts/release.sh all` uses the verified `notarytool-profile` keychain profile by default and performs the complete signed, notarized, stapled, and validated local preparation. Override `KEYCHAIN_PROFILE` if another Mac uses a different profile name. If the profile is unavailable, set `NOTARY_KEY_FILE`, `NOTARY_KEY_ID`, and `NOTARY_ISSUER_ID` together from a temporary, private 1Password-backed scratch directory. The script never stores those values in the repository. Individual subcommands remain available for diagnosis, but `commit` also refuses to tag an app that fails Developer ID, Gatekeeper, or stapler validation.

Notarization (`Scripts/release.sh notarize`, `staple`) requires either `KEYCHAIN_PROFILE` or the complete three-variable API-key set above. A public release must be Developer ID signed, notarized, stapled, and validated before packaging. Ad hoc or unnotarized builds are for local development only.

## Publish

```bash
VERSION=1.0.0 Scripts/release.sh commit     # commit version bump, tag v1.0.0
VERSION=1.0.0 Scripts/release.sh push-tags  # push the release commit and tag (prompts for confirmation)
```

The command pushes the current `main` or `master` branch with the tag. The tag then triggers `release.yml`, which re-runs CI as a gate and creates the GitHub release (source + notes only; see below) using `docs/release-notes/vX.Y.Z.md` if present, otherwise auto-generated notes.

GitHub releases no longer carry the signed DMG — see `docs/licensing.md`. The notarized zip (`dist/Apple.Core-<version>.zip` + `.sha256` from `Scripts/release.sh package`) is distributed through Gumroad under `EULA.md`; do not run `Scripts/release.sh upload` for normal releases (that subcommand now refuses and points at Gumroad).

## Sparkle Auto-Updates

Apple Core ships Sparkle 2 (mirroring ping-warden's setup): `SPUStandardUpdaterController` in the app, "Check for Updates…" in the status menu, and a signed appcast served from GitHub Pages at `https://oliverames.github.io/apple-core/appcast.xml` (the `SUFeedURL` in `App/Info.plist`).

- **Keys (rotated 2026-07-30, for 1.0.3):** the EdDSA keypair lives in the login Keychain as "Private key for signing Sparkle updates"; the matching public key is in `App/Info.plist` (`SUPublicEDKey`). Never commit the private key.

  Releases 1.0.0 through 1.0.2 shipped `qMLqpF6nJjBtvt0UMuGfe6zy4/psV9nTA/YHsXU4uqs=`, whose private half was absent from the login Keychain, from 1Password, and from disk, while the appcast was signed with the Keychain key. Every one of those builds therefore rejected the feed as improperly signed. 1.0.3 adopts the Keychain key `NIhfyD083qOzYZteoMsBOljz/u7/ptMziiHheqt3mns=` and those installs need a one-time manual reinstall.

  **Before signing a release, confirm the two keys still match**, because a mismatch is invisible until a user tries to update:

```bash
"$(Scripts/release.sh --print-sign-update-path 2>/dev/null || find ~/Library/Developer/Xcode/DerivedData -type f -name generate_keys -path '*Sparkle*' | head -1)" -p
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/Info.plist
```

  The private key is backed up in 1Password as the Secure Note **"Apple Core Sparkle EdDSA Private Key"** in the Development vault, alongside the sibling Image Relay item. The last line of that note is the key; the lines above it record which public key it matches and why. Restore and verify with:

```bash
op read "op://Development/Apple Core Sparkle EdDSA Private Key/notesPlain" | tail -1 > /tmp/sparkle.key
sign_update --ed-key-file /tmp/sparkle.key <file>   # signature must verify against SUPublicEDKey
rm /tmp/sparkle.key
```

  Verified 2026-07-30 by signing with the vaulted copy and checking the signature against the shipped public key. Losing the login Keychain must never again force a rotation on everyone.
- **Per release**, after `package` (and `notarize`/`staple` if signing):

```bash
VERSION=1.0.0 Scripts/release.sh appcast   # signs dist/Apple.Core-1.0.0.zip, prepends an item to appcast.xml
```

  The item's release notes come from `docs/release-notes/v<version>.md`, rendered to HTML by `Scripts/render_release_notes.sh`; write that file first.

  **Enclosure URL (since 1.7.0):** GitHub releases carry no binary, so Sparkle downloads the zip from the `ames-website-assets` R2 bucket, served at `https://assets.amesvt.com/apple-core/<zip>`. Pass `ENCLOSURE_URL` to the `appcast` step (or to `all`), upload the zip and its `.sha256` before the appcast goes live, and purge the two URLs from Cloudflare's cache if anything fetched them before the upload landed, because the edge caches the 404 for an hour and `HEAD` will lie to you by returning 200 while `GET` still serves the cached 404:

```bash
VERSION=1.7.0 BUILD_NUMBER=<n> ENCLOSURE_URL="https://assets.amesvt.com/apple-core/Apple.Core-1.7.0.zip" Scripts/release.sh all
op run --env-file=$HOME/.claude/.env -- sh -c 'for f in dist/Apple.Core-1.7.0.zip dist/Apple.Core-1.7.0.zip.sha256; do rclone copyto --s3-no-check-bucket --s3-provider Cloudflare --s3-access-key-id "$CLOUDFLARE_R2_WEBSITE_ASSETS_ACCESS_KEY_ID" --s3-secret-access-key "$CLOUDFLARE_R2_WEBSITE_ASSETS_SECRET_ACCESS_KEY" --s3-endpoint "$CLOUDFLARE_R2_WEBSITE_ASSETS_ENDPOINT" --s3-region auto "$f" ":s3:$CLOUDFLARE_R2_WEBSITE_ASSETS_BUCKET/apple-core/$(basename "$f")"; done'
# then GET the zip, compare its sha256 with dist/*.sha256, and compare sign_update's enclosure signature with the appcast item
```

  `--s3-no-check-bucket` matters: the scoped R2 key cannot list or create buckets, and without the flag rclone tries `CreateBucket` first and fails with `AccessDenied`. The same zip is also attached to the Gumroad product (`gumroad products update <id> --file dist/<zip> --file-name <zip>`) as the buyer deliverable. Pass the filename explicitly: omission produced an unnamed file entry during the 1.7.2 release. Verify the uploaded name, size, and downloaded checksum. Use `gumroad products content get`, then `content set --page <page-id> --dry-run`, to replace the old visible download while preserving the EULA, license-key block, and any other buyer content. Removing an old embed does not delete its uploaded file. `SURequireSignedFeed` also requires a signature over the complete appcast XML. The script adds and verifies that feed signature after every edit.

- **Publish the appcast** by copying the updated `appcast.xml` to the `gh-pages` branch and pushing (Pages serves that branch, matching ping-warden):

```bash
git worktree add /tmp/apple-core-pages gh-pages
cp appcast.xml /tmp/apple-core-pages/ && cd /tmp/apple-core-pages
git add appcast.xml && git commit -m "appcast: v<version>" && git push origin gh-pages
cd - && git worktree remove /tmp/apple-core-pages
```

Updates are EdDSA-verified before extraction (`SURequireSignedFeed`/`SUVerifyUpdateBeforeExtraction` are enabled), so an appcast item with a bad or missing signature is rejected by clients.

**Do not run any of the publish steps without explicit confirmation for each release** — this file documents the mechanism, it is not a standing authorization to cut releases.
