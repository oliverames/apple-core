# Apple MCP Synthesis — Design Doc

**Date:** 2026-04-30
**Status:** Review and design complete. No implementation yet.
**Inputs:** Per-repo reports under `reviews/`, clones under `repos/`.

This document compares seven Apple-related MCP server projects and proposes a recommended architecture, tool inventory, and lift list for a combined MCP we will build separately.

---

## 1. Project roster

| Short name | URL | License | Stack | Last commit | 90d commits | Status |
|---|---|---|---|---|---|---|
| **iMCP** | mattt/iMCP | MIT | Swift app + CLI | 2026-01-30 | 4 | Lightly active, polished |
| **apple-events** | FradSer/mcp-server-apple-events | MIT | TS + Swift sidecar | 2026-04-23 | 51 | Very active |
| **icloud-mcp-mrgo2** | MrGo2/icloud-mcp | MIT (no LICENSE file) | Node CJS | 2026-01-13 | 0 | Dormant |
| **icloud-mcp-adamzaidi** | adamzaidi/icloud-mcp | MIT (no LICENSE file) | Node ESM | 2026-04-02 | 45 | Very active |
| **apple-mcp-supermemoryai** | supermemoryai/apple-mcp | MIT | Bun/TS | 2025-08-10 | 0 | Dormant |
| **apple-mcp-dhravya** | Dhravya/apple-mcp | MIT | Bun/TS | 2025-08-10 | 0 | Dormant |
| **apple-mail-mcp** | imdinu/apple-mail-mcp | **GPL-3.0-or-later** | Python | 2026-04-13 | 31 | Very active |

### Important corrections to the input list

- **`Dhravya/apple-mcp` and `supermemoryai/apple-mcp` are the same project**, republished under the supermemory org because Dhravya works there. Same code, same author, same package.json. Treat them as one entry; prefer the supermemoryai URL because it has the Aug 2025 revamp and the .dxt artifact.
- **`MrGo2/icloud-mcp` does not actually touch iCloud Drive, Photos, Find My, or CloudKit.** It is a dual-mode AppleScript-vs-iCloud-protocol server for Mail/Calendar/Contacts/Reminders/Notes/Messages/Safari. The repo name is misleading.
- **`apple-mail-mcp` is GPL-3.0-or-later.** This is the single biggest license blocker in the set. We can study its architecture but cannot vendor any of its code into an MIT/Apache-2.0 combined project.

---

## 2. Surface coverage matrix

Legend: ● = full coverage, ◐ = partial / read-only / send-only, ○ = not covered. Mechanism in parentheses.

| Surface | iMCP | apple-events | mrgo2 | adamzaidi | dhravya/super | apple-mail |
|---|---|---|---|---|---|---|
| **Mail (read+search)** | ○ | ○ | ◐ AS+IMAP | ● IMAP | ◐ AS | ● disk+FTS5+JXA |
| **Mail (send/draft/bulk)** | ○ | ○ | ◐ AS+SMTP | ● SMTP+IMAP | ◐ AS | ○ |
| **Calendar** | ● EventKit | ● EventKit | ● AS+CalDAV | ● CalDAV | ● AS | ○ |
| **Reminders** | ● EventKit | ● EventKit (richest) | ● AS | ● JXA | ● AS | ○ |
| **Contacts** | ● Contacts.fw | ○ | ● AS+CardDAV | ● CardDAV | ◐ AS read | ○ |
| **Notes** | ○ | ○ | ◐ AS create+read | ○ | ◐ AS create+search | ○ |
| **Messages (read)** | ● chat.db+madrid | ○ | ○ | ○ | ◐ chat.db+sqlite3 | ○ |
| **Messages (send)** | ○ | ○ | ◐ AS | ○ | ◐ AS | ○ |
| **Maps** | ● MapKit | ○ | ○ | ○ | ● JXA | ○ |
| **Weather** | ● WeatherKit | ○ | ○ | ○ | ○ | ○ |
| **Location** | ● Core Location | ○ | ○ | ○ | ○ | ○ |
| **Capture (cam/audio/screen)** | ● AVF/SCK | ○ | ○ | ○ | ○ | ○ |
| **Shortcuts** | ● shortcuts CLI | ○ | ○ | ○ | ○ | ○ |
| **Safari (tabs/URL)** | ○ | ○ | ● AS | ○ | ◐ scrape | ○ |
| **iCloud Drive** | ○ | ○ | ○ | ○ | ○ | ○ |
| **iCloud Photos** | ○ | ○ | ○ | ○ | ○ | ○ |
| **Find My** | ○ | ○ | ○ | ○ | ○ | ○ |
| **Health** | ○ | ○ | ○ | ○ | ○ | ○ |

