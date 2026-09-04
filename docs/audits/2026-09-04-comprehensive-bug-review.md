# Apple Core bug review and release round

Date: 2026-09-04. Author: Oliver Ames.

## Work list

- [x] Review previous work and establish repository and release state.
- [x] Inventory source, tests, distribution, and existing verification.
- [x] Verify the baseline checks and retained test report.
- [x] Challenge suspected defects and implement verified fixes.
- [x] Verify the requested activation-screen revision and repeat final checks.
- [x] Prepare version 1.7.2, build 26, and release artifacts.
- [x] Publish and verify GitHub, Gumroad, R2, and the signed Sparkle feed.

## Starting evidence

The worktree was clean on `main` at `22936e5`, with version 1.7.1/build 25.
The initial inventory covered 108 Swift files, the app and CLI targets, shared
helpers, test target, scripts, CI, release workflow, and distribution runbook.
The first pass changed no files and published nothing.

Baseline evidence retained from 2026-09-04:

- Swift formatting, shell syntax, ShellCheck, and Python compilation passed.
- Xcode unit report: 173 passed, zero failed, zero skipped.
- Xcode static analysis completed successfully.
- Gitleaks reported five historical findings: three instances of one dummy
  Gumroad key and two Swift private-key parameter declarations. These require
  narrow exclusions before the full-history release check can pass.

## Review coverage

The review covers license persistence and actor concurrency, HTTP/OAuth and
CLI transport, filesystem access and numeric arguments, Maps/Location geometry,
service mutations, subprocess lifecycle, UI state, and release checks.
Independent read-only reviewers challenge the suspected bugs before changes.

The review confirmed nine runtime defect groups and one release-check defect.
All received fixes and regression coverage where applicable. Independent
read-only reviewers checked licensing, input boundaries, OAuth, and subprocess
lifecycle, then reviewed the final changes again. No new third-party code or
dependencies were introduced.

## Confirmed findings and fixes

| Area | Defect and consequence | Fix and evidence |
| --- | --- | --- |
| License cache | Separate Settings/server actors and a disk-blind cache kept removed or replaced licenses active. | Share one actor, compare source bytes on every request, and test independent gates. Live removal immediately returned HTTP 402, and restoration resumed serving. |
| License concurrency | Delayed activation or reverification could restore a deleted license or overwrite newer activation state. | Reject superseded generations and changed disk snapshots. Suspended-verifier tests cover deletion, replacement, deactivation, and signed activation. |
| Gumroad verification | Loose response decoding accepted malformed replies, failed renewals were not revoked, and failed writes could preserve known-revoked access. Settings could reject a valid Gumroad entitlement beside a damaged signed file. | Decode typed responses, recognize failed renewals, retain revocation in memory, report write failures, and use the same entitlement precedence in Settings and serving. Tests verify actual persistence failure and private signed-license file permissions. |
| Filesystem arguments | Extreme pagination and lookback inputs overflowed integer arithmetic and could terminate the app. | Saturate page-end arithmetic and reject unrepresentable lookbacks. Unit and live tests exercise the maximum signed integer. |
| Maps and Location | Invalid coordinates or spans reached MapKit, whose Objective-C exception could terminate the process. The default point-of-interest radius exceeded the SDK limit. | Validate coordinates, spans, and radii before framework calls. Clamp the default radius to the SDK maximum and expose bounds in schemas. Live malformed requests return errors while the server remains responsive. |
| OAuth callbacks | Metadata-backed clients could pass consent with a dynamic loopback port but fail code issuance. Callback comparison also ignored query differences. | Apply one port-only exception during consent and issuance, preserve all other URL components, and retain exact callback binding at redemption. Full issue/redeem tests cover this path. |
| OAuth registry | Registration churn could evict clients with active sessions or pending authorizations. Metadata-backed clients bypassed the registry cap. | Protect active grants and pending codes, cap every registration path, and roll back when all slots are occupied. Churn and capacity tests pass. |
| Client metadata | The fetcher buffered the entire response before checking its size, and retained an unbounded cache. | Stop body consumption at the 5,121st byte, cancel the request, expire old entries, and cap the cache at 256 entries. Boundary tests accept 5,120 bytes and reject 5,121. |
| Subprocesses | Task cancellation could leave AppleScript or Shortcuts children running, and a child that ignored termination could prevent timeout completion. | Centralize completion and cancellation, terminate children immediately, and force termination after a grace period. Tests cover cancellation, timeout, and already-exited processes. |
| Release checks | Full-history secret scanning stopped on known dummy data and Swift type declarations. The CI label incorrectly claimed a full-history scan. | Add narrow exclusions for the exact dummy fixture and declaration, keep default rules enabled, and correct the CI label/runbook. Full-history scanning passes. |

## Rejected candidates and limits

- A stable-tree filesystem search did not traverse an outside-root directory
  symlink. A real fixture refuted the proposed content leak. Concurrent local
  symlink retargeting was not exhaustively stress-tested.
- Installing a Foundation termination handler after process exit did not lose
  the completion event. The already-exited regression test passes.
- Valid extreme map regions did not require a broader geographic restriction.
  The reviewer tested 135 boundary combinations, including zero spans.
- The unused Maps search-completer delegate is cleanup work, not a confirmed
  runtime failure. It remains unchanged.
- Apple-account mutations and purchases were not exercised. No named disposable
  Apple accounts were provided, and this round did not change those operations.
- A separate production Mac was not modified. Its SSH authentication failed at
  the local credential agent, so this review does not claim remote verification.

## Verification on 2026-09-04

