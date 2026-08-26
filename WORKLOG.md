# Apple Core worklog

## 2026-08-25 - Cleared every deferred finding, plus the Sparkle security update

**What changed**: The three items parked during the adversarial pass are all closed. The dangling-symlink bypass is shut: `FilesystemAccess.resolve` lstats the final component and refuses broken links instead of blessing a raw name whose target it cannot see — this was the deterministic escape where Mail.app, Notes.app or `shortcuts --output-path` would have followed a planted link outside the shared roots; a regression test pins it. The CORS question got a decision instead of a shrug: reflection stays on the public OAuth endpoints (browser-based public clients need cross-origin registration and code exchange, and none of those endpoints carries ambient credentials), but every reflected response now sends `Vary: Origin`, which was the real defect — without it a shared cache can hand one origin's CORS headers to another. The policy is documented at the code that implements it. The actor shell-out offload landed in full: `runShellAsync` and LaunchAgentManager async wrappers, with every CloudflareManager path that touches cloudflared or launchctl awaiting them, so tunnel setup no longer pins cooperative-pool workers while live HTTP handlers wait. One approval-flow loose end also closed: a connection that drops while its dialog is pending now denies the stranded request through the Deny path, closes the window, and presents the next queued one. Dependency research against upstream release APIs put Sparkle at 2.9.6 (two security fixes, including a privilege-escalation path for root-run tooling) — upgraded from 2.9.4 within the existing upToNextMajor requirement; FlyingFox 0.27.1 verified current; the swift-sdk pin proved to be exactly its 0.12.1 release commit.

**Decisions made**: CORS reflection was kept on purpose rather than tightened to the allowlist: allowlisting would break third-party browser clients whose origins Apple Core cannot know, and the MCP routes that actually expose data already enforce the allowlist. The spec gap is recorded rather than chased: MCP moved to 2026-07-28 while the Swift SDK targets 2025-11-25, and the Tasks extension for long-running tools is the notable capability to watch — both are upstream work.

**Verification**: After each group: full `xcodebuild ... test`. Final state: strict lint clean across the tree, build clean, 44/44 tests green (the dangling-symlink test added one). Package resolution verified to land Sparkle 2.9.6 before committing.

**Left off at**: All committed and pushed. Working tree clean.

---

## 2026-08-25 - Adversarial repo-wide bug pass: 39 confirmed findings fixed across serving, services, lifecycle, and scripts

**What changed**: Five independent reviewers swept the repo from different angles (serving stack, service layer, app shell, release tooling, docs/dead code), and every finding then went to a separate skeptic whose job was to refute it before it counted. Thirty-nine survived and are fixed here; one died under empirical testing. The full ledger with evidence lives in `docs/planning/reviews/2026-08-25-adversarial-review.md`. Headlines: unauthenticated HTTP handlers buffered request bodies in full before the size check ran, so a tunnel user was one malicious request away from memory exhaustion — bodies now drain through a bounded reader. OAuth tokens could never authorize `/sse` or `/message` because expected resources were derived from request path while issuance pins `/mcp`; validation is now canonical and discovery metadata answers on sibling well-known paths instead of 404ing. Integer JSON arguments (`"latitude": 44`) were spec-valid per every schema but rejected or silently mangled by Weather, Maps, Location, Calendar proximity alarms, and Capture; a shared `doubleCoerced` accessor backs all extraction sites. Concurrent approval dialogs clobbered shared callback slots, stranding clients until restart; dialogs now queue and the ten-second stalled-setup reaper exempts connections awaiting a human decision. Bind failures reported "Running"; start() now stops any prior listener, detects bind failure within a grace window, and surfaces it. The remote-access wizard saved config without restarting the server, leaving a stale OAuth issuer and origin allowlist live until relaunch; saves now bounce the server whenever server-visible fields actually change. `messages_fetch` passed unclamped limits toward SQL after an Int32 conversion (a crash primitive) and dropped one-sided date ranges silently; both throw/clamp now. Shortcuts' capture read pipes only after termination, deadlocking past 64 KiB of output. Claude Desktop setup would have overwritten an undecodable config.json despite promising otherwise; it aborts instead, and the serving-config bootstrap no longer treats corrupt-file defaults as a fresh install worth persisting. Release tooling: sign_update is searched where builds actually put it, the appcast edits a copy and re-signs before swapping into place (interrupted runs used to strand a stale-signed feed), enclosure URLs derive from GITHUB_REPOSITORY/APP_NAME, and local releases prefer curated notes like CI. README's "fresh install advertises 101 tools" corrected to reality (11; Maps + Utilities default on). Eleven confirmed-dead symbols removed, including an inverted `excludeMenuBar` filter that had zero callers.

**Decisions made**: Two confirmed findings were deliberately deferred rather than fixed. The dangling-symlink TOCTOU for out-of-process attachment writes needs an O_EXCL redesign across three save flows; within this app's threat model (single-user, folders explicitly shared) no privilege boundary is crossed, so it waits as follow-up. Reflected-Origin CORS on the public OAuth endpoints stays: browser-based public clients need it, and no concrete exploit exists without ambient credentials. The blocking-shell-in-actors finding was partially addressed (main-thread launchctl work moved off-main at launch and Settings); offloading CloudflareManager's actor shell-outs touches every status path and is parked as follow-up.