### Union of covered surfaces

Mail, Calendar, Reminders, Contacts, Notes, Messages, Maps, Weather, Location, Capture, Shortcuts, Safari (tabs only).

### Gaps in the union (no project covers any of these)

- **iCloud Drive** — would require CloudKit Web Services or running inside an entitled container; no candidate attempts it.
- **iCloud Photos / Photos library** — would use the Photos.framework (`PHPhotoLibrary`). Worth adding.
- **Find My / Devices** — no public API; effectively impossible without a private endpoint reverse-engineering pact we shouldn't make.
- **Health** — HealthKit is iOS/watchOS only, not macOS, so the gap is structural.
- **Notes editing** — every project that supports Notes is create-only or create+search; updating an existing note is missing.
- **Safari history / bookmarks / reading list** — only tab-state has any coverage (mrgo2).

### Surface depth by project

- **iMCP**: widest macOS-system coverage (Maps, Weather, Location, Capture, Shortcuts) but no Mail and no Notes.
- **apple-events**: deepest Reminders/Calendar coverage of any project (subtasks via notes-encoding, geofenced alarms, full recurrence, tags). Two surfaces, but each one is comprehensive.
- **icloud-mcp-adamzaidi**: deepest Mail coverage (~70 tools including bulk move/delete, saved rules, three-phase safe move) over native protocols (IMAP/SMTP/CardDAV/CalDAV). Reminders via JXA because iCloud's CalDAV VTODO is broken.
- **apple-mail-mcp**: only Mail, but the most technically polished Mail of the set — disk-first `.emlx` parse, FTS5 cache, state-reconciliation sync, batch JXA fetches. Benchmarks against six competitors.
- **dhravya/supermemoryai**: broad but shallow; seven polymorphic tools spanning the consumer apps, mostly AppleScript.
- **mrgo2**: useful as a reference for the AppleScript-vs-network-protocol split per surface; not useful as a runtime.

---

## 3. Mechanism inventory — what talks to Apple, how

This is the table that drives the architecture decision. Mechanisms range from "rock solid Apple-blessed APIs" to "fragile shell-out scraping".

| Mechanism | Used by | Pros | Cons |
|---|---|---|---|
| **EventKit** (Swift native) | iMCP, apple-events | First-class API, fast, stable across macOS versions | Cross-source moves return -3002, requires Swift toolchain |
| **Contacts.framework** (Swift native) | iMCP | First-class, fast | Swift-only |
| **Core Location / MapKit / WeatherKit** | iMCP | First-class | Swift-only, WeatherKit needs entitlement |
| **AVCaptureSession / ScreenCaptureKit** | iMCP | First-class | Heavy TCC: camera, mic, screen recording |
| **AppleScript via osascript** | mrgo2, dhravya/super, apple-events (fallback) | Universal, no toolchain | Slow, fragile, brittle escaping, Automation TCC re-prompts |
| **JXA via osascript -l JavaScript** | mrgo2, dhravya/super, adamzaidi (Reminders), apple-mail | JSON-friendly object model | Same TCC and shell-out costs as AppleScript |
| **chat.db SQLite read** | iMCP (with bookmark), dhravya/super (raw) | 10-100× faster than AppleScript Messages | Needs Full Disk Access; typedstream decoding for body |
| **`.emlx` disk parse + FTS5** | apple-mail (only) | <5ms per email; survives where AppleScript Mail dies | FDA required; format change risk |
| **Mail Envelope Index sqlite** | apple-mail | Metadata cheap | FDA; undocumented schema |
| **IMAP/SMTP** | mrgo2, adamzaidi | Cross-platform, no TCC | App-specific password required; iCloud throttling |
| **CalDAV/CardDAV via tsdav** | mrgo2, adamzaidi | Cross-platform, no TCC | iCloud VTODO is broken; partition-host pinning |
| **Shortcuts CLI shell-out** | iMCP | Lets users extend without code | No structured I/O, no input validation |
| **Bonjour-discovered TCP between CLI and app** | iMCP (only) | Keeps stdio at client boundary while sandboxed app holds TCC | Finicky; iMCP's own commit log shows continuation/QoS hangs being patched |
| **Hardened-runtime ad-hoc-signed Swift sidecar** | apple-events (only) | Solves macOS 26+ "TCC prompts under GUI parent" problem cleanly | Requires Xcode CLT on user machine for npm install |

