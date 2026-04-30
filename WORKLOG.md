# Apple Core worklog

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
