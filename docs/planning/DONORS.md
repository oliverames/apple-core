# Donor map

This doc consolidates the seven upstream MCP servers that contributed code, patterns, or design decisions to Apple Core. Each donor is listed with its license, activity status as of 2026-04-30, the specific role it plays in the synthesis, and the patterns we plan to lift. Per-donor deep-dive review notes live in [`reviews/`](reviews/).

**License compatibility note**: Apple Core is being relicensed to GPL-3.0-or-later (queued; see [`BUILD_PLAN.md` §0 decision 4](BUILD_PLAN.md) and §4). Six of the seven donors are MIT — one-way compatible into GPL via composition; their LICENSE files will live in `THIRD_PARTY_LICENSES/` and per-file MIT headers stay intact on lifted files. The seventh (`apple-mail-mcp`) is GPL-3.0-or-later — fully compatible with our chosen license, lifted directly without clean-room overhead.

**De-duplication note**: `Dhravya/apple-mcp` and `supermemoryai/apple-mcp` are the same project republished under two GitHub orgs — Dhravya works at Supermemory. Two reviewers converged on this finding from independent reads (the `package.json` `repository` field on the supermemory copy still points at `Dhravya/apple-mcp`, the manifest author is Dhravya, the commit history is identical). They are listed separately below for completeness, but for code-lift purposes treat them as one donor.

---

## 1. mattt/iMCP — *the structural base*

| | |
|---|---|
| **URL** | https://github.com/mattt/iMCP |
| **Author** | Mattt (mat.tt), author of the official Swift MCP SDK |
| **License** | MIT (Copyright Mattt 2025) |
| **Last commit** | 2026-01-30 |
| **Activity (90d)** | 4 commits — lightly active, polished |
| **Review** | [`reviews/iMCP.md`](reviews/iMCP.md) |

**Role:** the Xcode project, the .app + CLI architecture, and several surface implementations Apple Core inherits via hard-fork. Without iMCP we would be building the entire macOS-app scaffold from scratch.

**Patterns/code lifted (with attribution per file via preserved MIT headers):**