Five distinct architectural approaches across the seven projects:

1. **Sandboxed signed app + stdio CLI proxy via Bonjour** (iMCP) — most polished, hardest to build.
2. **TS server + signed Swift sidecar** (apple-events) — best TCC story for a non-app server.
3. **Network-only over IMAP/CalDAV/CardDAV** (adamzaidi for everything except Reminders) — easiest to ship, lowest TCC surface, weakest credential hygiene.
4. **Pure AppleScript/JXA over osascript** (dhravya/super, mrgo2 local mode) — quickest to write, most fragile.
5. **Disk-first index + selective JXA** (apple-mail) — fastest for Mail; complex; GPL-blocked.

---

## 4. Activity, license, and trust signals

```
Active maintenance now (2026 Q2):       apple-events, adamzaidi, apple-mail
Lightly active polished:                 iMCP
Dormant since Jan 2026:                  mrgo2
Dormant since Aug 2025:                  dhravya/supermemoryai
```

License-compatible to vendor into MIT or Apache-2.0:
- iMCP, apple-events, mrgo2, adamzaidi, dhravya/supermemoryai (5 projects, MIT)
- **apple-mail-mcp is GPL-3.0-or-later — DO NOT vendor.** Reimplement under our license.

Both icloud-mcp repos declare MIT in metadata but ship no LICENSE file in the repo root. We should consider that a yellow flag — if we lift code we should ask the authors to add a real LICENSE file, or treat the metadata claim as authoritative and document our reliance.

---

## 5. Recommended stack for our combined MCP

**Decision: hybrid — TypeScript MCP frontend with per-surface Swift sidecars for TCC-protected work, network protocols for iCloud-server paths, and direct SQLite reads where they win.**

This is the architecture FradSer's `mcp-server-apple-events` is converging on, generalized across more surfaces. It is *not* the iMCP architecture (sandboxed app + Bonjour) — we deliberately drop that complexity.

### 5.1. Why hybrid, not pure-Swift app

**Pro pure-Swift-app (iMCP-style):**
- Cleanest TCC: a long-lived signed sandboxed .app holds Calendar/Contacts/Messages access once and reuses it.
- Apple-blessed: signed/notarized, passes Gatekeeper, App Store viable.
- Native frameworks are stable across macOS versions in a way AppleScript is not.

**Con pure-Swift-app:**
- Bonjour CLI ↔ app proxy is genuinely fragile — iMCP's own recent commits (`c9daec8`, `e00864f`) patched continuation/QoS hangs in the proxy itself.
- Swift bar for contributors is higher than TS for an open-source project we want others to extend.
- The .app is overkill for headless or remote use cases.
- macOS-only; no cross-platform headless story.

