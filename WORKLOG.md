# Apple Core worklog

## 2026-07-21 — Public release posture, Sparkle, full parity backlog

- **Repo made public** under GPL-3.0-or-later (Oliver's call; Gitleaks full-history scan green beforehand).
- **Sparkle 2 auto-updates** wired per ping-warden's pattern: `SPUStandardUpdaterController` with explicit startup, "Check for Updates…" menu item, EdDSA keys (public in Info.plist, private in login Keychain), signed-feed enforcement, `release.sh appcast` signing command + `render_release_notes.sh`, appcast served from the `gh-pages` branch via GitHub Pages (live, HTTP 200).
- **MCP compliance verified** (`docs/planning/MCP_COMPLIANCE.md`): all tool schemas valid against JSON Schema 2020-12, protocol 2025-06-18 negotiated, Claude Code enumerated every tool live; Codex config accepted (authenticated enumeration is a follow-up). Pinned swift-sdk already supports `outputSchema`/`structuredContent` — wiring them is queued.
- **Parity backlog completed in two waves** (21 → 75 tools served): Messages send + group chats; Calendar/Reminders full CRUD plus shared RFC 5545 recurrence parser (30/30 fixtures); Mail 5 → 26 tools (triage, compose, threads, stats, attachments, mailbox CRUD, templates); Notes 8 → 19 (folders, move, markdown converter, attachments, batch ops). Exclusions are evidence-documented in each service's header (Mail rules, Notes DB-backed tools, reminder subtasks — no public API even in the macOS 27 beta SDK this machine runs).
- **UX pass**: Bridgeport-style settings panes reworked to native forms, Remote Access terminology, Open at Login, connector app icon generated from the menu bar symbol, approval-window close-as-deny fix, and a config save-clobber loop fixed (tolerant CloudflareSettings decoding + merge-on-save + reload-on-appear).
- **Cloudflare remote access configured and verified**: tunnel `apple-core` → `https://applecore.amesvt.com/mcp`, 401 unauthenticated, full MCP round-trips with bearer token.
- **Still open**: runtime write-path integration tests (disposable accounts per BUILD_PLAN §3.2/§5.1), TCC grants via UI toggles, outputSchema wiring, Codex authenticated enumeration, new AppIcon artwork if the placeholder should be replaced, first release cut (explicitly awaiting Oliver's go).

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