- **App + CLI split.** The `App/` and `CLI/` folder layout. The CLI is bundled inside the `.app` and launched by MCP clients via stdio.
- **Per-surface `Sources/<Surface>Service/` module structure.** One folder per surface registered with the MCP server via an actor-isolated tool dispatcher. Calendar, Reminders, Contacts, Location, Maps, Messages-read, Weather, Capture, Shortcuts all already exist.
- **MenuBarExtra UI** (`MenuBarExtraAccess` package).
- **Per-client approval gate** (`ConnectionApprovalView` + `@AppStorage("trustedClients")`).
- **JSON-LD / Schema.org outputs via `Ontology`** package (Mattt's other project). Tool results encoded as `Person`, `Conversation`, `Event` instead of ad-hoc dictionaries.
- **`madrid` package** (Mattt's typedstream decoder) for Messages `attributedBody` decoding.
- **`Tool.Annotations` set on every tool** (`readOnlyHint`, `destructiveHint`, `openWorldHint`).
- **swift-format strict + warnings-as-errors** CI configuration.

**Patterns we deliberately drop or replace:**

- **Bonjour `_mcp._tcp` discovery** → replaced with `NSXPCConnection` over Mach service `com.oliverames.applecore.xpc` (BUILD_PLAN §1.2). The `NetworkTransport.swift` in Mattt's swift-sdk-pinned commit is exactly the file that fails to compile under Swift 6 strict concurrency — and it's the file we're deleting.
- **Sandboxed access via `NSOpenPanel` + security-scoped bookmark for chat.db** (in `MessageService`) → unsandboxed v1 reads `~/Library/Messages/chat.db` directly (BUILD_PLAN §3.6).
- **Sparkle appcast at `downloads.imcp.app/appcast.xml`** → not in v1 distribution (no auto-update for personal use).

---

## 2. imdinu/apple-mail-mcp — *the Mail target*

| | |
|---|---|
| **URL** | https://github.com/imdinu/apple-mail-mcp |
| **Author** | Ioan-Mihail Dinu (imdinu) |
| **License** | **GPL-3.0-or-later** |
| **Last commit** | 2026-04-13 |
| **Activity (90d)** | 31 commits — very active solo maintainer, tagged through v0.2.2 on PyPI |
| **Review** | [`reviews/apple-mail-mcp.md`](reviews/apple-mail-mcp.md) |

**Role:** the gold standard for Mail. Disk-first `.emlx` parsing + FTS5 cache + state-reconciliation sync, benchmarked against six competitors. Apple Core's v2.0 Mail surface is a Python→Swift translation of this design.

**Patterns/code lifted:**

- **Disk-first single-email read strategy cascade.** Strategy 0: parse `.emlx` directly from disk in 1-5 ms. Strategy 1: JXA-by-mailbox. Strategy 2: index-assisted JXA. Strategy 3: iterate-all-mailboxes.
- **State-reconciliation sync.** Two cheap walks keyed on `(account, mailbox, msg_id)` produce NEW/DELETED/MOVED diffs deterministically — simpler than diffing AppleScript snapshots.
- **FTS5 external-content table with sync triggers.** `emails_fts` shares storage with `emails`, triggers keep them aligned.
- **`MailCore` JXA facade with batch property fetching** — single-IPC-round-trip property fetch, the canonical fix for AppleScript Mail's 87× iteration slowdown.
- **Benchmark harness pattern** for validating performance claims against competitors.

**License posture:** GPL-3.0-or-later matches Apple Core's chosen license (queued relicense). No clean-room discipline needed — we translate the Python implementation function-by-function into Swift, attributing per file via preserved GPL headers and a top-level `NOTICE`.

---

## 3. FradSer/mcp-server-apple-events — *the EventKit reference*

| | |
|---|---|
| **URL** | https://github.com/FradSer/mcp-server-apple-events |
| **Author** | Frad LEE (fradser) |
| **License** | MIT (Copyright 2025 Frad LEE) |
| **Last commit** | 2026-04-23 |
| **Activity (90d)** | 51 commits — very active, tagged v1.4.0 |
| **Review** | [`reviews/mcp-server-apple-events.md`](reviews/mcp-server-apple-events.md) |

**Role:** deepest EventKit (Reminders + Calendar) coverage in the field. Donor for the action-dispatcher tool shape and the hardened-runtime + embedded Info.plist Swift sidecar pattern.

**Patterns/code lifted:**

- **Verb-dispatcher tool shape.** `reminders_tasks(action: read|create|update|delete, ...)` keeps tool count compact while exposing full CRUD. Same for `calendar_events`.
- **Recurrence/alarm/structured-location coverage.** Full RRULE expansion (FradSer extends to hourly/minutely beyond EventKit's native frequencies via raw RRULE strings), geofenced alarms via `EKAlarm.structuredLocation`, alarm types (relative/absolute/location), span semantics (`this-event`/`future-events`).
- **AppleScript fallback for cross-source reminder moves** (EventKit returns -3002 across iCloud↔local). Single isolated fallback, named function, dedicated error message for Automation-TCC denial.
- **Hardened-runtime ad-hoc-signed Swift sidecar pattern** (`-Xlinker -sectcreate __TEXT __info_plist`). Documented in BUILD_PLAN §6.3 for if we ever go back to a sidecar shape; for now we embed Info.plist in the .app bundle normally.
- **JSON envelope contract** (`{status: success|error, result|message}`) and typed permission-error classification. Useful pattern even though our IPC is XPC, not stdout JSON.
- **Binary path validation** allowlist for spawning sidecars.

---

## 4. adamzaidi/icloud-mcp — *the iCloud network-protocol donor*

| | |
|---|---|
| **URL** | https://github.com/adamzaidi/icloud-mcp |
| **Author** | Adam Zaidi |
| **License** | MIT (declared in package.json + README; LICENSE file pending in repo root) |
| **Last commit** | 2026-04-02 |
| **Activity (90d)** | 45 commits — very active, v2.6.0 |
| **Review** | [`reviews/icloud-mcp-adamzaidi.md`](reviews/icloud-mcp-adamzaidi.md) |

**Role:** the donor for headless iCloud-server paths (IMAP, SMTP, CardDAV, CalDAV) plus several high-value operational patterns. Apple Core's v2.0 IMAP/SMTP send and v2.1 headless CalDAV/CardDAV builds on this work.

**Patterns/code lifted:**

- **Three-phase safe move for Mail bulk operations**: copy → fingerprint-verify → single EXPUNGE on source, with a persistent JSON manifest for resume/abandon. Powered by `mail_get_move_status` and `mail_abandon_move` MCP tools in our v2.0 inventory.
- **`--doctor` self-test pattern.** Walks env vars → TCP+TLS → IMAP greeting → AUTH → INBOX open with green-check plain-English output. We expose this both as a menu item in the .app and as a `server_doctor` MCP tool.
- **Connect-rate-limiting gate** for iCloud throttle. Single global `_connectGate` actor serializing connection initiations 10 ms apart while letting in-flight sessions run concurrently.
- **JXA Reminders fallback** when CalDAV VTODO is broken on iCloud (which it is — Apple's CalDAV server returns malformed VTODO). Documented design rationale for why headless mode degrades to JXA for Reminders specifically.
- **Saved-rules engine** with `dryRun` semantics — `create_rule` / `run_rule` / `run_all_rules`. v1.2 surface.
- **Session journal** (`log_write` / `log_read` / `log_clear`) so the model can resume multi-step bulk runs after a context reset.

---

## 5. Dhravya/apple-mcp — *the broad-surface checklist*

| | |
|---|---|
| **URL** | https://github.com/Dhravya/apple-mcp |
| **Author** | Dhravya Shah (dhravya@supermemory.com) |
| **License** | MIT (Copyright 2025 Dhravya Shah) |
| **Last commit** | 2025-08-10 |
| **Activity (90d)** | 0 commits — dormant since August 2025 |
| **Review** | [`reviews/apple-mcp-dhravya.md`](reviews/apple-mcp-dhravya.md) |

**Role:** the original of the two `apple-mcp` repos (see also #6). Broadest consumer-app coverage in the field — 7 polymorphic tools spanning Contacts, Notes, Messages, Mail, Reminders, Calendar, Maps. Useful as a feature-checklist and as a source of specific AppleScript snippets.

**Patterns/code lifted:**

- **Operation-multiplexed tool shape.** Each surface exposes a single tool with an `operation` enum (`messages.send | read | schedule | unread`). Keeps the LLM-facing tool list compact for surfaces with rich verb sets.
- **Lazy module loading with eager-loading fallback.** Watchdog timer flips to "safe mode" if a surface's startup hangs >5 seconds.
- **Per-surface `checkAccess` / `requestAccess` preflight** returning paragraph-long human-readable error strings ("Open System Settings > Privacy & Security > Automation, enable …").
- **Hybrid SQLite-read + AppleScript-send for Messages.** Read via chat.db (fast), write via AppleScript (the only safe path).
- **Phone-number normalization helper** producing format candidates (`+1XXXXXXXXXX`, `1XXX...`, `XXX...`) for fuzzy iMessage buddy matching.

---

## 6. supermemoryai/apple-mcp — *same project, supermemory org*

| | |
|---|---|
| **URL** | https://github.com/supermemoryai/apple-mcp |
| **Author** | Dhravya Shah (republished under the supermemoryai org because Dhravya works at Supermemory) |
| **License** | MIT (Copyright 2025 Dhravya Shah) |
| **Last commit** | 2025-08-10 |
| **Activity (90d)** | 0 commits — dormant |
| **Review** | [`reviews/apple-mcp-supermemoryai.md`](reviews/apple-mcp-supermemoryai.md) |

**Role:** **same project as #5.** Listed separately for completeness; do not double-count when computing the donor lift list. The `package.json` `repository` field on this copy still points at `Dhravya/apple-mcp`. The Supermemory copy has the Aug 2025 "total revamp with tests" commit and the prebuilt 27 MB `.dxt` artifact, otherwise identical.

**What's worth knowing here that isn't in #5:**

- **DXT artifact pattern.** The supermemory copy includes a Claude-Desktop one-click `.dxt` bundle. Reference for if Apple Core ever ships broadly. We won't commit the artifact itself to git (as supermemory did — bloating their clones with 27 MB); we'd build it in CI.

---

## 7. MrGo2/icloud-mcp — *the AppleScript-vs-network-protocol split reference*

| | |
|---|---|
| **URL** | https://github.com/MrGo2/icloud-mcp |
| **Author** | Carlos Lorenzo (MrGo2) |
| **License** | MIT (declared in package.json + README; LICENSE file pending in repo root) |
| **Last commit** | 2026-01-13 |
| **Activity (90d)** | 0 commits — dormant (v2.0.0 then quiet) |
| **Review** | [`reviews/icloud-mcp-mrgo2.md`](reviews/icloud-mcp-mrgo2.md) |

**Role:** despite the name, this is not an iCloud-Drive/Photos/Find-My MCP — it's a dual-mode AppleScript-vs-iCloud-protocol server for Mail/Calendar/Contacts/Reminders/Notes/Messages/Safari. Useful as a reference architecture for the local-vs-remote split per surface, less useful as a runtime (dormant, no tests, no CI, plain-text credentials).

**Patterns/code lifted:**

- **Per-surface `local-client.js` vs `protocol-client.js` folder split.** The shape generalizes: each surface module dispatches between an AppleScript path (when Apple's app is configured locally) and a network-protocol path (when running headless or against a non-default account). Apple Core mirrors this for Calendar (EventKit local + CalDAV remote) and Contacts (Contacts.framework local + CardDAV remote).
- **`utils/applescript.js` shape — small and reusable.** `runAppleScript` / `runJXA` / `runJXAWithJSON` / `escapeAppleScript` / `escapeJXA` / typed `AppleScriptError` mapping known stderr substrings to `PERMISSION_DENIED` / `APP_NOT_RUNNING` / `NOT_FOUND` codes. Apple Core's `AppleScriptRunner` actor (BUILD_PLAN §3.5) is the Swift translation.
- **Stdin-based `osascript` invocation** rather than `osascript -e` — handles multi-line scripts, avoids argv length limits.
- **`tsdav` + `ical.js` choice** for CalDAV/CardDAV instead of hand-rolling XML. We'll use the equivalent on the Swift side (likely SwiftNIO HTTP/2 + libical via wrapper).

**Patterns we deliberately drop:**

- Plain-text app-specific passwords in `.env` → Apple Core uses macOS Keychain.
- Hand-rolled JSON-RPC framing → use `swift-sdk` (already a dep via iMCP fork).
- Hardcoded Spanish-locale defaults (Europe/Madrid timezone, es-ES dates).
- Naive HTML-by-string-concatenation in Notes create.

---

## Summary table

| Donor | License | v0/v1 status | Lifted patterns count |
|---|---|---|---|
| mattt/iMCP | MIT | Hard-fork base | ~10 (architecture-level) |
| imdinu/apple-mail-mcp | GPL-3.0-or-later | v2.0 Mail target | 5 (will translate) |
| FradSer/mcp-server-apple-events | MIT | EventKit reference | 6 |
| adamzaidi/icloud-mcp | MIT | iCloud-network donor | 6 |
| Dhravya/apple-mcp | MIT | Broad-surface checklist | 5 |
| supermemoryai/apple-mcp | MIT | (same as Dhravya) | 0 net new |
| MrGo2/icloud-mcp | MIT | AppleScript runner reference | 4 |

For per-surface specifics (which donor's pattern applies to which Apple Core surface, with effort/risk estimates), see [`BUILD_PLAN.md` §3](BUILD_PLAN.md). For the per-repo deep-read review notes that drove these decisions, see [`reviews/`](reviews/).