**Pro hybrid:**
- TypeScript frontend is easy to extend per surface, easy to test with mocks, easy to ship via npm + DXT.
- Swift sidecars solve the macOS 26+ "TCC prompts must come from a hardened-runtime process" problem (apple-events proves this works).
- Per-surface optimization possible: FTS5 indexer for Mail, EventKit binary for Calendar/Reminders, raw SQLite for chat.db, JXA for the long tail.
- Network paths (IMAP/CalDAV/CardDAV) give us a headless iCloud-server option that doesn't require macOS at all.
- Each sidecar can ship with its own minimal entitlements file rather than an app-wide blob.

**Con hybrid:**
- Two languages to maintain (TS + Swift), plus shell-outs to JXA for the long tail.
- npm postinstall has to build Swift sidecars, which means Xcode CLT is a hard install dependency on macOS.
- Need a clean spawn-and-JSON-envelope contract between TS and each Swift binary (FradSer's `cliExecutor.ts` is the donor here).

The hybrid wins because the cons are tractable and the pros land in places our users actually feel — extensibility, performance, and resilience to macOS updates.

### 5.2. The transport question

stdio at the client boundary, full stop. All seven candidates use stdio; that's also where the Claude Desktop / Claude Code ecosystem expects MCPs to live. Skip Bonjour. If we ever need HTTP/SSE for remote use, add it as a second `Server` instance later — `@modelcontextprotocol/sdk` supports both.

### 5.3. The credential question

**macOS Keychain via Security framework, not env vars or `.env` files.**

Every iCloud-touching project in this set stores app-specific passwords in plain text — `.env` (mrgo2), `claude_desktop_config.json` (adamzaidi), or both. That's a regression from any 2010s-era native macOS app. Our combined server should:

- On first run, prompt for the iCloud app-specific password and store it in Keychain under our service identifier via `security add-generic-password` or a native binding.
- Read it back with `security find-generic-password -w`.
- Fall back to env vars only when explicitly opted in (CI / headless) and document the reduced security posture.
- Provide a `server_doctor` tool (lift adamzaidi's `--doctor` pattern) that shows where credentials are coming from and verifies they work.

---

## 6. What to lift, with attribution

For each item we lift, the source project's MIT license requires us to preserve the upstream copyright notice in the file or in NOTICES.md. apple-mail-mcp items must be **reimplemented clean-room**, not lifted, because of GPL.

### From iMCP (mattt) — MIT

- **`MessageService` security-scoped bookmark for `chat.db`.** `NSOpenPanel` → security-scoped bookmark stored in `UserDefaults` → `withSecurityScopedAccess` helper. The canonical pattern for sandboxed `chat.db` access.
- **Per-client approval gate** (`ConnectionApprovalView` + `@AppStorage("trustedClients")`). If we add a UI surface, this is the trust model.
- **JSON-LD / Schema.org outputs via `Ontology`.** Tool results typed as `Person`, `Conversation`, `Event` rather than ad-hoc dicts. Self-documenting to the model.
- **`Tool.Annotations` set on every tool** (`readOnlyHint`, `destructiveHint`, `openWorldHint`). MCP feature most projects ignore.
- **Maps tool shape** — search, directions, ETA, static map PNG generation via `MKMapSnapshotter`. Lift directly.

### From mcp-server-apple-events (FradSer) — MIT

- **Hardened-runtime ad-hoc-signed Swift sidecar pattern.** `swiftc -framework EventKit -Xlinker -sectcreate __TEXT __info_plist Info.plist; codesign --force --sign - --options runtime --entitlements ...entitlements`. This is the cleanest pattern for a CLI sidecar that needs TCC dialogs to fire under a GUI parent process on macOS 26+.
- **Strict JSON envelope contract** between TS and Swift: `{status:"success", result}|{status:"error", message}`. Permission errors classified by regex against the Swift message and surfaced as a typed `CliPermissionError` with `'reminders' | 'calendars'` domain tag.
- **Binary path validation** (`binaryValidator.ts`) — allowlist of paths the TS layer is willing to spawn, defending against substitution attacks.
- **`execFile`-not-`exec`** for spawning the sidecar, with the shell-injection reasoning documented in the source.
- **EventKit tool shape** — verb-dispatcher pattern (`reminders_tasks` action: read|create|update|delete) keeps the tool count low while still exposing full CRUD.

### From icloud-mcp-adamzaidi — MIT

- **`--doctor` self-test command.** Walks env vars → TCP+TLS → IMAP greeting → AUTH → INBOX open with green-check plain-English output. We expose this as a `server_doctor` tool.
- **Three-phase safe move for Mail:** copy → fingerprint-verify → single EXPUNGE, with a persistent manifest at `~/Library/Application Support/our-mcp/move-manifest.json` and `get_move_status` / `abandon_move` recovery. Crucial for any bulk-mail tool we ship.
- **Connect-rate-limiting gate for iCloud throttle.** Single global `_connectGate` promise serializing connection initiations 10ms apart while letting in-flight sessions run concurrently.
- **JXA Reminders fallback when CalDAV VTODO is broken on iCloud.** Document the reason in the code so a future maintainer knows why.
- **Saved-rules engine** with `dryRun` semantics — `create_rule` / `run_rule` / `run_all_rules`. Higher-level pattern but useful for power users.
- **Session journal** (`log_write` / `log_read` / `log_clear`) so the model can resume multi-step bulk runs after a context reset.

### From icloud-mcp-mrgo2 — MIT

- **`utils/applescript.js` shape.** Small, reusable: `runAppleScript`, `runJXA`, `runJXAWithJSON`, `escapeAppleScript`, `escapeJXA`, typed `AppleScriptError` with `PERMISSION_DENIED` / `APP_NOT_RUNNING` / `NOT_FOUND` codes mapped from stderr substrings.
- **Stdin-based `osascript` invocation** (rather than `osascript -e`) — cleanly handles multi-line scripts and avoids argv length limits.
- **Per-surface `local-client.js` vs `protocol-client.js` folder split.** Mental model holds up across the codebase.
- **`tsdav` + `ical.js`** for CalDAV/CardDAV instead of hand-rolling XML, with cached `DAVClient` per process.

### From apple-mcp-supermemoryai / apple-mcp-dhravya — MIT

- **Eager-load with timeout fallback to lazy "safe mode".** If startup hangs >5s, flip to per-call dynamic imports. Graceful degradation when one Apple framework misbehaves.
- **Per-surface `checkAccess` / `requestAccess` preflight** that returns paragraph-long human-actionable error strings ("Open System Settings > Privacy & Security > Automation, enable …"). Far friendlier than raw osascript exit codes.
- **Hybrid SQLite read + AppleScript send for Messages.** Reading via chat.db is dramatically faster than scripting Messages.app; writing via AppleScript avoids touching the write-locked DB. Sensible split.
- **DXT artifact.** Build a `.dxt` for Claude Desktop one-click install. (As a release asset, **not** committed to the repo — they made the mistake of committing a 27 MB binary to git, we won't.)
- **Phone-number normalization** (`utils/message.ts`) producing format candidates (`+1XXXXXXXXXX`, `1XXX...`, `XXX...`) for fuzzy iMessage buddy matching.

### From apple-mail-mcp (imdinu) — GPL-3.0 — REIMPLEMENT, do not vendor

These are patterns to clean-room reimplement under our license. Studying the public README, CLAUDE.md, and benchmark write-ups is fine; copying source is not.

- **Disk-first `.emlx` parse strategy cascade.** Strategy 0: parse `.emlx` directly. Strategy 1: JXA-by-mailbox. Strategy 2: index-assisted JXA. Strategy 3: iterate-all-mailboxes. Fall through on miss.
- **State-reconciliation sync.** Two cheap walks keyed on `(account, mailbox, msg_id)` produce add/delete/move diffs deterministically — simpler and more correct than diffing AppleScript snapshots.
- **FTS5 external-content table with sync triggers.** `emails_fts` shares storage with `emails`, triggers keep them aligned, FTS5 special characters escaped via regex; highlighting and pagination first-class.
- **`MailCore` JXA facade with batch property fetching.** One shared JS object fetches property arrays in a single IPC round-trip — the canonical fix for AppleScript iteration slowness (87× per their CLAUDE.md).
- **Benchmark harness pattern.** A JSON-RPC stdio MCP client that runs the same query against multiple competitors and emits Plotly charts. Reimplement in our test suite to validate any combined server's performance claims as we add surfaces.

---

## 7. What to leave out, with reasoning

- **Hand-rolled JSON-RPC framing** (mrgo2). Use `@modelcontextprotocol/sdk`. There is zero upside to cloning the framing layer — it's a defect surface.
- **Plain-text app-specific passwords in `.env` or `claude_desktop_config.json`** (mrgo2, adamzaidi). Replace with macOS Keychain.
- **27 MB DXT committed to main** (dhravya/supermemoryai). Build it in CI, ship as a release asset.
- **Web search via Safari DOM scrape** (dhravya/supermemoryai). ToS-adjacent, brittle, and out of scope for an Apple-services MCP. If the user wants web search they should use a web-search MCP.
- **Bonjour CLI ↔ app proxy** (iMCP). Over-engineered for our case. The gain (sandboxed long-lived app) is real, but the cost (continuation/QoS hangs, 30s discovery timeout, harder to install for non-developers) outweighs it for a hybrid TS/Swift design.
- **Hand-rolled AppleScript escaping** (every TS-based project). Build all AppleScripts via parameterized templates that pass arguments via stdin or environment variables, not string concatenation.
- **Subtasks encoded inside the notes field with `---SUBTASKS---` markers** (apple-events). Clever, but corrupts if any other writer touches the note. Use EventKit's actual subtask API where it exists; if it doesn't on a given macOS version, persist subtask metadata to our own SQLite, not the user's note body.
- **All seven projects' "no CI" posture.** Stand up GitHub Actions from day one with at least lint + unit tests; integration tests gated behind a `RUN_INTEGRATION_TESTS=1` env var that pulls credentials from a CI secret.

---

## 8. Proposed tool inventory for our combined MCP

Tool names use `surface_verb` snake_case to match adamzaidi's convention (which is closest to MCP-canonical). Tools that touch destructive operations carry the `destructiveHint` annotation per MCP spec.

### Calendar (EventKit Swift sidecar)

- `calendar_list_calendars`
- `calendar_list_events` — filters: `range`, `calendar_id`, `query`, `account`, `limit`
- `calendar_get_event`
- `calendar_create_event` — supports recurrence (RFC 5545 RRULE), alarms (relative/absolute/location), structured location, all-day, availability, span (`this-event`/`future-events`)
- `calendar_update_event` — same shape as create + `event_id`
- `calendar_delete_event`

### Reminders (EventKit Swift sidecar + JXA fallback for cross-source moves)

- `reminders_list_lists`
- `reminders_list` — filters: `list_id`, `completed`, `due_before`, `due_after`, `tag`
- `reminders_get`
- `reminders_create` — supports priority, alarms, recurrence, due date, completion date, subtasks
- `reminders_update`
- `reminders_complete`
- `reminders_delete`
- `reminders_move_to_list` — uses JXA fallback for cross-source per FradSer

### Contacts (Contacts.framework Swift sidecar)

- `contacts_search`
- `contacts_get`
- `contacts_create`
- `contacts_update`
- `contacts_delete` (destructive)
- `contacts_me` — returns the user's own card

### Mail (Swift indexer for read/search + IMAP/SMTP for write)

- `mail_list_accounts`
- `mail_list_mailboxes`
- `mail_search` — scopes: `all`, `subject`, `sender`, `body`, `attachments`; `before`, `after`, `highlight`, `limit`, `offset`. FTS5-backed.
- `mail_get_email`
- `mail_get_email_links`
- `mail_get_attachment`
- `mail_count_emails` — by sender / mailbox / range
- `mail_get_top_senders`
- `mail_compose`
- `mail_reply`
- `mail_forward`
- `mail_save_draft`
- `mail_flag` / `mail_mark_read` / `mail_move` (single-message)
- `mail_delete` (destructive)
- `mail_bulk_move` / `mail_bulk_delete` / `mail_bulk_mark_read` (destructive; uses three-phase safe-move)
- `mail_get_move_status` / `mail_abandon_move`
- Mailbox mgmt: `mail_create_mailbox`, `mail_rename_mailbox`, `mail_delete_mailbox`

### Notes (AppleScript / JXA — no native Notes API)

- `notes_list_folders`
- `notes_list`
- `notes_search`
- `notes_get`
- `notes_create`
- `notes_update` — net-new, missing in all candidates

### Messages (chat.db read + AppleScript send)

- `messages_search` — chat.db FTS-over-typedstream
- `messages_get_thread`
- `messages_send` — phone-number normalization per dhravya
- `messages_unread_count`
- `messages_recent_chats`

### Maps (MapKit Swift sidecar)

- `maps_search`
- `maps_directions`
- `maps_eta`
- `maps_explore`
- `maps_static_image` — PNG render via `MKMapSnapshotter`

### Location & Weather (Swift sidecar)

- `location_current`
- `location_geocode`
- `weather_current`
- `weather_daily`
- `weather_hourly`

### Capture (optional, behind feature flag — high TCC cost)

- `capture_screenshot`
- `capture_take_picture`
- `capture_record_audio`

### Shortcuts

- `shortcuts_list`
- `shortcuts_run` — destructive, validate name against the list

### Server admin

- `server_doctor` — adamzaidi's pattern, generalized to all configured surfaces
- `server_check_permissions` — show TCC state per surface
- `server_status`

Approximate total: ~60 tools, but 25-30 of those are operation-multiplexed via discriminated `operation` enums (per dhravya/super) so the LLM-facing tool count stays manageable.

---

## 9. Architecture sketch

```
                  ┌─────────────────────────────────────────┐
                  │           MCP Client                    │
                  │  (Claude Desktop / Claude Code / Cursor)│
                  └────────────────────┬────────────────────┘
                                       │ stdio / JSON-RPC
                  ┌────────────────────▼────────────────────┐
                  │  apple-mcp (TypeScript, Node ESM)       │
                  │  • @modelcontextprotocol/sdk            │
                  │  • Per-surface tool registrations       │
                  │  • cliExecutor (JSON envelope contract) │
                  │  • Keychain credential helper           │
                  │  • Doctor / status admin tools          │
                  │  • Lazy load + safe-mode fallback       │
                  └─────┬─────────────┬─────────────┬───────┘
                        │             │             │
              ┌─────────▼──────┐  ┌───▼──────┐  ┌───▼────────┐
              │ Native sidecars│  │ Network  │  │ AppleScript│
              │ (Swift, ad-hoc │  │ paths    │  │ / JXA      │
              │  signed,       │  │ (no TCC) │  │ (osascript)│
              │  hardened)     │  │          │  │            │
              ├────────────────┤  ├──────────┤  ├────────────┤
              │ EventKitCLI    │  │ IMAP     │  │ Notes      │
              │ ContactsCLI    │  │ SMTP     │  │ Messages   │
              │ MapKitCLI      │  │ CalDAV   │  │   send     │
              │ MessagesReader │  │ CardDAV  │  │ Safari tabs│
              │  (chat.db)     │  │          │  │ Reminders  │
              │ MailIndexer    │  │          │  │   move     │
              │  (.emlx+FTS5)  │  │          │  │   (cross-  │
              │ WeatherCLI     │  │          │  │    source) │
              │ LocationCLI    │  │          │  │            │
              │ CaptureCLI     │  │          │  │            │
              │ ShortcutsCLI   │  │          │  │            │
              └────────────────┘  └──────────┘  └────────────┘
                       │
              ┌────────▼─────────────────┐
              │ macOS Keychain           │
              │ (app-specific pwd,       │
              │  per-account, per-       │
              │  service)                │
              └──────────────────────────┘
```

### Build pipeline

1. `npm install` runs `postinstall.mjs`.
2. `postinstall` checks for Xcode CLT (`xcode-select -p`). If missing, prints the install command and exits with a clear error.
3. For each Swift sidecar, runs `swiftc -framework <FW> -Xlinker -sectcreate __TEXT __info_plist <plist>` then `codesign --force --sign - --options runtime --entitlements <ents>`.
4. Outputs go to `bin/<sidecar>` and are referenced by `binaryValidator.ts` allowlist.
5. CI builds these on macOS-latest runners, packages into a `.dxt`, and ships as a release asset.

### Distribution

- **npm**: primary install path for developers, `npx @<scope>/apple-mcp@latest` Just Works after Xcode CLT install.
- **DXT**: one-click for Claude Desktop users, built in CI, attached to releases.
- **Homebrew formula**: optional later; a third path that bundles a pre-built sidecar set.

### Testing

- **Unit tests** for everything that doesn't touch the OS — JSON envelope parsing, AppleScript escaping, FTS5 query construction, IMAP throttle-gate, manifest reconciliation. Jest with ts-jest.
- **Integration tests** behind `RUN_INTEGRATION_TESTS=1`. Real iCloud account in CI secrets. apple-mail-mcp's benchmark harness pattern (reimplemented) validates Mail performance claims.
- **CI** from day one: lint (Biome), `tsc --noEmit`, unit tests. Integration tests on a self-hosted macOS runner with per-pull-request gating.

---

## 10. Risks and open questions

1. **macOS 27 AppleScript surface.** Apple has been deprecating Apple Events automation at the edges. Build a kill-switch test that detects when osascript invocation fails wholesale and surfaces a "your macOS version no longer supports Automation, please use the network paths" message. apple-mail's disk-first approach is the long-term hedge for Mail; we'll need similar hedges for Notes (no native API) and Safari.
2. **iCloud throttling.** adamzaidi already serializes connections 10ms apart. Validate this is enough on real accounts; iCloud has been known to ratchet limits without notice.
3. **DXT signing.** Claude Desktop's DXT loader trusts unsigned bundles, but Apple Gatekeeper does not. If we ship a DXT containing unsigned Swift binaries, users on macOS 26+ may hit Gatekeeper friction. Test before relying on the .dxt as the primary path.
4. **Notes update API.** No project supports updating an existing note. AppleScript Notes set-property works but is fragile, and there's no native API. Likely needs JXA + careful error handling, possibly with content-hash check before write to avoid clobbering concurrent edits.
5. **Find My / iCloud Drive / iCloud Photos.** None of the candidates touch these. Adding them is a separate research effort — Find My has no public API at all, iCloud Drive needs file-coordination plus possibly CloudKit Web Services, iCloud Photos needs PhotoKit. Defer to a v0.2 pass.
6. **License-clean Mail implementation.** apple-mail-mcp is the gold standard but GPL. Reimplementing the disk-first cascade and FTS5 schema clean-room is a real effort — probably 2-3 weeks of the build time. Don't underestimate it.

---

## 11. Quick-reference: per-project verdict

- **iMCP**: study the architecture; don't copy the topology. Lift specific patterns (chat.db bookmark, Tool.Annotations, JSON-LD outputs).
- **mcp-server-apple-events**: closest reference to our target architecture. Lift the Swift sidecar build/sign pattern, the JSON envelope, the EventKit tool shape.
- **icloud-mcp-mrgo2**: dormant; harvest `utils/applescript.js` and the dual-client folder split, ignore the runtime.
- **icloud-mcp-adamzaidi**: active and broad; lift the safe-move semantics, the doctor command, the connect-gate, the Reminders JXA fallback. Refactor credential handling before merging.
- **apple-mcp-supermemoryai / apple-mcp-dhravya**: same project, dormant. Use as a feature-checklist and source of specific AppleScript snippets. Adopt lazy-load pattern, preflight error strings, DXT bundling.
- **apple-mail-mcp**: GPL-blocked. The single best Mail implementation. Reimplement clean-room.

---

*End of synthesis. Next step: separate build phase, scoped from this design.*