- The final Debug app and test bundle build without warnings.
- All 190 tests in 28 suites pass. The baseline contained 173 tests.
- Xcode static analysis, repository-wide Swift formatting, ShellCheck, shell
  syntax, project-plist validation, and whitespace checks pass.
- Gitleaks scans all 304 existing commits with no remaining findings. A final
  scan will include this round's commits before publication.
- The built app launched with an isolated configuration, a read-only temporary
  folder, a short-lived signed test license, and remote access disabled.
- Screenshots confirm the Services and activated License panes render correctly.
- Live MCP enumeration returns 128 unique tools with 128 output schemas.
- Live tests reject invalid Maps/Location geometry and overflowing filesystem
  lookbacks, return an empty extreme-offset page, and immediately enforce license
  removal and restoration without relaunch.
- The production license signer round-trip passes, and the Sparkle public key
  matches the key embedded in the app.

Xcode 27 beta 6's Instruments helper stalled before test execution on two final
`xcodebuild test` attempts. `build-for-testing` succeeded, and the generated
bundle passed through the standalone test runner with a stripped environment.
The release workflow will also run the normal test command on Xcode 26.0.

The review uses repository source and live checks as primary evidence. External
checks used [Apple's point-of-interest request documentation](https://developer.apple.com/documentation/mapkit/mklocalpointsofinterestrequest),
[Gumroad's license-key documentation](https://gumroad.com/help/article/76-license-keys),
and the [Gitleaks action source](https://github.com/gitleaks/gitleaks-action).

## Release verification

During the packaged-app check, the user requested a better activation screen.
Publication paused before the GitHub release, buyer-content update, or update
feed changed. The revised pane separates key entry from bounded file import,
adds the verified purchase URL, collapses verification details, and confirms
deactivation. Its file-import boundary test brings the suite to 191 tests.
The preliminary R2 package was replaced and reverified before feed publication.

The revised Debug build passes all 191 tests in 28 suites, formatting, and static
analysis. Rendered checks confirm the compact form, purchase link, collapsed
details, keyboard submission, and key-specific error feedback. The native file
picker initially opened, but automation timed out in its path-navigation sheet.
A fresh isolated launch of the published app completed native file selection
and activation on 2026-09-04. The rendered activated state matched
the imported signed fixture. The deactivation confirmation appeared, and Cancel
preserved activation. Direct source tests also prove import bounds,
CRLF normalization, successful signature verification, and rejection of invalid
signatures and unrelated files.

The final 1.7.2/build 26 package includes the activation-screen revision.
Developer ID signature validation, Gatekeeper acceptance, and stapled-ticket
validation pass. Apple accepted notarization submission
`0d2453d6-8a0e-4b49-9279-4ee6368a5417` on 2026-09-04.
The ZIP SHA-256 is
`9eb56524663237c889f55153fb70d9ba7e2e455d8f1c09a8e217388ac1576b47`.
The archive and complete appcast signatures verify with the existing signing key.

[CI for the final source](https://github.com/oliverames/apple-core/actions/runs/33915385784)
passed on Xcode 26.0. The tag workflow repeated those checks before creating the
source-only GitHub release. Distribution checks are recorded below.

Final publication checks on 2026-09-04:

- [Apple Core 1.7.2](https://github.com/oliverames/apple-core/releases/tag/v1.7.2)
  is published from tag `v1.7.2` at `41733ea`. The GitHub release contains source
  and notes, with no binary assets, as required by the distribution policy.
- [The release workflow](https://github.com/oliverames/apple-core/actions/runs/33915918042)
  passed its build, tests, secret scan, and publication jobs.
- The public R2 ZIP and checksum are byte-identical to the final local artifacts.
  The downloaded ZIP passes Sparkle verification, Developer ID validation,
  Gatekeeper assessment, and stapled-ticket validation. Its bundle reports
  1.7.2/build 26.
- Gumroad's buyer ZIP is named `Apple.Core-1.7.2.zip`, contains 9,740,846 bytes,
  and downloads with the same SHA-256. The buyer page contains exactly the EULA,
  new ZIP, and license-key block. Older uploads and the first unnamed upload
  remain in the file store but are not embedded or visible to buyers.
- The deployed appcast is byte-identical to the signed repository copy, and
  its complete-feed signature verifies. Pages deployed commit `ab874fa`.
- The downloaded release itself launched in the isolated profile and passed
  enumeration of 128 tools, all six invalid-input checks, extreme pagination,
  immediate license removal (HTTP 402), and restoration without relaunch.

The activation UI uses native controls and a width-limited form, following the
macOS SwiftUI skill. The humanizer pass kept the release notes focused on the
verified changes. A clean second Mac, Apple-account writes, and real purchases
remain outside verified coverage.

The completion audit rechecked the published release and successful release CI,
then downloaded the Gumroad and public R2 ZIPs again. Both retained the recorded
SHA-256, and the live appcast still matched the repository copy. All confirmed
in-scope defects are fixed, the revised activation flow is visually verified,
and the release is published. The separate production Mac remains untouched.

## Wrap-up on 2026-09-04

- [x] Resume the completed release without duplicating publication or worklog entries.
- [x] Confirm the prior final commit is pushed and its CI passed.
- [x] Correct README download and settings-pane drift against live release metadata and source.
- [x] Verify the documentation corrections and prepare their closeout commit.

GitHub reports no binary assets for 1.7.2. The published Gumroad product at
`https://amesconsulting.gumroad.com/l/applecore` lists `Apple.Core-1.7.2.zip`
with 9,740,846 bytes. `SettingsPane` declares Services, Access, Clients, and
License. These observations support the README corrections. No host
configuration, shared plugin files, or production services were changed.