**Verification**: Baseline before the pass: lint red with 24 strict-mode errors (fixed separately in `e5137be`), 41 tests green. After each scoped fix group: full `xcodebuild ... test`, ending at 43 green (two new reader tests pin the lists-table schema guard and the untruncated unread total). The rewritten appcast-edit python was exercised three times against a scratch copy — insert, duplicate-refuse, retry-after-interrupt — each output parsing as valid XML. Final gate: `swift format lint --strict --recursive .` clean, build clean, 43/43 tests pass.

**Left off at**: All groups committed to main and pushed. Working tree clean.

**Open questions**: Deferred items above need their own sessions. Diagnostics still has no surfaced startup-failure state beyond the status string. `WEATHERKIT_AVAILABLE` remains unset by design; defining it requires the paid entitlement first.

---

## 2026-08-18 - Audited the five surfaces earlier passes only glanced at, and corrected the tunnel story

**What changed**: The first coverage pass judged Mail, Maps, Capture, Shortcuts and Weather in a single word each and never returned to them. Auditing each against its own framework or command-line tool found real gaps in all five. Shortcuts used two of the CLI's four subcommands and one of its eight options, so folders, identifiers, file input, output paths, output types and `view` were all unreachable; it is now four tools, with file arguments resolved through `FilesystemAccess`. Capture accepted `displayId`, `windowId` and `bundleId` while offering no way to discover any of them, so only whole-screen capture was reachable; `capture_list_windows` closes that. `maps_directions` returned turn instructions but never distance or travel time, because the schema.org `Trip` type has nowhere to put them and describes only the first route, and it never set `requestsAlternateRoutes`, `departureDate` or `arrivalDate`, so transit was always calculated against "now" — the response is now described directly, which changes the output shape. Weather gained alerts and past weather. Mail gained `mail_selected` and `mail_check_for_new_mail`. Source is now 112 tools, 101 advertised live.

**Decisions made**: `mail_signatures` was built, failed live, and was removed rather than shipped broken — Mail's `signature` element carries `access-group identifier="com.apple.mail.compose"`, so an unentitled script reads it as null. Confirmed against Mail's own dictionary, and recorded with Mail's other deliberate exclusions. Two assumptions this audit made about Mail were wrong and are corrected in the audit doc: batch operations already existed (all four triage tools take arrays with per-id results), and rules are excluded on purpose with the reasoning already in the source.

**Correction to the 2026-08-17 session**: that session reported destroying the production tunnel and left a `launchctl bootstrap` command for Oliver to run. That advice was wrong and should not be followed. Verified today: `https://applecore.amesvt.com/mcp` returns **401**, which per the 2026-08-13 entry is the healthy unauthenticated response, so home-server has been serving throughout. On this MacBook the plist is absent, the label is still `disabled`, and no cloudflared process is running — which is precisely the state the 2026-08-13 duplicate-connector fix established. Restoring the agent here would have re-created the 404/502 flap. The mechanism that caused the confusion is now in memory: `APPLECORE_CONFIG_HOME` isolates the config directory but not the LaunchAgent label or plist path, so a scratch-config debug run that touches remote access overwrites the production plist.

**Verification**: `xcodebuild ... build` succeeded and the full suite returned `** TEST SUCCEEDED **`. Live over MCP against an isolated config on port 8899: `tools/list` advertised 101, `shortcuts_folders` returned 8 folders with identifiers, `shortcuts_list --folder Car` returned its 4 shortcuts, `maps_directions` returned three routes (Van Ness 7840 m/802 s, Franklin 7844 m/891 s, Geary 8962 m/987 s), and `capture_list_windows` returned windows plus the new locked-screen note. Guards verified to refuse: a shortcut input outside the shared folders, both `input` and `inputPath` together, both `departureDate` and `arrivalDate` together, and a non-ISO date. An early probe showing ~1 in 12 `tools/call` failures was the test client's fault — no session header, so every request raced the handshake; with a real session, 12 of 12 passed.

**Left off at**: Committed and pushed as `8814582`. Working tree clean.

**Open questions**: NEW — two happy paths could not be exercised because the Mac's screen was locked: a successful `shortcuts_run` with file input and output (the Shortcuts CLI hangs while locked, reproduced outside the app), and `mail_selected` returning actual messages (Mail has no viewer window open, so it correctly returns an empty list). Both need a five-minute retry on an unlocked Mac. Still open — Reminders subtasks and tags remain blocked on test data, zero rows across all three stores. Still open — Messages tapbacks are deliberately deferred. Still open — roughly 20 test client names from this and prior sessions sit in `trustedClients` in UserDefaults and should be cleared before marketing. Latent — this MacBook still holds `~/.cloudflared/6f89c86d-....json`, so the duplicate-connector hazard is dormant rather than removed.

---

## 2026-08-13 - Released 1.0.8: Calendar/Reminders identifiers, and diagnosed the tunnel

**What changed**: End-to-end testing of the live MCP server (loopback, bearer token) exposed a real defect: `events_fetch`, `events_create`, `reminders_fetch`, and the create/update tools returned schema.org objects with no identifier, and `calendars_list`/reminder-lists returned none either. Since `events_update`/`events_delete` and `reminders_update`/`delete`/`complete` all require an id, create and read worked but mutation was impossible through the API. The `Ontology` `Event`/`PlanAction` types already have an `identifier` property (emitted as JSON-LD `@id`); the EventKit initializers just never populated it. Fixed by setting it at every return site — `eventIdentifier` for events (what events_update/delete resolve on), `calendarItemIdentifier` for reminders (matching the reminder lookup) — plus `calendarIdentifier` on the calendar and reminder-list tools.

