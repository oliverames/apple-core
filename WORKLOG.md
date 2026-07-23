# Apple Core worklog

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