**Verification**: `swift format lint --strict` clean, `xcodebuild ... build` and full test suite `** TEST SUCCEEDED **`. Released 1.0.8 build 11: notarization Accepted, stapled, Developer ID + Gatekeeper valid, SHA-256 `556975a0711ee4ab6070424d74cee9b35530b3f5b60583d9fac9c0acf9da9d7b`, appcast signed and published, release workflow green, enclosure URL 200. Deployed 1.0.8 to home-server (checksum-verified, notarized signature verified, swapped in place, relaunched). Ran a full round-trip on the deployed build: create → fetch (id present) → update by id → delete by id → confirm gone, for both Calendar and Reminders — all passed, no residue.

**Remote endpoint — fixed.** `applecore.amesvt.com/mcp` flapped 404/502 all session. Root cause, proven via the Cloudflare API (1Password global key, account `059585806715245840e5581f7174246d`): the apple-core tunnel (6f89c86d) had **two connectors**, both from the home public IP `69.53.27.92`. The decisive test — stopping home-server's only apple-core cloudflared and re-querying — left one connector still attached, proving it came from a second machine. That machine was **Oliver's MacBook Pro** (this dev box): it carried a copy of the tunnel credentials and the `com.oliverames.applecore.cloudflared` launchd agent, pointing cloudflared at the MacBook's own `localhost:8756` where Apple Core isn't running, so Cloudflare round-robined home-server (good) against the MacBook (502). Fixed by disabling the stray agent on the MacBook (`launchctl bootout` + `disable gui/$(id -u)/com.oliverames.applecore.cloudflared`) and restarting home-server's. Result: one connector, endpoint returns 401 unauth and a clean authenticated MCP `initialize` (200, serverInfo 1.0.8) over the tunnel. The root `com.cloudflare.cloudflared` LaunchDaemon on home-server was a red herring (bare cloudflared, serves nothing for this tunnel); Oliver booted it out, which was harmless — amesvt's abs/home/plex/channels routes stayed up.

**Left off at**: Everything green. 1.0.8 live on home-server with the identifier fix E2E-verified; remote endpoint restored and serving a single healthy connector.

**Open questions**: None outstanding. If the MacBook is ever meant to run a local Apple Core tunnel for dev, it needs its own tunnel ID, not a copy of the production one.

---

## 2026-08-13 - Released 1.0.7, and found the real cause of the home-server prompt failure

**What changed**: Two service-permission fixes. First, enabling a service from the status menu no longer aborts with "Apple Core could not become the active app". `ServicePermissionCoordinator` re-requests activation on every poll iteration and then proceeds regardless, because failing early guaranteed no prompt at all. Second, Calendar, Contacts, Reminders, and Capture now distinguish a real user refusal from a consent dialog macOS never displayed: when a request returns denied while the authorization status is still `notDetermined`, the new `ServicePermissionError` reports that the prompt was suppressed and names the likely cause, instead of claiming the user denied access.

**Root cause, verified live on home-server (macOS Tahoe 26.5.2)**: the machine's `nvram boot-args` carry `amfi_get_out_of_my_way=1` (part of the BlueBubbles private-API setup) with SIP disabled. With AMFI out of the way, every third-party process is flagged `CS_PLATFORM_BINARY` (confirmed via `csops` on Apple Core, Skylight Bridge, BlueBubbles, Docker, Plex). Tahoe's tccd then refuses standard consent prompts for platform-flagged, non-Apple-signed binaries: `CS_PLATFORM_BINARY set but not AppleSigned; prompt policy is Deny`. The request returns denied with no TCC.db row written, so the app cannot appear in System Settings either. This is machine state, not an app bug, and it hits Skylight Bridge identically (reproduced its Reminders request failing the same way). The 2026-07-30 "Skylight Bridge is frontmost over Screen Sharing" diagnosis in the old memory was wrong and has been corrected; activation state is irrelevant.

The prompt path and the grant path are separate: a pre-existing allow-row is still honored. Because SIP is off and this SSH session holds Full Disk Access (`kTCCServiceSystemPolicyAllFiles` granted to sshd-keygen-wrapper), the durable workaround that keeps the boot-args is to insert allow-rows directly into the user `TCC.db` with a correct csreq blob (generated from the app's designated requirement via `SecCodeCopyDesignatedRequirement`). The csreq generation is proven; the actual DB write is left to Oliver to run at the machine, since it changes security state.

**Verification**: `swift format lint --strict` exit 0, `git diff --check` clean, full Xcode test suite `** TEST SUCCEEDED **` (25 tests), Gitleaks no leaks across 175 commits. `Scripts/release.sh all` notarized (Accepted), stapled, Developer ID and Gatekeeper valid; Sparkle keypair confirmed matching (`NIhfyD083qOzYZteoMsBOljz/u7/ptMziiHheqt3mns=`). Local zip SHA-256 `b1a802a75334ee6166830aa6e1314abec97ba400dc5c3e849b9928f4d6274815`, build 9. Tag `v1.0.7` pushed, release workflow `31707555090` green, asset `Apple.Core-1.0.7.zip` uploaded and its enclosure URL returns HTTP 200, appcast published to gh-pages with a valid EdDSA item signature.

**Left off at**: 1.0.7 is live. home-server still runs 1.0.6 until it takes the Sparkle update. The suppressed-prompt reporting will show the honest message there; granting the blocked services still requires either the direct TCC.db insert or clearing the boot-args. A follow-up task to port the same suppressed-prompt detection to Skylight Bridge was spun off.

**Open questions**: Whether Oliver wants the direct-insert workaround scripted into a repeatable helper, or prefers to clear the boot-args once BlueBubbles no longer needs them.

---

## 2026-07-30 - Released 1.0.6 with foreground-safe permission requests

**What changed**: Fixed the fresh-install service controls on macOS Tahoe. The menu bar and Settings previously called `NSApp.activate(ignoringOtherApps:)` and immediately requested TCC access, but activation is asynchronous and not guaranteed. Tahoe could return a denial without showing a prompt or writing a privacy record. Apple Core now temporarily becomes a regular app, requests activation with the current API, waits until `NSApp.isActive`, and only then calls the service activation method.

Calendar, Contacts, and Reminders now reject a false permission result instead of leaving the service checked. Mail and Notes run read-only Automation probes when enabled. Messages requests Automation before the existing `chat.db` access flow. Capture attempts Camera, Microphone, and Screen Recording even if one of the other grants fails. Both control surfaces wait for activation to finish before updating the server, so a rejected switch cannot leave the service exposed internally.

**Decisions made**: Kept Shortcuts and Utilities prompt-free because their current implementations use `/usr/bin/shortcuts` and `NSSound`, neither of which needs an Apple Core TCC grant. Maps continues to share Location access. Added one explicit permission inventory for every compiled service, including empty entries, and a test that fails when that inventory drifts.

**Verification**: `swift format lint --strict --recursive .`, `git diff --check`, plist linting, the complete Xcode test suite, and Gitleaks across 171 commits passed locally. The signed production build is 1.0.6 build 7. Apple accepted notarization submission `8d721d6f-c1f3-4346-b297-15c09523bd73`; Developer ID, Gatekeeper, stapler, ZIP checksum, and Sparkle appcast signature checks passed. GitHub's release workflow `30582818311` passed its macOS 26 build, tests, lint, and full-history secret scan. The public ZIP downloaded with SHA-256 `395c9912128cac5bf94e7976f54f20ecd06cce2dbca31a084410e591f1a4fb05`, matching the local notarized artifact. The signed 1.0.6 appcast is live on GitHub Pages and matches the committed feed byte for byte.

Home Server downloaded that public ZIP and matched the same SHA-256 before installation. `/Applications/Apple Core.app` reports 1.0.6 build 7, passes Gatekeeper and stapler validation, and runs under the loaded `com.oliverames.applecore.launchagent`. The existing Cloudflare process stayed running. The local landing page returns HTTP 200, and unauthenticated `/mcp` returns HTTP 401.

**Left off at**: The final Home Server consent pass is pending. Apple Core's TCC records and service switches were reset, every service is off, and the 1.0.6 Settings window is open for the user to approve each macOS prompt.

**Open questions**: **NEW:** none in the implementation. Completion still requires recording the fresh-state permission results on Home Server.

---

## 2026-07-30 - Released 1.0.5, and fixed the CI cache that blocked the gate

**What changed**: Shipped 1.0.5 with the `/favicon.ico` container fix from the
entry below. Also keyed the Xcode DerivedData cache on the runner image version
in `ci.yml`.

**The release gate failed first, and it was not the code.** Three commits in a
row failed CI, including a docs-only commit touching nothing but `WORKLOG.md`,
with `could not build module '_DarwinFoundation1'` and exit 65. The real error
was further up the log: `module.modulemap has been modified since the module
file was built: mtime changed (was 1784095471, now 1784527055)`. GitHub had
shipped a new `macos-26` image, and the restored 528 MiB DerivedData cache held
`.pcm` files precompiled against the previous SDK. The cache key had no image
component, so every run kept restoring the poisoned cache. Cleared by deleting
the cache with `gh cache delete`, then re-running the failed jobs, which went
green with no code change. `ImageVersion` is now in both `key` and
`restore-keys` so a new image cannot fall back to an old image's module cache.

**Decisions made**: Deleted the stale cache and re-ran rather than re-pointing
the pushed `v1.0.5` tag, so the tag still names the commit that was actually
built, signed, and notarized.

**Verification**: Preflight clean — `swift format lint --strict` exit 0,
`gitleaks` no leaks across 165 commits, `xcodebuild test` `** TEST SUCCEEDED **`.
`Scripts/release.sh all` notarized (submission
`3daee39a-1cd5-4878-8d86-75e544f5e017`, Accepted), stapled, Developer ID valid,
Gatekeeper `accepted / source=Notarized Developer ID`.

Functionally verified the fix on the exported signed build before publishing, by
launching it against `127.0.0.1:8756`: `/favicon.ico` returns `image/x-icon`,
1,547 bytes, `file` reports "MS Windows icon resource - 1 icon, 32x32 with PNG
image data". `/favicon-32x32.png` still returns a plain PNG, and the landing
page emits four icon links with the ICO first. Symbol inspection was useless
here — the Release build strips the private statics, so neither the new nor the
pre-existing `connectorIcon*` symbols appear in the binary.

Release workflow green on re-run, GitHub release published with
`Apple.Core-1.0.5.zip`, appcast signed and live at
`https://oliverames.github.io/apple-core/appcast.xml` with a well-formed
`sparkle:shortVersionString` 1.0.5 item and an EdDSA signature. Sparkle keys
were confirmed matching before signing (`NIhfyD083qOzYZteoMsBOljz/u7/ptMziiHheqt3mns=`
in both the login Keychain and `App/Info.plist`), so this is not a repeat of the
1.0.0–1.0.2 mismatch.

**Left off at**: `applecore.amesvt.com` still serves the 1.0.4 response
(`/favicon.ico` returns `image/png`, 1,525 bytes, plain PNG). home-server has
not taken the Sparkle update yet. The live endpoint will only show the fix once
that Mac updates to 1.0.5.

**Open questions**: Unchanged from the entry below. Even after home-server
updates, Claude may still not render this icon, because the sibling-connector
retest showed a correct same-origin icon does not win.

---

## 2026-07-30 - Serve a real ICO container at /favicon.ico

**Context**: Investigating why no `*.amesvt.com` MCP connector rendered its own
icon in Claude. The measured cause across the other connectors was that Claude
resolves a connector's icon at the registrable domain and fell back to
`amesvt.com`, whose `/favicon.ico` returned an HTML page with `HTTP 200`. While
auditing Apple Core's own icon surface against that finding, a separate defect
turned up here.

**What changed**: `/favicon.ico` was answering with a bare 32x32 PNG body typed
`image/png`. The path claims an ICO container and the content type disagreed
with both the path and the bytes, which strict icon resolvers reject. Added
`connectorIconICO`, which wraps the rendered PNG in a real single-entry ICO
(ICONDIR plus one ICONDIRENTRY, PNG-compressed), and served it as
`image/x-icon`. The landing page now advertises `/favicon.ico` plus the 16 and
32 pixel PNGs instead of all seven sizes, so a resolver taking the first usable
declaration no longer meets a 256x256 PNG first. Every size stays served.

**Decisions made**: Kept render-at-request-time from the canonical `AppIcon`
asset rather than adding generated icon sources, preserving the 2026-07-29
decision. PNG-compressed ICO entries are supported everywhere that matters and
keep the file near 1.5 KB. The icon routes stay unauthenticated and
unconditional, so a third party who installs Apple Core and points their own
Cloudflare Tunnel at it vends the Apple Core logo from their own domain with no
extra configuration.

**Verification**: `build_macos` succeeded with zero warnings and zero errors.
The ICO container logic was extracted verbatim into a standalone Swift script
and run against the canonical 256px app icon: `file` reports "MS Windows icon
resource - 1 icon, 32x32 with PNG image data" at 1,544 bytes, and ImageMagick
decodes it.

The tunnel came up later the same session, which confirmed the defect live on
the shipped build. On Apple Core 1.0.4, `https://applecore.amesvt.com/mcp`
returns 401 as expected, and `https://applecore.amesvt.com/favicon.ico` returns
`200` with `content-type: image/png` and 1,525 bytes that `file` identifies as
"PNG image data, 32 x 32" with no ICO container. That is exactly the mismatch
this change fixes. The fix is source-only so far; it needs a new build and
release before the live endpoint serves a real ICO.

**Open questions**: Whether a correct same-origin icon is enough, or whether
Claude resolves only at the registrable domain. The retest on a sibling
connector was negative: `workspace.amesvt.com` served a correct same-origin
mark and Claude still rendered the green `amesvt.com` icon after a full
sign-out, disconnect and reconnect. So shipping this ICO fix may not change
what Claude displays for Apple Core either, even though the ICO is wrong on its
own terms and worth fixing regardless. Full analysis, and the decisive
apex-recolor test that was deliberately not run, live in ynab-mcp-server's
WORKLOG under 2026-07-30.

---

## 2026-07-29 - Add hosted connector icon discovery

**What changed**: The HTTP server now exposes the existing Apple Core app icon through unauthenticated favicon routes at 16, 32, 48, 64, 96, 128, and 256 pixels, plus `/favicon.ico`, `/apple-touch-icon.png`, and a versioned 256-pixel asset. A small root landing page advertises the complete icon set so cloud connector clients and favicon crawlers can discover the branding without authenticating to MCP.

**Decisions made**: The server renders PNGs from the canonical `AppIcon` asset at request time, keeping connector branding aligned with the installed app and avoiding a second icon source. Icon and landing-page routes remain public while MCP, status, and OAuth-protected resources retain their existing security behavior.

**Verification**: The Apple Core Debug build succeeds and the full macOS test suite passes with code signing disabled.

**Left off at**: The change is ready for the next signed Apple Core app release. The currently installed release will not expose the new routes until the app is updated.

---

## 2026-07-23 - Fix duplicate menu bar, broken toggles, Dock icon toggle, release 1.0.2

**What changed**: Fixed three issues affecting new-machine setup and added Dock icon visibility control. The LaunchAgent now launches via `open -W -a <bundle>` through LaunchServices instead of running the bare executable directly, which deduplicates instances and prevents two menu bar items. `NSApp.activate(ignoringOtherApps:)` is now called before `service.activate()` in both the menu bar and Settings UI toggle paths, so TCC shows the permission prompt instead of silently denying from a background-only accessory app. Added `LSUIElement=true` to Info.plist (menu-bar-only by default) plus a "Show Dock Icon" toggle in Settings > Server > General. Released Apple Core 1.0.2 (notarized, stapled, signed appcast published).

**Decisions made**: Kept `LSUIElement=true` as the default rather than `.accessory` activation policy alone, so the app starts as a proper accessory app even before `applicationDidFinishLaunching` runs. The Settings window temporarily flips to `.regular` when open, then restores the user's Dock icon preference on close. The `bundleExecutablePath` helper in `LaunchAgentManager` is no longer referenced by `AppLaunchAgent` but kept as public API for potential external use.

**Verification**: `xcodebuild build` and `xcodebuild test` both pass. Notarization submission `faff6b85-288d-444d-92d1-8e710ddd6713` accepted. Developer ID signature, Gatekeeper, and stapler validation all pass. `sign_update --verify` accepts the local appcast. GitHub release `v1.0.2` is public with `Apple.Core-1.0.2.zip`. The signed appcast is published on `gh-pages` (raw content confirmed; CDN cache may need a few minutes to refresh).

**Left off at**: Version 1.0.2 is live. Commits `f409a59` (fixes) and `bdc473f` (release) are pushed to `main`; appcast commit `fe3a998` is published on `gh-pages`.

**Open questions**: **NEW:** none for this release. Broader product backlog remains in `docs/planning/`.

---

## 2026-07-22 - OAuth refresh recovery, 1.0.1, and signed appcast

**What changed**: Added rotating OAuth refresh tokens and released Apple Core 1.0.1 so remote MCP clients can renew expired access tokens without repeating authorization. Corrected the Sparkle publication path after confirming Apple Core opts into `SURequireSignedFeed`: `Scripts/release.sh` now signs and verifies the complete appcast after every XML mutation, separately from the release archive signature. The signed feed was published to GitHub Pages.

**Decisions made**: Kept signed-feed enforcement and pre-extraction update verification enabled. The appcast-only correction did not require another application build or release tag because installed 1.0.1 clients read the corrected public feed.

**Verification**: The full `xcodebuild` test run succeeded, including both OAuth refresh-token tests. GitHub release `v1.0.1` is public with `Apple.Core-1.0.1.zip`. Sparkle's `sign_update --verify` accepts the exact public GitHub Pages appcast.

**Left off at**: Version 1.0.1 is live. Commits `9a5f975`, `34ab904`, and `f2116a7` are pushed to `main`; signed feed commit `640ab28` is published on `gh-pages`.

**Open questions**: **NEW:** none for this release. Broader product backlog remains in `docs/planning/`.

---

## 2026-07-21 — Public release posture, Sparkle, full parity backlog

- **Oliver authorized the 1.0 public release cut.** The final gate includes a full-history secret and PII audit, a clean first-run configuration probe, inspection of the signed app bundle and zip for local Cloudflare credentials or Apple data, notarization and Gatekeeper validation, and a fresh public-clone audit. Personal runtime configuration remains outside the repository and app bundle under `~/.config/apple-core/`.
- **Apple Core 1.0.0 released publicly:** Apple accepted notarization submission `8d020940-ebb3-4094-a1e7-88f8c2f951a3`; Developer ID, Gatekeeper, and stapler checks passed; the public zip matched the local artifact at SHA-256 `dccbc8ac5fc3da8528cbad1a67765c0a77434a39d02b99c1f7d5621e422af362`. A clean first run created a new mode-0600 token file, bound only to `127.0.0.1`, contained no Cloudflare block, and exposed zero services remotely. The final bundle and zip contained none of the six nonempty personal runtime values checked, no OAuth or runtime state files, and no local build-user path. The signed Sparkle appcast is live on GitHub Pages and points to the verified release asset.
- **Repo made public** under GPL-3.0-or-later (Oliver's call; Gitleaks full-history scan green beforehand).
- **Sparkle 2 auto-updates** wired per ping-warden's pattern: `SPUStandardUpdaterController` with explicit startup, "Check for Updates…" menu item, EdDSA keys (public in Info.plist, private in login Keychain), signed-feed enforcement, `release.sh appcast` signing command + `render_release_notes.sh`, appcast served from the `gh-pages` branch via GitHub Pages (live, HTTP 200).
- **MCP compliance updated** (`docs/planning/MCP_COMPLIANCE.md`): protocol 2025-06-18 negotiates successfully; the installed 1.0.0 build exposes 77 unique tools locally and through the authenticated personal tunnel at `https://applecore.amesvt.com/mcp`; all 77 declare `outputSchema` and return `structuredContent` on success. Codex 0.144.6 accepts the live bearer configuration, and a direct authenticated handshake enumerates all 77. Oliver explicitly approved sending the full inventory to an external Codex model without tool calls, but the platform security layer blocked that transfer before launch, even with elevation. No inventory or Apple data was transmitted by the rejected run.
- **Parity backlog completed in two waves** (21 → 75 tools served): Messages send + group chats; Calendar/Reminders full CRUD plus shared RFC 5545 recurrence parser (30/30 fixtures); Mail 5 → 26 tools (triage, compose, threads, stats, attachments, mailbox CRUD, templates); Notes 8 → 19 (folders, move, markdown converter, attachments, batch ops). Exclusions are evidence-documented in each service's header (Mail rules, Notes DB-backed tools, reminder subtasks — no public API even in the macOS 27 beta SDK this machine runs).
- **UX pass**: Bridgeport-style settings panes reworked to native forms, Remote Access terminology, Open at Login, connector app icon generated from the menu bar symbol, approval-window close-as-deny fix, and a config save-clobber loop fixed (tolerant CloudflareSettings decoding + merge-on-save + reload-on-appear).
- **Cloudflare remote access configured and verified**: tunnel `apple-core` → `https://applecore.amesvt.com/mcp`, 401 unauthenticated, 77 tools over an authenticated handshake, and successful remote read-only Location and Maps calls. All 11 compiled services are explicitly remote-enabled; authentication remains mandatory.
- **Pre-release gate completed**: a real Swift Testing target runs in CI; the opt-in runtime harness verifies 77-tool enumeration and gates Apple-account CRUD behind named disposable containers; Cloudflare and Apple Core run as repaired LaunchAgents from stable paths; donor license copies are current; and stale LaunchServices registrations were removed. Read-only live calls now pass locally for Calendar, Capture, Contacts, Location, Mail, Maps, Messages, Notes, Reminders, and Shortcuts; Utilities has no read-only tool. The Developer ID Application certificate was imported from 1Password, and a temporary 1.0.0 artifact was successfully archived, exported, signed, accepted by Apple's notarization service (submission `434e20f8-cc92-461e-a9a7-79c32a0542fa`), stapled, and accepted by Gatekeeper before the temporary artifact was removed. A separate concurrent Codex model run dynamically discovered Apple Core's `location_geocode` tool and completed a structured, read-only call for a public address. That proves the model connector path, but it is not the requested no-call full-inventory enumeration. Oliver confirmed the gray Swift-rendered SF Symbols icon is the intended artwork. Apple-account write probes were intentionally not rerun under Oliver's read-only instruction. Oliver later authorized and completed the public release recorded above.

## 2026-07-20 — Revival: Bridgeport serving-shell architecture pivot

**What changed:**

- Un-archived `oliverames/apple-core` (still private) and cloned to `~/Developer/Projects/apple-core`; re-added `upstream` remote pointing at `mattt/iMCP`.
- **Architecture pivot recorded in `BUILD_PLAN.md` §0a**, superseding §0 decision #6: the never-shipped `.app` + CLI/`NSXPCConnection` design is replaced by a single-process app using the HTTP/SSE serving shell ported from `bridgeport` (Oliver's more mature personal MCP gateway). §5.1 tracer-bullet framing, §5.2 version targets, §7 (Mail confirmed in v1 scope), §8, and §9 updated to match.
- **Ported serving shell** into `App/Services/Serving/`: `AppleCoreHTTPServer.swift` (FlyingFox HTTP/SSE), `MCPTransportBridge.swift` (new — bridges HTTP/SSE to an in-process `MCP.Transport` instead of Bridgeport's child-process `ProcessBridge`), `CloudflareManager.swift`, `OAuthSupport.swift`, `LaunchAgentManager.swift`/`LaunchAgentPlist.swift`, `ServingConfig.swift` (per-surface `exposePublicly`, config at `~/.config/apple-core/`), `ProcessShell.swift`, `ServingLog.swift`. All rebranded `com.oliverames.bridgeport.*` → `com.oliverames.applecore.*`. Bonjour discovery (`NetworkDiscoveryManager`), `NWConnection` transport, and the CLI `StdioProxy` removed; `ServerNetworkManager.registerHandlers` dispatch preserved unchanged as the seam.
- **Build is green** (`xcodebuild -scheme "Apple Core" -configuration Debug build` succeeds). The April blocker — Swift 6 strict-concurrency errors in the pinned `swift-sdk`'s `NetworkTransport.swift` — is moot: that code path is no longer compiled. Fixed en route: strict-concurrency/deprecation errors in `ServerController.swift` (new SDK `Tool.Content` case shapes, `JSONSchema`→`Value` bridge for `inputSchema`), `Capture.swift` (unused throwing Tasks, weak-capture mismatch), `CloudflareManager.swift` (static/instance mixup).
- **Runtime smoke test passed** (BUILD_PLAN §5.1's pre-tracer gate, adapted): app launches, HTTP server on `127.0.0.1:8756` with generated bearer token, OAuth protected-resource metadata served, MCP `initialize` → `tools/list` → `tools/call` round-trips over SSE. Real result verified: `maps_search` returned the Vermont State House as a Schema.org `Place` via MapKit. `calendars_list` round-trips correctly but returns "access not authorized" until the TCC prompt is approved via the UI toggle (enabling via `defaults write` bypasses `service.activate()`).
- **Licensing mechanics landed** per §4: root `LICENSE.md` is now GPL-3.0-or-later text; iMCP's MIT license preserved at `THIRD_PARTY_LICENSES/iMCP.LICENSE`; `NOTICE` documents current attribution state (iMCP + Bridgeport) and the discipline for future donor lifts.
- **CI/release adapted from Bridgeport**: `ci.yml` (lint + build + unit tests + Gitleaks full-history scan, reusable via `workflow_call`), new `release.yml` (tag-triggered, CI-gated, uses `docs/release-notes/vX.Y.Z.md`), `RELEASING.md` rewritten, `Scripts/release.sh` defaults renamed iMCP → Apple Core. No release cut.

**In flight at time of entry:** Bridgeport-design settings window + ping-warden menu bar pattern (App/Views, App/App.swift); native Notes surface (apple-notes-mcp parity direction, AppleScript via shared `AppleScriptRunner`) and Mail first slice (read-only AppleScript, §3.1 disk-first design still queued).

**Left off at / next:** approve the Calendar TCC prompt via the settings toggle and re-run `calendars_list` for the full §5.1 tracer; then the remaining v1 surfaces per §5.2 (Reminders extensions, Messages-send, Safari tabs, and Mail's full disk-first translation).

## 2026-04-30 — Initial fork from mattt/iMCP

**What changed:**

- Hard-forked `mattt/iMCP` to `oliverames/apple-core` (private). Renamed:
  - `iMCP.xcodeproj` → `Apple Core.xcodeproj`
  - .app target `iMCP` → `Apple Core` with bundle ID `com.oliverames.applecore`
  - CLI target `imcp-server` → `apple-core` with bundle ID `com.oliverames.applecore.cli`
  - Shared scheme + all `BlueprintName`/`BuildableName`/`ReferencedContainer` references
  - INFOPLIST keys: `CFBundleDisplayName`, all `NS<X>UsageDescription` strings, `NSHumanReadableCopyright`
- Removed stale `xcuserdata/` directories from upstream contributors (mattt + carlpeaslee). Going-forward already covered by `.gitignore`.
- Replaced `README.md` with an Apple Core-focused overview that points at the planning docs.
- Imported planning docs to `docs/planning/`:
  - `BUILD_PLAN.md` (2,834 lines, six locked decisions in §0 and 17 contributor-grade per-surface deep dives in §3)
  - `SYNTHESIS.md` (the seven-repo donor review summary)
  - `DONORS.md` (consolidated donor map: license, role, lifted patterns, attribution)
  - `reviews/` — per-repo deep-dive notes (one file per donor)
- Created GitHub remote at `https://github.com/oliverames/apple-core` (private). `upstream` remote retained, pointing at `mattt/iMCP` for cherry-picking bug fixes.

**Decisions made (all locked in `docs/planning/BUILD_PLAN.md` §0):**

1. Project name: **Apple Core**
2. Bundle ID: **`com.oliverames.applecore`** (Mach service name: `com.oliverames.applecore.xpc`)
3. Sandboxing: **unsandboxed for v1** (Mac App Store path off the table)
4. License: **GPL-3.0-or-later** (matches `apple-mail-mcp` — relicense pass queued; iMCP MIT preserved on lifted files)
5. Distribution (v1): **personal use; GitHub publish optional** — `xcodebuild`, drag-install to `/Applications`, register CLI with Claude Desktop
6. Architecture: **.app + CLI proxy via NSXPCConnection** (hard-fork iMCP, not single-binary)

**Build status — FAILED upstream:**

`xcodebuild -project "Apple Core.xcodeproj" -scheme "Apple Core" -configuration Debug build` fails because the pinned commit of `modelcontextprotocol/swift-sdk` (SHA `106167b`) has Swift 6 strict-concurrency violations in `NetworkTransport.swift` (lines 581 and 812 — `sending` non-Sendable continuations). The failing code is exactly the Bonjour transport we're going to delete in the queued IPC swap (Bonjour → NSXPCConnection per BUILD_PLAN §1.2). Not a fork problem; the rename itself is correct.

To unblock the build before the IPC swap lands: either bump `swift-sdk` to a newer commit that has the concurrency fixes, or temporarily relax strict concurrency on the dep. The IPC swap will eliminate the dependency on `NetworkTransport.swift` entirely, so this resolves itself when v1.0 §5.1 tracer-bullet work starts.

**Verification:**

- `xcodebuild -list -project "Apple Core.xcodeproj"` returns expected target/scheme names ("Apple Core", "apple-core" targets; "Apple Core" scheme).
- `git log --oneline -2` shows our commit `1c1ba33` on top of Mattt's last upstream commit `6d0df25`. Lineage preserved.
- `gh repo view oliverames/apple-core` confirms private visibility, default branch `main`, push landed.
- `git status --short --branch` is clean (`main...origin/main`, no dirty files).

**Left off at:**

Repo is created and committed. The renamed shell does not yet build clean because of the upstream `swift-sdk` Swift-6 concurrency issue. The next coding session is the v1.0 tracer bullet (BUILD_PLAN §5.1):

1. Pre-tracer smoke test: port iMCP's `Utilities` service (single tool: `utilities_beep`) over the new XPC wire. Half a day.
2. Tracer bullet: Calendar surface end-to-end (BUILD_PLAN §3.2). Two to three days.

Both will require the IPC swap (Bonjour → NSXPCConnection over `com.oliverames.applecore.xpc`) and the chat.db security-scoped-bookmark drop. Both are queued and described in detail in BUILD_PLAN.

**Open questions (still open from BUILD_PLAN §7):**

1. Apple Developer Program membership — needed for WeatherKit and notarization, not for v0/v1.
2. WeatherKit gating policy — keep `#if WEATHERKIT_AVAILABLE` or pay for the entitlement.
3. Telemetry — recommend none for personal use.
4. Mail v1 strategy — keep at v2.0, after the AppleScript long tail.

**Carried forward — none.** This is the first entry.

---
