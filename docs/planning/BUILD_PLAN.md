# Apple Core — Build Plan (Swift fork of iMCP)

**Date:** 2026-04-30
**Decision recorded:** Fork `mattt/iMCP` as the base. Port the best patterns from the other six repos into Swift. v1 ships as a single GPL-3.0-or-later binary (`apple-core`) for personal use. See §0 for locked decisions.

This plan supersedes `SYNTHESIS.md §5` (which recommended a TS frontend + Swift sidecars). The pivot to Swift-shaped product is motivated by: (1) iMCP already proves the architecture works for the macOS-system-level surfaces; (2) the maintenance burden of a single-language project beats two-language plumbing once Swift is the destination anyway.

---

## 0. Locked decisions

These are immutable inputs to the build, decided 2026-04-30. Future contributors and AI agents pick these up unchanged. If a recommendation elsewhere in this doc contradicts §0, §0 wins.

| # | Decision | Value | One-line rationale |
|---|---|---|---|
| 1 | Project name | **Apple Core** | Reflects the breadth — multi-surface Apple integration; short, unique, easy to say. |
| 2 | Bundle ID | **`com.oliverames.applecore`** | Drives the .app's code-signing identity, the Mach service name (`com.oliverames.applecore.xpc`), the Sparkle appcast URL (if ever wired), the Homebrew cask name (if ever published), and the GitHub repo path (`oliverames/apple-core`). |
| 3 | Sandboxing | **Unsandboxed for v1** | Mac App Store path is off the table. Mail / iCloud Drive / Safari history read FDA-protected paths directly. No sandbox temp-exception entitlement gymnastics; no security-scoped bookmarks needed. |
| 4 | License | **GPL-3.0-or-later** | Same as apple-mail-mcp, dissolving the clean-room discipline. We lift apple-mail-mcp's disk-first `.emlx` + FTS5 + state-reconciliation directly. The other six donors are MIT — one-way compatible into GPL. We keep their LICENSE files in `THIRD_PARTY_LICENSES/` and credit them in `NOTICE`. |
| 5 | Distribution (v1) | **Personal use; GitHub publish optional** | Build with `xcodebuild` (we have an .app target). Drag `Apple Core.app` to `/Applications`. Register the bundled CLI (`Apple Core.app/Contents/MacOS/apple-core`) with MCP clients via stdio. No Mac App Store, no Sparkle, no Homebrew cask in v1. Notarization optional. |
| 6 | Architecture | **.app + CLI proxy via NSXPCConnection (hard-fork iMCP)** | The .app is a long-lived menu bar host that holds TCC permissions under its own signed bundle identity, exposes the Settings UI (surface toggles, account management, doctor), and runs the surface services. The CLI (`apple-core`) is a stdio shim that MCP clients launch; it bridges stdin/stdout to the app over `NSXPCConnection`. Without the .app, TCC prompts attribute to whichever client spawned the CLI (Claude Desktop, Claude Code, etc.) — the original iMCP problem. |

**Downstream consequences worth knowing as you read on:**

- **Hard-fork iMCP** is the build-starting move. iMCP's `Sources/<Surface>Service/` module structure, menu bar app, Settings UI scaffolding, and CLI proxy shape are exactly what we want; we change the IPC wire (Bonjour → NSXPCConnection over a Mach service) and the license (MIT → GPL-3.0-or-later, with iMCP's MIT files keeping their original headers).
- **Per-client approval gate stays.** The .app exposes an XPC listener; multiple MCP clients (Claude Desktop, Claude Code, Cursor) can connect. The first connection from each new client triggers `ConnectionApprovalView`; trust set persists in `@AppStorage("trustedClients")`.
- **Security-scoped bookmark for chat.db is dropped.** That was iMCP's sandbox workaround; we read `~/Library/Messages/chat.db` directly under FDA.
- **Sandbox entitlement XML blocks throughout §3** (mach-register/lookup global-name, file temp-exceptions, App Groups) are documented for completeness but **not needed for v1**. They describe what we would re-add if a future major version re-sandboxes for Mac App Store.
- **Notarization is opt-in for v1.** Without it, users on first run see Gatekeeper friction (right-click → Open). Acceptable for personal use; trivially fixable later if we publish.

---

## 1. Architecture in Swift-native terms

### 1.1 What we keep from iMCP

- **App + CLI split.** Long-lived signed `.app` is the menu bar host that holds TCC permissions under its own bundle identity, exposes the Settings UI, and runs the actual surface services. A small bundled CLI (`apple-core`, lives at `Apple Core.app/Contents/MacOS/apple-core`) is the stdio endpoint that MCP clients (Claude Desktop, Claude Code, Cursor) launch. The CLI proxies bytes between its stdin/stdout and the app over local XPC.
- **Menu bar UI** (`MenuBarExtra`) for surface toggles, account management, troubleshooting/doctor, and the per-client approval gate.
- **All-native Apple frameworks** for the macOS-system surfaces: EventKit (Calendar/Reminders), Contacts.framework (Contacts), Core Location, MapKit, WeatherKit (entitled), AVCaptureSession + ScreenCaptureKit (Capture), the Shortcuts CLI shell-out.
- **Schema.org JSON-LD outputs** via the `Ontology` package — typed result objects (`Person`, `Conversation`, `Event`) instead of ad-hoc dictionaries. Self-documenting to the model.
- **`Tool.Annotations` on every tool** (`readOnlyHint`, `destructiveHint`, `openWorldHint`).
- **Per-client approval gate** (`ConnectionApprovalView` + `@AppStorage("trustedClients")`). With multiple MCP clients potentially connecting (Claude Desktop, Claude Code, Cursor, custom clients), the .app shows an approval alert on first connection from each new client, then remembers the trust set.
- **`madrid` package for typedstream decoding** of Messages bodies.
- **iMCP's `Sources/<Surface>Service/` module structure** — one folder per surface, registered with the MCP server via the actor-isolated tool dispatcher.
- **Loopwork-style swift-format strict + warnings-as-errors** CI gate.

### 1.2 What changes from iMCP

#### IPC: replace Bonjour with NSXPCConnection over a Mach service

**Decision: drop Bonjour. Use `NSXPCConnection` with a Mach service name derived from the bundle ID.**

iMCP uses Bonjour (`_mcp._tcp` on `local.`) so the CLI can discover the running app on the local network. That design optimizes for a case we don't have — there's no scenario where the CLI proxy needs to find Apple Core.app running on a *different* host. Both processes are on the same machine, both ship in the same bundle, both share a build-time-known identifier.

The macOS-blessed primitive for app↔helper IPC on the same machine is `NSXPCConnection`. We register a Mach service from the .app at launch:

```swift
// Inside Apple Core.app
@MainActor
final class XPCListener: NSObject, NSXPCListenerDelegate {
    static let serviceName = "com.oliverames.applecore.xpc"
    let listener = NSXPCListener(machServiceName: serviceName)

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AppleCoreServiceProtocol.self)
        connection.exportedObject = AppleCoreServiceImpl.shared
        connection.resume()
        return true
    }
}
```

The CLI connects with no discovery step:

```swift
// Inside apple-core (CLI proxy)
let connection = NSXPCConnection(machServiceName: "com.oliverames.applecore.xpc")
connection.remoteObjectInterface = NSXPCInterface(with: AppleCoreServiceProtocol.self)
connection.invalidationHandler = { exit(EXIT_FAILURE) }  // MCP client logs the disconnect
connection.interruptionHandler = { /* one reconnect attempt; if fails, invalidate */ }
connection.resume()
let proxy = connection.remoteObjectProxy as! AppleCoreServiceProtocol
```

**The protocol** is the typed seam between CLI and app:

```swift
@objc protocol AppleCoreServiceProtocol {
    func clientHandshake(clientId: String, clientName: String,
                         reply: @escaping (Bool, NSError?) -> Void)
    func listTools(reply: @escaping ([NSDictionary], NSError?) -> Void)
    func callTool(name: String, arguments: NSDictionary,
                  reply: @escaping (NSDictionary?, NSError?) -> Void)
    func ping(reply: @escaping (Bool) -> Void)  // health check
}
```

Tool inputs and outputs round-trip as `NSDictionary` (Codable-bridged through JSON) because XPC requires Foundation-bridged types. The CLI's stdio MCP wire is handled by `swift-sdk`'s `Server`; the XPC layer is just a typed dispatcher between the parsed MCP request and the app's tool implementations.

**Lifecycle:**

1. MCP client (Claude Desktop) launches `apple-core` CLI binary via stdio.
2. CLI immediately attempts `NSXPCConnection(machServiceName: "com.oliverames.applecore.xpc")`.
3. If the .app is running, connection succeeds.
4. If the .app isn't running, the CLI uses `NSWorkspace.shared.openApplication(at:configuration:)` with `--background` to launch it, then retries the connection with backoff (3 attempts, 500 ms apart).
5. On first successful connection, the CLI sends `clientHandshake(...)` with a stable client ID (parent process bundle ID + LaunchServices PID). The app's `ServerController` shows the approval alert if this is a new client; persists trust in `@AppStorage("trustedClients")`.
6. CLI then handles the MCP `initialize` from stdin and proxies subsequent tool listing/calling through XPC.
7. If the .app exits mid-session, the connection's `invalidationHandler` fires; the CLI exits nonzero; the MCP client logs the disconnect and surfaces the error.

**Why this beats Bonjour:**

- **No discovery** — CLI knows the Mach name at compile time. Eliminates iMCP's 30-second Bonjour timeout and the brittle `String(describing: $0.endpoint).contains("iMCP")` hack.
- **Strong typing** via the `@objc` protocol. Tool dispatch becomes a Swift API surface, not a free-form NWConnection byte stream.
- **Built-in lifecycle**: `interruptionHandler`, `invalidationHandler`. No custom continuation/QoS handling.
- **No NWError 54/57/96 cases to handle** — iMCP's `c9daec8` and `e00864f` patches become irrelevant.

**Sandbox entitlements** (documented for completeness — *not needed for unsandboxed v1*):
- App: `com.apple.security.temporary-exception.mach-register.global-name = ["com.oliverames.applecore.xpc"]`
- CLI: `com.apple.security.temporary-exception.mach-lookup.global-name = ["com.oliverames.applecore.xpc"]`

Unsandboxed processes register and look up Mach services freely; v1 ships without these.

#### Security-scoped bookmark for `chat.db`: drop

iMCP's `MessageService` uses `NSOpenPanel` + `withSecurityScopedAccess` to access `~/Library/Messages/chat.db` from inside the sandbox. Since v1 is unsandboxed, drop this entire pattern. Open the file directly under FDA. The `NSOpenPanel` flow re-emerges only if a future major version re-sandboxes.

#### Tests

iMCP ships zero tests. We change that day one. Swift Testing on macOS, unit tests for everything that doesn't touch the OS, integration tests behind `RUN_INTEGRATION_TESTS=1` against a dedicated test calendar/account.

#### Tool surface

We grow from iMCP's ~25 tools to ~60 over v1+v2 (per `SYNTHESIS.md §8`), with the same operation-multiplexed pattern (`reminders_tasks` carrying an `action` enum) for the CRUD-heavy surfaces — keeps the LLM-facing tool count manageable.

#### Doctor command

Lift adamzaidi's `--doctor` self-test as a first-class menu item in the .app *and* an MCP `server_doctor` tool. Walks each enabled surface, exercises permissions, reports green-check status. Far better UX than waiting for the first tool call to fail.

#### Tests

iMCP ships zero tests. We change that day one. Swift Testing (or XCTest where Swift Testing is awkward for the harness), unit tests for everything that doesn't touch the OS, integration tests behind `RUN_INTEGRATION_TESTS=1` against a dedicated test calendar/account.

#### Tool surface

We grow from iMCP's ~25 tools to ~60 over v1+v2 (per `SYNTHESIS.md §8`), with the same operation-multiplexed pattern (`reminders_tasks` carrying an `action` enum) for the CRUD-heavy surfaces — keeps the LLM-facing tool count manageable.

#### Doctor command

Lift adamzaidi's `--doctor` self-test as a first-class menu item *and* an MCP `server_doctor` tool. Walks each enabled surface, exercises permissions, reports green-check status. Far better UX than waiting for the first tool call to fail.

---

## 2. Per-surface port plan

Effort tiers: **S** = days, **M** = weeks, **L** = month+. Risk reflects translation difficulty plus runtime fragility.

| Surface | Donor(s) | Donor mechanism | Swift target | Effort | Risk | Notes |
|---|---|---|---|---|---|---|
| **Calendar** | iMCP, apple-events | EventKit | EventKit (already in iMCP); extend with apple-events' richer recurrence + structured location + alarms | M | low | iMCP has the scaffold; FradSer's coverage is deeper. Port his action-dispatcher shape into Swift. |
| **Reminders** | apple-events (richest), iMCP | EventKit + AS fallback for cross-source moves | EventKit; subtask metadata in our own SQLite *not* in the user's note body | M | low | FradSer encodes subtasks inside notes between `---SUBTASKS---` markers. Don't replicate — corrupts external writers. Persist to our own `subtasks` table keyed on `(account, calendar_item_id)`. |
| **Contacts** | iMCP | Contacts.framework | already in iMCP; add update + delete + create-from-vCard | S | low | Trivial extension of iMCP's existing `ContactService`. |
| **Notes (read+create)** | dhravya/super, mrgo2 | AppleScript / JXA | NSAppleScript via a typed wrapper (port `utils/applescript.js` to Swift) | M | medium | Notes has no native macOS API. AppleScript-only surface. Build a `AppleScriptRunner` actor with input via stdin (per mrgo2), typed errors mapped from stderr (per mrgo2). |
| **Notes (update)** | NEW — gap none of the seven cover | n/a | Read-modify-write via AppleScript with content-hash check before write | M | medium-high | Open question: how do we resolve concurrent edits? Tentative plan: hash note body before edit, fail if changed at write time, surface a `notes_update_conflict` error. |
| **Messages (read)** | iMCP | chat.db SQLite + madrid typedstream | already in iMCP | S | low | Drop the security-scoped-bookmark dance (sandbox-only); read chat.db directly under FDA. |
| **Messages (send)** | dhravya/super | AppleScript | NSAppleScript through the typed wrapper | S | low | Phone-number normalization helper (port from dhravya's `utils/message.ts`). |
| **Mail (read+search)** | apple-mail-mcp (GPL-3.0 — lifted directly, see §4) | disk-first `.emlx` parse + FTS5 cache + state-reconciliation sync | Foundation file enumeration + GRDB.swift FTS5 + custom diff | **L** | medium | The single biggest swift port. Translate Python to Swift function-by-function. |
| **Mail (send/draft/bulk)** | adamzaidi | imapflow + nodemailer | SwiftNIO IMAP (or hand-rolled IMAP client) + URLSession SMTP | M-L | medium | swift-nio-imap exists from Apple but is not 1.0; evaluate vs. MailCore2 (Objective-C, mature, GPL **no**, MPL — check). |
| **Mail (three-phase safe move)** | adamzaidi | copy → fingerprint-verify → expunge with persistent JSON manifest | Same algorithm in Swift, manifest as Codable JSON in Application Support | M | medium | Lift the algorithm verbatim with attribution. |
| **Maps** | iMCP | MapKit (search/directions/ETA/static map) | already in iMCP | S | low | Ship as-is. |
| **Weather** | iMCP | WeatherKit (entitled) | already in iMCP | S | low | Conditional-compiled per `WEATHERKIT_AVAILABLE`. Open question on entitlement. |
| **Location** | iMCP | Core Location | already in iMCP | S | low | Ship as-is. |
| **Capture (camera/audio/screen)** | iMCP | AVCaptureSession + ScreenCaptureKit | already in iMCP | S | low | Behind a feature flag (high TCC cost, niche use). |
| **Shortcuts** | iMCP | shell out to `/usr/bin/shortcuts` | already in iMCP | S | low | Add input validation against the live `shortcuts list` output (currently iMCP only validates the name shape). |
| **Safari (tabs)** | mrgo2 | AppleScript | NSAppleScript via typed wrapper | S | low | Useful for "what's the user looking at right now" workflows. |
| **Safari (history)** | NEW — gap | n/a | SQLite read of `~/Library/Safari/History.db` (FDA required) | M | medium | Schema documented in third-party reverse-engineering writeups. |
| **iCloud Calendar (CalDAV)** | adamzaidi | tsdav + ical.js | SwiftNIO HTTP/2 + ICalendarKit (or hand-roll) | M | medium | Why bother if EventKit covers it locally? Two reasons: headless mode (no GUI app running), and accessing accounts not configured in Calendar.app. |
| **iCloud Contacts (CardDAV)** | adamzaidi | tsdav | Same NIO base + custom vCard 4.0 parser | M | medium | Same headless rationale. |
| **iCloud Drive** | NEW — gap (none of the seven cover) | n/a | NSFileCoordinator + ubiquity APIs in entitled container | L | high | Requires an `iCloud.com.oliverames.applecore` container entitlement. We can read user files via NSFileCoordinator + standard FileManager APIs against `~/Library/Mobile Documents/`. **Open question on scope** — full filesystem ops or read-only? |
| **iCloud Photos / Photos library** | NEW — gap | n/a | PhotoKit (`PHPhotoLibrary`, `PHFetchOptions`, `PHAsset`) | M | medium | Native API, well-documented. Tools: search by date/location/people, fetch metadata, get image data, list albums. |
| **Find My** | NEW — gap | n/a | n/a | — | blocked | No public API. Skip. Document why in README. |
| **Health** | NEW — gap | n/a | HealthKit | — | blocked | iOS/watchOS only; no macOS HealthKit. Skip. |

### 2.1 Swift libraries we'd pull in

| Library | Used for | License | Notes |
|---|---|---|---|
| **swift-sdk (modelcontextprotocol/swift-sdk)** | MCP framing | MIT | Already in iMCP. Authoritative. |
| **JSONSchema** | Tool input schema validation | MIT | Already in iMCP. |
| **Ontology** | Schema.org JSON-LD outputs | MIT | Already in iMCP. |
| **madrid** | typedstream decoding | MIT | Already in iMCP. Keeps Messages working. |
| **swift-service-lifecycle** | Graceful shutdown | Apache-2.0 | Already in iMCP. |
| **swift-log** | Logging | Apache-2.0 | Already in iMCP. |
| **MenuBarExtraAccess** | Menu bar UI | MIT | Already in iMCP. |
| **GRDB.swift** | SQLite + FTS5 (Mail index, custom subtasks store) | MIT | New dep. Battle-tested. Best-in-class SQLite Swift wrapper. |
| **SwiftSoup** | HTML parsing inside `.emlx` and Mail bodies | MIT | New dep. Foundation only does NSAttributedString HTML which is heavyweight. |
| **swift-nio-imap** | IMAP client | Apache-2.0 | New dep. Apple project, not 1.0 yet. Evaluate vs. fallback. |
| **swift-nio** | NIO base | Apache-2.0 | Transitive of swift-nio-imap. |
| **swift-crypto** | TLS / IMAP STARTTLS | Apache-2.0 | Transitive. |
| **Sparkle** | Auto-update | MIT | Already wired in iMCP. |

License posture: every dep is MIT or Apache-2.0. No GPL, no LGPL, no AGPL. Clean for a notarized .app. Document in `NOTICES.md` at the repo root, generated from `Package.resolved`.

---

## 3. Per-surface deep dives

The §2 table is the index. The sections below are contributor-grade specs — each stands alone enough that a maintainer can pick a single Apple surface and start implementing it without re-reading the donor repos. Every section follows the same template:

- **Library/protocol choice and rationale** — exact framework, version notes, why this over alternatives
- **Authentication & credentials** — Keychain item shape, rotation path, env-var fallback
- **TCC / entitlements** — exact prompts, Info.plist usage strings, what the user sees
- **Data model** — Swift types we expose to MCP, with field-level decisions
- **Sync / caching** — where applicable
- **MCP tool inventory** — names, signatures, multiplexing decisions, annotations
- **Edge cases & gotchas** — donor-repo discoveries we inherit
- **Performance budget** — latency and memory targets
- **Testing strategy** — fixtures, mocks, what's testable without a real account

Sections are ordered by build importance: Mail first (deepest port, lifted from `apple-mail-mcp` per §4); iMCP-existing surfaces next (Calendar, Reminders, Contacts, Messages, Maps, Weather, Location, Capture, Shortcuts); AppleScript-only surfaces (Notes, Safari tabs); gap surfaces (Safari history, iCloud Drive, iCloud Photos); finally documented-blocked surfaces (Find My, Health).

### 3.1 Mail

**Donor(s):** apple-mail-mcp (GPL-3.0 — **lifted directly**; we translate Python to Swift), icloud-mcp-adamzaidi (MIT — IMAP/SMTP send paths), apple-mcp-dhravya/supermemoryai (MIT — AppleScript Mail UI fallbacks).
**License posture:** Apple Core is GPL-3.0-or-later (§0 decision 4) — matching apple-mail-mcp. We translate their disk-first parser, FTS5 cache, and state-reconciliation logic directly into Swift, attributing per §4.2. The MIT donors retain their MIT headers on the files we lift.
**Effort:** L (month-plus). The single biggest port in the project.
**Risk:** medium — first-time Swift translation of a deeply non-trivial Python pipeline. The clean-room overhead is gone.
**Target version:** v2.0.

#### Library/protocol choice and rationale

Mail is the only surface where we run **three** separate access paths in parallel, each chosen for a specific job. No single library covers all of read, search, write, and bulk well.

**Read & search → disk-first `.emlx` parsing + GRDB FTS5 cache.**

We parse Mail.app's on-disk store at `~/Library/Mail/V<N>/` directly, build a SQLite index with FTS5 over headers and body text, and serve all reads from there. Why this over alternatives:

- **vs. AppleScript Mail iteration**: 87× slower per the apple-mail-mcp public CLAUDE.md write-up. AppleScript over Mail is the canonical case study in why scripting bridges don't replace native data access.
- **vs. Mail.app's own `Envelope Index` SQLite**: that database is undocumented, schema changes between macOS versions, and Mail.app holds write locks on it. We *read* it for metadata where it's stable (UIDs, flag bits) but we don't depend on it as our primary store.
- **vs. IMAP for read**: IMAP works headlessly but it's slow (every search is a network round-trip) and re-fetches data the user already has locally. Disk-first wins for the "Mail.app is configured on this Mac" case, which is 95%+ of our users.
- **vs. MailKit (Apple's framework)**: MailKit is a Mail.app extension API for filters and message-content extensions. It does not expose a "read all my mail" API — it's the wrong abstraction. Skip.

GRDB.swift is the SQLite Swift wrapper; FTS5 is the SQLite full-text-search module. Both are battle-tested and MIT-licensed. Schema described in §3.1 / Data Model below.

**Write & bulk → swift-nio-imap + URLSession SMTP.**

For send, draft, move, flag, expunge — we use IMAP/SMTP against the user's mail server (typically `imap.mail.me.com` for iCloud). Why this over alternatives:

- **vs. AppleScript Mail send**: Works but slow, fragile under macOS updates, and produces messages that show up *only* in Mail.app. IMAP send via SMTP creates messages on the server that sync to every client (Mail.app, iOS Mail, web) automatically.
- **vs. MailCore2 (objc++)**: Mature, BSD-3-Clause, but ageing — last major release 2018-ish, Swift package wrappers are unmaintained, ObjC++ bridging tax in Swift. swift-nio-imap is Apple's first-party answer and has more momentum even pre-1.0.
- **swift-nio-imap version notes**: Pre-1.0 as of training cutoff. The IMAP4rev1 surface is feature-complete; the API may break. Pin to a specific commit, plan on porting work when we bump versions. If swift-nio-imap proves too unstable, fall back to MailCore2 wrapped in a thin Swift shim.
- **SMTP via URLSession is feasible** for our needs (auth via `STARTTLS` + `PLAIN`/`LOGIN`, multipart bodies via raw text construction). We don't need a full SMTP library — the protocol is simple. ~300 lines of Swift.

**UI-attached operations → AppleScript Mail.**

A few operations are best done by driving Mail.app directly: opening a message in the user's Mail UI (`mail_open_in_app`), creating a draft that's editable in Mail (so the user can review before send), and triggering Mail.app's own rules engine. These shell out to AppleScript via our shared `AppleScriptRunner` actor.

#### Authentication & credentials

**Disk-first read path: no auth.** Mail.app has already authenticated the user's accounts. We read the resulting `.emlx` files; the OS-level Full Disk Access entitlement (TCC) is the only gate.

**IMAP/SMTP write path: app-specific password per account, stored in macOS Keychain.**

Keychain item shape (using `kSecClassInternetPassword` for IMAP/SMTP, since the OS already understands these as internet credentials):

```swift
struct MailKeychainItem {
    let server: String          // imap.mail.me.com, smtp.mail.me.com
    let account: String         // user@icloud.com
    let `protocol`: SecProtocolType  // .IMAPS or .SMTPS
    let port: Int               // 993 or 587
    let password: String        // app-specific password
    let label: String           // "com.oliverames.applecore: IMAP <account>"
}
```

We use `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` directly against Security framework — no third-party wrapper. This means the Keychain entries are visible in Keychain Access.app under "Internet Passwords", which is what users expect.

**Rotation path**: when the user generates a new app-specific password (via appleid.apple.com), they re-run our Settings panel's "Update Mail Password" flow. We re-add to Keychain (which updates by composite key), invalidate cached IMAP connections, and run `--doctor` to verify. No restart required.

**Env-var fallback** for headless / CI use: `APPLE_MCP_MAIL_PASSWORD_<account-slug>=<password>`. Documented as reduced-security; surface a warning in `--doctor` output when env vars are in use.

**Multi-account**: each iCloud Mail account or third-party IMAP account gets its own Keychain item. A `mail_accounts` setting in `UserDefaults` records `[Account]` with credentials referenced by Keychain item ID, never inline. Adamzaidi's mistake — `lib/carddav.js` reading `process.env.IMAP_USER` directly so multi-account didn't actually work for Contacts/Calendar — is the explicit anti-pattern we avoid: every code path threads through a typed `Account` value, never a global env var.

#### TCC / entitlements

Three TCC permissions in play, one entitlement.

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Full Disk Access** (FDA) | Reading `~/Library/Mail/V<N>/` | macOS does not auto-prompt for FDA — user must grant manually in System Settings → Privacy & Security → Full Disk Access. We surface a guided dialog: "Apple Core needs Full Disk Access to read your Mail. Click Open Settings, find Apple Core in the list, and toggle it on." | If denied: degraded mode where reads cascade to AppleScript Mail (slow but works). Document the cliff in user-facing docs. |
| **Apple Events → Mail.app** | First AppleScript send to Mail.app | "Apple Core wants permission to control Mail" | If denied: send-via-AppleScript fails. IMAP send still works. |
| **Network outbound to imap.mail.me.com:993, smtp.mail.me.com:587** | First IMAP connection | No prompt under non-sandboxed; sandboxed needs `com.apple.security.network.client` entitlement | If denied (sandbox without entitlement): IMAP/SMTP fails entirely. |

**Info.plist usage strings** added to the existing iMCP set:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Apple Core uses AppleScript to drive Mail.app for opening messages, creating editable drafts, and triggering Mail's rules engine.</string>
```

FDA does not have a corresponding `NS<X>UsageDescription` key — it's a system-level permission, granted only via System Settings, not via an in-app prompt. iMCP currently has a temp-exception read for `~/Library/Messages/`; we add an analogous one for `~/Library/Mail/`:

```xml
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/Users/USERNAME/Library/Mail/</string>
    <string>/Users/USERNAME/Library/Messages/</string>
</array>
```

For sandboxed v1, this is the path. If it proves insufficient (Apple rejects the entitlement, FDA isn't recognized through the sandbox), we ship Mail under an "advanced features" toggle that the user enables, which silently disables sandbox for our app. Open question §7.3.

**Doctor output** for Mail:

```
$ apple-mcp doctor mail
[✓] Bundle entitlements include Mail temp-exception read
[✓] Full Disk Access granted (read of ~/Library/Mail/V10/MailData/Envelope Index succeeded)
[✓] Mail.app installed at /System/Applications/Mail.app
[✓] Apple Events permission granted (osascript probe succeeded)
[✓] iCloud Mail account discovered: oliver@icloud.com
[✓] Keychain credential found: imap.mail.me.com (oliver@icloud.com)
[✓] IMAP login: 220 OK in 234ms
[✓] INBOX open: 12,847 messages, 23 unread
[✓] FTS5 index DB: 1.2 GB, last full rebuild 2 days ago
[✓] State-reconciliation pass: 12 NEW, 0 DELETED, 1 MOVED in 3.1s
```

#### Data model

The Swift types we expose to MCP. These are the *result types* — the MCP tool input schemas are defined per-tool below. All conform to `Codable` and the JSON-LD encoding from `Ontology` where a Schema.org type matches.

```swift
struct MailAccount: Codable, Sendable, Identifiable {
    let id: String                // stable internal ID (UUID per Mail.app account)
    let displayName: String       // "Oliver – iCloud"
    let emailAddress: String      // "oliver@icloud.com"
    let type: AccountType         // .icloud, .imap, .exchange (gleaned from Mail.app)
    let rootPath: URL             // ~/Library/Mail/V10/<UUID>.mbox
    let imapHost: String?         // for write paths
    let smtpHost: String?
    let isEnabled: Bool
}

struct Mailbox: Codable, Sendable, Identifiable {
    let id: String                // composite: account-id + "/" + relative path
    let accountId: String
    let displayName: String       // "Inbox", "Sent Messages", "Archive/2026"
    let role: MailboxRole         // .inbox, .sent, .drafts, .trash, .junk, .archive, .normal
    let unreadCount: Int
    let totalCount: Int
    let pathOnDisk: URL?          // nil for virtual mailboxes
}

enum MailboxRole: String, Codable, Sendable {
    case inbox, sent, drafts, trash, junk, archive, normal
}

struct EmailSummary: Codable, Sendable, Identifiable {
    let id: String                // composite: account-id + "/" + mailbox-id + "/" + message-id-header
    let mailboxId: String
    let subject: String
    let from: EmailAddress
    let to: [EmailAddress]
    let cc: [EmailAddress]
    let date: Date
    let snippet: String           // first 200 chars of body, plain text
    let hasAttachments: Bool
    let attachmentCount: Int
    let isRead: Bool
    let isFlagged: Bool
    let isReplied: Bool
    let isForwarded: Bool
    let sizeBytes: Int
}

struct Email: Codable, Sendable, Identifiable {
    let id: String                // same ID as EmailSummary
    let summary: EmailSummary     // embedded for convenience
    let bcc: [EmailAddress]
    let replyTo: [EmailAddress]
    let messageIdHeader: String   // RFC 5322 Message-ID
    let inReplyTo: String?        // RFC 5322 In-Reply-To header
    let references: [String]      // RFC 5322 References header (parsed)
    let bodyText: String          // best-effort plain text
    let bodyHTML: String?         // raw HTML if present
    let attachments: [Attachment]
    let rawHeaders: [String: [String]]  // for power users; full header set
}

struct EmailAddress: Codable, Sendable {
    let address: String           // "oliver@icloud.com"
    let displayName: String?      // "Oliver Ames"
}

struct Attachment: Codable, Sendable, Identifiable {
    let id: String                // emailId + ":" + index
    let emailId: String
    let filename: String
    let mimeType: String          // "application/pdf"
    let sizeBytes: Int
    let disposition: AttachmentDisposition  // .inline, .attachment
    let contentId: String?        // for inline (cid: refs)
    let isExtracted: Bool         // whether we have the body bytes cached
}

enum AttachmentDisposition: String, Codable, Sendable {
    case inline, attachment
}

struct EmailThread: Codable, Sendable, Identifiable {
    let id: String                // root message-id
    let subject: String
    let participants: [EmailAddress]
    let messageCount: Int
    let firstDate: Date
    let lastDate: Date
    let messages: [EmailSummary]  // ordered chronologically
}
```

**Threading**: built from RFC 5322 `References:` and `In-Reply-To:` headers. We don't trust subject-line normalization (the "Re: Re: Re:" approach) because it produces false positives; we only fall back to subject matching when both headers are missing AND the subject prefix-stripped match exceeds a similarity threshold. Threads are *computed on demand*, not stored — `mail_get_thread(message_id)` walks the index by header graph and returns the materialized thread.

**Multi-part bodies**: a single `Email` exposes both `bodyText` and `bodyHTML`. If only HTML is present, `bodyText` is derived via SwiftSoup → `.text()`. If only plain is present, `bodyHTML` is nil. Inline images (cid: references) resolve to attachments; tools that render bodies can substitute `data:` URIs if asked.

**Flags**: `.emlx` files have a trailing plist with a `flags` integer. Bit 0 = read, bit 4 = flagged. Other bits track replied/forwarded/deleted state. We read these directly from disk and reconcile with IMAP UIDs where the user's IMAP server has authoritative state.

#### Sync / caching strategy

The whole point of disk-first is the FTS5 cache. Lifted directly from `apple-mail-mcp` (Python → Swift translation, attribution per §4.2):

**Index DB location**: `~/Library/Application Support/com.oliverames.applecore/mail-index.sqlite`, mode 0600.

**Schema** (translate apple-mail-mcp's SQL to GRDB migrations; the description below is for orientation, not a re-spec):

- A table of *emails* keyed by `(account_id, mailbox_id, message_id_header)` with columns covering all the `EmailSummary` fields plus body text/html, header bag, path-on-disk, and a `last_seen_inode` column for move detection.
- A table of *attachments* with foreign key to emails, columns for filename/mime/size/disposition/content-id, plus a nullable `extracted_path` for cached attachment bytes.
- A table of *sync_state* recording the last successful reconciliation pass per `(account_id, mailbox_id)` with a timestamp and a hash of the directory listing.
- An *FTS5 virtual table* `emails_fts` mirroring `(subject, from_address, from_name, to_addresses, body_text, attachment_filenames)` with `tokenize='porter unicode61 remove_diacritics 1'`. External-content table linked to the main `emails` table; trigger-maintained on insert/update/delete.
- An *attachments_fts* virtual table over filename and extracted-text where applicable.
- Indexes on `emails(account_id, mailbox_id, date DESC)` for "show me recent in this mailbox" and on `emails(message_id_header)` for thread-graph walks.

**State-reconciliation sync**: the reconciliation pass produces three change sets without ever scanning email bodies:

1. **`disk_inventory(account_id, mailbox_id)`**: a fast directory walk yielding `(message_id_header, path_on_disk, mtime, size)`. We only read the trailing plist of each `.emlx` for the message-id; not the body.
2. **`db_inventory(account_id, mailbox_id)`**: a single SQL query selecting `(message_id_header, path_on_disk)` for the same scope.
3. **Diff produces**: NEW = in disk, not in db; DELETED = in db, not in disk; MOVED = in both but `path_on_disk` differs.
4. NEW emails get parsed (header + body MIME) and inserted. DELETED emails are removed. MOVED emails have only their `path_on_disk` and `mailbox_id` updated. Body text is never re-read for MOVED.

**Trigger conditions for a sync**:

- On app launch (full pass scoped to enabled accounts).
- On user-initiated `mail_search` if the index is older than the staleness threshold (default 5 minutes).
- On a watcher event (optional v2.1 feature): we use `DispatchSource.makeFileSystemObjectSource` against each mailbox directory's `Messages/` subdir to coalesce file-system events and trigger a scoped reconciliation.

**Body-extraction policy**: full body text is parsed at NEW-insert time. For very large emails (>5 MB MIME), we cap stored body at 1 MB and set a `body_truncated: true` flag; the original `.emlx` path remains and tools that need the full body re-read on demand.

**Attachments**: by default we store *metadata only* in the DB; attachment bytes are read on demand from `.emlx` (or via JXA fallback if the file is moved). When `mail_get_attachment(...)` is called, we extract once and cache to `~/Library/Caches/com.oliverames.applecore/mail-attachments/<email-id>/<filename>` with a 7-day expiry.

**Re-index from scratch**: a `mail_rebuild_index` admin tool drops `mail-index.sqlite` and re-runs reconciliation. Targets full rebuild in <60s for a 50,000-email account on an M-series Mac.

#### MCP tool inventory

Designed for the LLM-facing surface. Tools that are read-only get `readOnlyHint: true`. Bulk operations get `destructiveHint: true`. All tools accept an optional `account_id` (defaults to "all enabled accounts") and an optional `mailbox_id` (defaults to "all" for reads, required for writes that target a specific mailbox).

**Read & search:**

- `mail_list_accounts() -> [MailAccount]` — read-only. Returns enabled accounts.
- `mail_list_mailboxes(account_id?) -> [Mailbox]` — read-only.
- `mail_search(query, scope?, account_id?, mailbox_id?, before?, after?, has_attachments?, is_unread?, is_flagged?, from_address?, to_address?, limit=50, offset=0, highlight=false) -> {results: [EmailSummary], total: Int}` — read-only.
  - `scope`: `"all" | "subject" | "sender" | "body" | "attachments"` (default `"all"`).
  - `query`: FTS5 query string with our own escaping; we strip FTS5 operators by default and let users opt into raw with `query: "RAW: ..."` prefix.
  - `highlight`: when true, returns snippets with `<mark>...</mark>` tags around matches.
- `mail_get_email(id, include_body=true, include_attachments_metadata=true, include_raw_headers=false) -> Email`
- `mail_get_email_links(id) -> [{url, anchor_text}]` — extract <a> hrefs and bare URLs from the body.
- `mail_get_attachment(email_id, filename) -> {filename, mime_type, size_bytes, content: Base64String}` — destructive in the sense that it extracts bytes; technically read-only.
- `mail_count_emails(account_id?, mailbox_id?, group_by?) -> {total: Int, groups?: [{key: String, count: Int}]}` — `group_by`: `"sender" | "domain" | "month"`. Powers "who sends me the most email" and "what month has the most newsletters" workflows.
- `mail_get_top_senders(account_id?, mailbox_id?, since?, limit=20) -> [{address: EmailAddress, count: Int}]`.
- `mail_get_thread(message_id, include_full_messages=false) -> EmailThread`.

**Send & draft:**

- `mail_compose(from_account_id, to, cc?, bcc?, subject, body_text, body_html?, in_reply_to?, references?, attachments?) -> {message_id: String, sent: Bool}` — destructive, opens TCC for SMTP.
- `mail_reply(email_id, body_text, body_html?, reply_all=false, attachments?) -> {message_id: String, sent: Bool}`.
- `mail_forward(email_id, to, body_text, body_html?, attachments?) -> {message_id: String, sent: Bool}`.
- `mail_save_draft(...same shape as compose..., draft_id?) -> {draft_id: String}` — saves to the account's Drafts mailbox via IMAP APPEND.

**Per-message write:**

- `mail_flag(id, flagged: Bool) -> Email`.
- `mail_mark_read(id, is_read: Bool) -> Email`.
- `mail_move(id, target_mailbox_id) -> Email` — destructive.
- `mail_delete(id) -> {deleted: Bool}` — destructive; moves to Trash unless `permanent: true`.

**Bulk:**

All bulk tools use the **three-phase safe move** (port adamzaidi's pattern): copy to target → fingerprint-verify → single EXPUNGE on source. Writes a manifest to `~/Library/Application Support/com.oliverames.applecore/mail-move-manifest-<uuid>.json` so an interrupted bulk operation can be resumed or rolled back.

- `mail_bulk_move(filter, target_mailbox_id, dry_run=true, max_count?) -> {moved: Int, failed: Int, manifest_path: String}` — destructive. `filter` shape mirrors `mail_search`.
- `mail_bulk_mark_read(filter, dry_run=true)`.
- `mail_bulk_delete(filter, dry_run=true)` — destructive, to Trash by default.
- `mail_archive_older_than(date, account_id?, mailbox_id?, target_mailbox_id, dry_run=true)`.
- `mail_get_move_status(manifest_path) -> {status: "in_progress" | "succeeded" | "failed", moved: Int, total: Int, started_at: Date, errors: [String]}`.
- `mail_abandon_move(manifest_path) -> {abandoned: Bool, reverted: Int}` — best-effort rollback.

**Mailbox management:**

- `mail_create_mailbox(account_id, parent_mailbox_id?, name) -> Mailbox`.
- `mail_rename_mailbox(id, new_name) -> Mailbox`.
- `mail_delete_mailbox(id) -> {deleted: Bool}` — destructive.

**UI bridge:**

- `mail_open_in_app(id) -> {opened: Bool}` — opens the message in Mail.app via AppleScript. Useful when the model wants to hand control back to the user.

**Multiplexing decision**: 28 tools is a lot but we deliberately don't multiplex Mail through an `operation` enum the way we do for Reminders. Mail's parameter shapes vary too much between read and write, between single and bulk, for a unified schema to be readable to the LLM. The flat tool list pays in tool-budget but reads better at compose-time.

#### Edge cases & gotchas

1. **`.emlx` byte-length header lies during a partial write.** When Mail.app is mid-sync, an `.emlx` may exist on disk with a header byte-length but no body yet. Our parser must verify the byte length matches actual file size — 1, otherwise skip and retry the file in the next reconciliation pass. apple-mail-mcp learned this; we inherit the lesson.
2. **macOS Mail directory version bump.** Apple has shipped V10 (Sonoma), V11 (Sequoia), and at least one bump beyond. Our code detects the version directory by glob `~/Library/Mail/V*/` and picks the highest. If two coexist (mid-migration), we read the higher and warn.
3. **Encrypted messages** (`multipart/encrypted`, `application/pkcs7-mime`). We surface metadata only (subject, sender, date, "encrypted: true"); body is left empty. We never attempt to decrypt — that's a private-key user-action that doesn't belong in an MCP.
4. **Subject-prefix locales**: `Re:`, `Fwd:`, `Sv:`, `Antw:`, `Vs:`, etc. We strip a curated set when building thread keys but only fall back to subject matching when no header thread exists.
5. **Multi-account threading**: a thread can span accounts (forwarded to a different inbox). Thread IDs are content-addressed (root message-id), not account-scoped. Cross-account threads work transparently.
6. **Group MMS via Mail (rare but exists)**: Mail.app sometimes ingests MMS via `@msg.mac.com`. We treat these as normal emails; no special-casing.
7. **Inline images stored as separate `.emlx`**. Some Mail accounts (notably Exchange) split inline images into separate message-id'd attachments. Our parser recognizes by `Content-Disposition: inline` + `Content-ID` and merges into the parent at materialization time.
8. **Drafts directory weirdness**: drafts are stored as `.emlxpart` files (no header byte-length, raw MIME) on some macOS versions. Our parser handles both.
9. **iCloud throttling on IMAP**: lifting adamzaidi's connect-rate-limiting gate. Single global `_connectGate` actor serializing connection initiations 10 ms apart; in-flight sessions run concurrently.
10. **App-specific password expiry**: Apple expires after long inactivity. IMAP auth failure with `BAD AUTHENTICATIONFAILED` triggers a user-facing notification with a deep-link to the Settings panel's "Update Mail Password" flow.
11. **Mail.app rebuilds the Envelope Index** without warning (Software Update, mailbox repair, etc.). Our index is independent and survives this; the only impact is that our IMAP UIDs may become stale, which we detect on the next IMAP UIDVALIDITY check.
12. **Subject-line `=?UTF-8?B?...?=` encoded headers**: RFC 2047 MIME-encoded-words. Decode at parse time to UTF-8 strings; never expose raw to MCP results.

#### Performance budget

| Operation | Target | Rationale |
|---|---|---|
| Single-email read by ID (index hit) | <5 ms | Direct `.emlx` parse from known path. apple-mail-mcp's public Strategy 0 hits this number. |
| Single-email read by ID (index miss → JXA fallback) | <500 ms | Mail.app round-trip. Acceptable degraded path. |
| FTS5 search returning ≤100 hits | <50 ms | GRDB.swift FTS5 query against an indexed table. |
| FTS5 search returning ≤1,000 hits | <200 ms | |
| Mailbox list with counts | <20 ms | Counts cached per mailbox. |
| Reconciliation pass (50,000-email account, no changes) | <5 s | Two directory walks + one `EXCEPT` query. |
| Reconciliation pass (50,000-email account, 100 NEW) | <10 s | Plus body-text MIME parsing for the 100 new. |
| Full index rebuild from scratch (50,000 emails) | <60 s | One-time cost; backgrounded with progress reporting. |
| IMAP send (single message, no attachment) | <2 s | Network-bound; iCloud's typical RTT. |
| IMAP send (single message, 5 MB attachment) | <10 s | |
| Bulk move 1,000 messages | <30 s | Three-phase safe; copy-and-verify is the bottleneck. |

**Memory ceilings**:

- The FTS5 index DB is bounded by the corpus; expect ~1.5 GB for a 50,000-email account with full body text.
- In-memory: <100 MB for steady-state; reconciliation is streaming (we don't load all `.emlx` into memory at once).
- Attachment cache: bounded by 1 GB on disk by default (tunable in Settings); LRU eviction.

#### Testing strategy

**Synthetic `.emlx` corpus** at `Tests/MailServiceTests/Fixtures/V10/`. ~50 messages covering:

- Plain ASCII, UTF-8, RFC 2047 encoded subjects.
- Single-part text, multipart/alternative (text+html), multipart/mixed (text+attachments).
- Inline images via cid: references.
- Threaded replies (header chain of 5).
- Forwarded messages (References vs. In-Reply-To variations).
- Encrypted messages (we just verify we surface the correct metadata-only result).
- Edge cases: zero-byte body, missing Date header, malformed Content-Type, BOM in subject, `=?ISO-8859-1?Q?` encoded.
- Drafts in `.emlxpart` form.
- A mailbox version-number bump fixture (V10 + V11 coexisting).

These fixtures are committed to the repo under MIT (we author them, no GPL exposure). They are sufficient for *parser*, *FTS5 indexer*, and *reconciliation diff* unit tests — none require a real Mail.app or iCloud account.

**Fakes & mocks**:

- `FakeMailIndex`: in-memory implementation of the indexer protocol for tool-layer tests.
- `MockIMAPClient`: protocol-conforming stand-in for the swift-nio-imap client; records sent commands, plays back canned responses. Used to test `mail_compose`, `mail_bulk_move`, etc., without network.
- `MockKeychain`: in-memory dictionary; tests that verify "credentials are read from Keychain, never from env vars" run against this.

**Integration tests** behind `RUN_INTEGRATION_TESTS=1`:

- A real iCloud test account (separate from Oliver's main, see open question §7.6) with a known fixture mailbox.
- Tests cover: full reconciliation, IMAP login, send-and-receive round-trip, attachment upload, bulk move with manifest verification.

**What's NOT testable without a real account**:

- iCloud's actual throttling behavior under sustained connect bursts (we test the gate logic with a fake clock; the real throttle thresholds drift).
- Spam-folder behavior of the user's own iCloud account (varies per account).
- Real `.emlx` content from third-party IMAP servers (Exchange, Gmail-over-IMAP) — surfaces format quirks our synthetic fixtures don't replicate.

**CI integration**: unit tests run on every PR (Swift Testing on macOS-latest GitHub runner). Integration tests run nightly on a self-hosted macOS runner with credentials in CI secrets, gated to the `mail` workflow.

### 3.2 Calendar

**Donor(s):** iMCP (MIT — base scaffolding), mcp-server-apple-events (MIT — richer recurrence/alarms/structured-location/span semantics).
**Effort:** M (weeks).
**Risk:** low.
**Target version:** v1.0.

#### Library/protocol choice and rationale

**EventKit, native.** This decision was already made in iMCP and we keep it. The minimum-deployment-target is macOS 14 (`requestFullAccessToEvents()` shipped in macOS 14 / iOS 17), but we follow iMCP at macOS 15.3+.

Why not alternatives:

- **vs. CalDAV directly**: CalDAV requires headless mode (no local Calendar.app) and re-implementing recurrence rule expansion. Reserved for v2.1's "iCloud Calendar headless" feature, which is a parallel access path, not a replacement. EventKit is faster, lower-friction, and exposes write-back without us touching the wire format.
- **vs. AppleScript Calendar**: 100× slower per round-trip and Apple has progressively reduced the AppleScript Calendar dictionary over recent macOS versions. Avoid.
- **vs. CalendarStore.framework**: deprecated since macOS 10.8; not available.

**Recurrence-rule strategy**: EventKit's `EKRecurrenceRule` covers daily/weekly/monthly/yearly with `byday`/`bymonthday`/`bymonth`/`bysetpos`/`byweekno`. It does **not** support hourly/minutely/secondly frequencies (apple-events extends to those by emitting raw RRULE strings). For v1.0 we ship only EventKit-native frequencies. v1.1 adds raw RRULE support via `EKEvent.recurrenceRules` accepting any RFC 5545 rule — EventKit accepts arbitrary RRULE strings even when the GUI doesn't expose them, so this works.

**Span semantics** (apple-events' contribution): when modifying a single occurrence of a recurring event, EventKit accepts `EKSpan.thisEvent` vs `.futureEvents`. We expose this as a `span` parameter on update/delete tools.

#### Authentication & credentials

**No credentials required.** Calendar accounts are configured in System Settings > Internet Accounts; we read what's there. iCloud, Google, Exchange, CalDAV, and local "On My Mac" calendars all surface through `EKEventStore` uniformly.

**Headless mode** (v2.1) is the only path that needs credentials, and that's the CalDAV implementation, not this surface.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Calendar Full Access** | First `EKEventStore.requestFullAccessToEvents()` | "Apple Core would like full access to your calendars" | If `.writeOnly` denied / read-only granted: write tools fail with typed error. If denied entirely: all tools fail with typed error. |
| **Calendar Write-Only** | Optionally requested separately for a more permissive prompt | "Apple Core would like to add events to your calendar" | Useful for the "I just want to file an event in your calendar" workflow. Skipped in v1.0; can be added later if user feedback shows the full-access prompt scares people off. |

**Info.plist usage strings** (from iMCP, kept):

```xml
<key>NSCalendarsUsageDescription</key>
<string>Apple Core reads and creates events in your calendars when you ask Claude to manage your schedule.</string>
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Apple Core needs full access to read existing events and create new ones at your request.</string>
<key>NSCalendarsWriteOnlyAccessUsageDescription</key>
<string>Apple Core creates events in your calendars when you ask Claude to add something to your schedule.</string>
```

**Entitlements**: `com.apple.security.personal-information.calendars`. iMCP already declares this.

**Doctor output** for Calendar:

```
$ apple-mcp doctor calendar
[✓] EKEventStore authorization: fullAccess
[✓] Calendar sources: 4 (iCloud, On My Mac, Google, Exchange)
[✓] Calendars total: 7 (Personal, Work, Family, Holidays-US, Birthdays, ...)
[✓] Default calendar: Personal (iCloud)
```

#### Data model

```swift
struct CalendarSource: Codable, Sendable, Identifiable {
    let id: String                // EKSource.sourceIdentifier
    let title: String             // "iCloud", "On My Mac"
    let type: CalendarSourceType  // .iCloud, .local, .calDAV, .exchange, .subscribed
}

struct EventCalendar: Codable, Sendable, Identifiable {
    let id: String                // EKCalendar.calendarIdentifier
    let title: String
    let sourceId: String
    let color: String             // hex "#RRGGBB"
    let allowsModifications: Bool
    let type: CalendarType        // .local, .calDAV, .exchange, .subscription, .birthday
}

struct Event: Codable, Sendable, Identifiable {
    let id: String                // EKEvent.eventIdentifier (stable across launches)
    let calendarId: String
    let title: String
    let location: String?
    let structuredLocation: StructuredLocation?
    let start: Date
    let end: Date
    let isAllDay: Bool
    let timeZone: String?         // IANA, e.g. "America/New_York"
    let availability: Availability   // .busy, .free, .tentative, .unavailable
    let status: EventStatus       // .none, .confirmed, .tentative, .canceled
    let recurrenceRules: [RecurrenceRule]
    let alarms: [Alarm]
    let attendees: [Attendee]
    let organizer: Attendee?
    let url: URL?
    let notes: String?
    let occurrenceDate: Date?     // for materialized recurring instances
    let isDetached: Bool          // true if this is a modified instance
}

struct StructuredLocation: Codable, Sendable {
    let title: String
    let latitude: Double?
    let longitude: Double?
    let radius: Double?
}

enum Availability: String, Codable, Sendable { case busy, free, tentative, unavailable }
enum EventStatus: String, Codable, Sendable { case none, confirmed, tentative, canceled }

struct RecurrenceRule: Codable, Sendable {
    let frequency: Frequency      // .daily, .weekly, .monthly, .yearly (+ .hourly/.minutely in v1.1)
    let interval: Int             // every N
    let byDay: [DayOfWeek]?       // [.monday, .wednesday]
    let byMonthDay: [Int]?
    let byMonth: [Int]?
    let bySetPosition: [Int]?
    let weekStart: DayOfWeek?
    let endCondition: EndCondition  // .never, .untilDate(Date), .occurrenceCount(Int)
}

enum Frequency: String, Codable, Sendable {
    case daily, weekly, monthly, yearly
    case hourly, minutely        // v1.1
}

struct Alarm: Codable, Sendable {
    let trigger: AlarmTrigger
    let action: AlarmAction       // .display, .audio, .email
    let proximity: Proximity?     // for location-based alarms
}

enum AlarmTrigger: Codable, Sendable {
    case relative(TimeInterval)   // -900 = 15 min before
    case absolute(Date)
    case location(StructuredLocation)
}

enum Proximity: String, Codable, Sendable { case enter, leave }

struct Attendee: Codable, Sendable {
    let name: String?
    let emailAddress: String?
    let participantStatus: ParticipantStatus  // .accepted, .declined, .tentative, .pending, .unknown
    let participantRole: ParticipantRole       // .required, .optional, .chair, .nonParticipant
    let isCurrentUser: Bool
}
```

JSON-LD: `Event` is encoded as Schema.org `Event` via `Ontology` (already in iMCP).

#### MCP tool inventory

Multiplexed via `action` enum on the verb-rich tools, per FradSer's pattern.

- `calendar_calendars(action, ...) -> ...` — read-only.
  - `read`: `() -> [EventCalendar]`.
  - Calendar create/rename/delete intentionally **not exposed** in v1.0; we don't want the LLM creating calendars by accident. Surface in v1.2 if needed.

- `calendar_events(action, ...) -> ...`
  - `read(start?, end?, calendar_ids?, query?, expand_recurrence=true, limit=100) -> [Event]` — read-only.
    - `expand_recurrence`: when true, recurring events are materialized into individual occurrences within the date range.
  - `get(id, occurrence_date?) -> Event` — read-only.
  - `create(event_input) -> Event` — destructive=false (creates not destroys), but adds permanent state.
  - `update(id, event_input, span="this-event") -> Event` — destructive (modifies existing data). `span: "this-event" | "future-events"`.
  - `delete(id, span="this-event") -> {deleted: Bool}` — destructive.

- `calendar_check_availability(start, end, calendar_ids?) -> {is_free: Bool, conflicts: [Event]}` — read-only convenience for "am I free Tuesday at 2?"
- `calendar_suggest_meeting_time(duration_minutes, attendees: [String]?, search_window_start, search_window_end, preferred_hours?: {start_hour: Int, end_hour: Int}, calendar_ids?) -> [{start: Date, end: Date}]` — read-only. Returns up to 5 candidate slots.

`event_input` is a struct with all the fields a user might want to set on create/update:

```swift
struct EventInput: Codable, Sendable {
    let calendarId: String?       // nil = default calendar
    let title: String
    let location: String?
    let structuredLocation: StructuredLocation?
    let start: Date
    let end: Date
    let isAllDay: Bool?
    let timeZone: String?
    let availability: Availability?
    let recurrenceRules: [RecurrenceRule]?
    let alarms: [Alarm]?
    let attendees: [Attendee]?    // create only; updating attendees has special semantics
    let url: URL?
    let notes: String?
}
```

#### Edge cases & gotchas

1. **Recurring-event identity**. EventKit's `eventIdentifier` is stable per-occurrence; for recurring events, the same identifier returns different concrete instances depending on `occurrenceDate`. Our `Event.id` is the EKEvent identifier; reads of recurring events expose `occurrenceDate` so the model can disambiguate.
2. **Span on update**: changing the title of "this event" in a recurring series creates a *detached* event with the same calendar identifier but `isDetached=true`. The model needs to know whether the user means "this one" or "the whole series" — we make `span` an explicit required-with-default parameter on update/delete.
3. **iCloud calendar invites with attendee responses**: only the organizer can change attendee status. We surface the role and current status; updates that require organizer permissions return a typed error.
4. **All-day events crossing time zones**: an all-day event starts at 00:00 local and ends at 00:00 local on the *next* day in EventKit. We preserve this; our `Event.end` is exclusive, not inclusive, when `isAllDay=true`.
5. **Birthday calendar is read-only**, derived from Contacts. We expose it but reject writes with a typed `CalendarReadOnlyError`.
6. **Time-zone propagation**: events have a time zone, which is required for non-all-day events that recur (otherwise daylight-saving boundaries shift the time). We default to the user's current zone if not specified.
7. **Default-calendar selection** when user doesn't specify on create: we use `EKEventStore.defaultCalendarForNewEvents`, falling back to the first iCloud personal calendar, then to "On My Mac". Surface in the result so the model can confirm.
8. **EKAlarm absolute date in past**: macOS rejects this silently. We validate at the tool layer and return an error rather than silently dropping.
9. **EventKit's `predicateForEvents(...)` capped at 4 years**: we explicitly cap any `read` query window at 4 years and chunk wider queries.
10. **Subscribed calendars (e.g., team holidays)** are read-only. We surface but reject writes.

#### Performance budget

| Operation | Target |
|---|---|
| `calendar_calendars/read` | <50 ms |
| `calendar_events/read` (1 month, expanded) | <200 ms |
| `calendar_events/read` (1 year, expanded, ~500 events) | <1 s |
| `calendar_events/get` | <30 ms |
| `calendar_events/create` | <100 ms (local) / <500 ms (iCloud round-trip) |
| `calendar_check_availability` (1 week) | <100 ms |
| `calendar_suggest_meeting_time` (1 week, 3 candidates) | <500 ms |

Memory: negligible. EventKit caches in-process; we don't materialize anything.

#### Testing strategy

**Unit tests**: pure-data tests for `EventInput` → `EKEvent` round-trip, recurrence-rule encoder/decoder, time-zone handling, span semantics. Use a `MockEventStore` protocol-conforming fake.

**Integration tests** (gated): create a dedicated calendar called `apple-mcp-test` on a test iCloud account, run create/read/update/delete cycles against it, then delete the calendar at end of suite. Tests are idempotent — they tolerate prior runs leaving state behind.

**What's not testable without a real account**: iCloud's actual sync latency (we test the tool layer assuming local store is authoritative; the iCloud round-trip is treated as opaque).

**Calendar is the tracer-bullet surface** (per §5.1) — its tests are also our first end-to-end smoke check that the new XPC IPC, Sparkle update, and notarization pipelines all work.

### 3.3 Reminders

**Donor(s):** mcp-server-apple-events (MIT — richest Reminders surface in the field, including geofenced alarms, full recurrence, subtask handling, tag extraction), iMCP (MIT — base scaffolding), icloud-mcp-adamzaidi (MIT — JXA fallback rationale for iCloud-broken VTODO).
**Effort:** M (weeks).
**Risk:** low.
**Target version:** v1.0 base, v1.1 extensions.

#### Library/protocol choice and rationale

**EventKit (`EKReminder`), native, with two intentional escape hatches.**

Same EventKit framework as Calendar; reminders are a separate access surface (`EKEntityType.reminder`) but the same `EKEventStore`. We keep iMCP's pattern of requesting reminders access independently from calendars access — users grant one without the other.

Two known weaknesses of EventKit Reminders, with our designed-in mitigations:

1. **Cross-source moves return error -3002.** Moving a reminder from an iCloud list to a "On My Mac" list (or vice versa) fails. mcp-server-apple-events handles this by falling back to AppleScript Reminders for the move operation only. We do the same — `reminders_move_to_list` detects the cross-source case and routes to the `AppleScriptRunner` actor.
2. **iCloud's CalDAV VTODO is broken.** Adamzaidi documented this — iCloud's CalDAV server returns malformed VTODO responses, so headless CalDAV-Reminders doesn't work. For headless operation (v2.1), we punt: Reminders only works when Reminders.app is installed and configured. Document the limitation.

**Subtask strategy** — apple-events stores subtasks inside the notes field between `---SUBTASKS---` markers. We **do not** replicate that. It corrupts external writers. Instead:

- EventKit gained native subtask support (`EKReminder.parent` / `subTasks`) in macOS 14.4. Use that as the primary path.
- For older macOS or when EventKit lies about subtask support, we maintain a parallel SQLite table at `~/Library/Application Support/com.oliverames.applecore/reminder-extensions.sqlite` keyed on `(account_id, calendar_item_id)`. Stores subtask hierarchy, our own tag set, and any other metadata EventKit doesn't expose. Synced via JXA on first read of a list to pick up subtasks created in Reminders.app.

**Tags**: same parallel-table approach. We extract `#tag` from titles/notes for read but never modify the user's note body. Persist to our SQLite. On write, the user supplies `tags: [String]`; we store them in our table and *also* mirror as `#tag` tokens at the end of the title (separated by ` ` from the title body). This way Reminders.app's UI shows tags, but our index is authoritative.

#### Authentication & credentials

**No credentials required.** Same story as Calendar — reminders accounts come from System Settings.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Reminders Full Access** | First `EKEventStore.requestFullAccessToReminders()` | "Apple Core would like full access to your reminders" | Read/write tools fail with typed error. |
| **Apple Events → Reminders.app** | First cross-source move (AppleScript fallback) | "Apple Core wants permission to control Reminders" | Cross-source move fails with typed error directing user to System Settings → Privacy & Security → Automation. |

**Info.plist usage strings**:

```xml
<key>NSRemindersUsageDescription</key>
<string>Apple Core reads and creates reminders when you ask Claude to manage your tasks.</string>
<key>NSRemindersFullAccessUsageDescription</key>
<string>Apple Core needs full access to read existing reminders and create new ones at your request.</string>
<key>NSRemindersWriteOnlyAccessUsageDescription</key>
<string>Apple Core creates reminders when you ask Claude to add a task.</string>
```

**Entitlement**: `com.apple.security.personal-information.reminders` (already in iMCP's entitlement file).

#### Data model

```swift
struct ReminderList: Codable, Sendable, Identifiable {
    let id: String                // EKCalendar.calendarIdentifier (Reminders lists are EKCalendars)
    let title: String
    let sourceId: String
    let color: String             // hex
    let allowsModifications: Bool
}

struct Reminder: Codable, Sendable, Identifiable {
    let id: String                // EKReminder.calendarItemIdentifier
    let listId: String
    let title: String
    let notes: String?
    let priority: Priority        // .none, .low, .medium, .high
    let isCompleted: Bool
    let completionDate: Date?
    let dueDate: ScheduledDate?   // EKReminder uses date components, not Date — we expose both
    let startDate: ScheduledDate?
    let alarms: [Alarm]           // same Alarm type as Calendar
    let recurrenceRules: [RecurrenceRule]
    let url: URL?
    let parentId: String?         // for native subtasks
    let tags: [String]            // extracted from title or our own table
}

enum Priority: String, Codable, Sendable { case none, low, medium, high }

struct ScheduledDate: Codable, Sendable {
    let date: Date                // best-effort materialized date
    let components: DateComponents  // raw EventKit date components
    let timeZone: String?
}

struct ReminderInput: Codable, Sendable {
    let listId: String?
    let title: String
    let notes: String?
    let priority: Priority?
    let dueDate: ScheduledDate?
    let startDate: ScheduledDate?
    let alarms: [Alarm]?
    let recurrenceRules: [RecurrenceRule]?
    let url: URL?
    let parentId: String?         // for creating a subtask
    let tags: [String]?
    let initialSubtasks: [String]?  // titles of subtasks to create alongside
}
```

#### MCP tool inventory

- `reminders_lists(action) -> ...`
  - `read() -> [ReminderList]`.

- `reminders_tasks(action, ...) -> ...` — multiplexed.
  - `read(list_id?, completed=false, due_before?, due_after?, tag?, priority?, query?, limit=100) -> [Reminder]`.
  - `get(id) -> Reminder`.
  - `create(reminder_input) -> Reminder`.
  - `update(id, reminder_input) -> Reminder`.
  - `complete(id, completed=true) -> Reminder`.
  - `delete(id) -> {deleted: Bool}` — destructive.
  - `move_to_list(id, target_list_id) -> Reminder` — destructive in source. Routes to AppleScript fallback for cross-source.

- `reminders_subtasks(action, ...) -> ...`
  - `read(parent_id) -> [Reminder]`.
  - `create(parent_id, title, notes?) -> Reminder`.
  - `toggle(id, completed) -> Reminder`.
  - `reorder(parent_id, ordered_ids: [String]) -> [Reminder]`.

- `reminders_tags(action, ...) -> ...` — read-only utility.
  - `list(list_id?) -> [{tag: String, count: Int}]`.
  - `find(tag, list_id?) -> [Reminder]`.

#### Edge cases & gotchas

1. **Date components vs. Date**: EventKit reminders are date-component-based (`DateComponents` with year/month/day/hour/minute), not `Date`. A reminder due "tomorrow" has no specific time-zone-stamped instant; it's "tomorrow in the current calendar". We expose both: the `components` for round-trip fidelity, the materialized `Date` for convenience.
2. **`completionDate` as a side-channel for ordering**: when `isCompleted=true`, the completion timestamp orders the completed-list view. Our `complete` action sets this; updates that change `isCompleted` from true to false clear it.
3. **Recurring reminders**: when completed, a recurring reminder spawns the next occurrence and marks itself completed. EventKit handles this automatically; we just expose the resulting state.
4. **Lists in Reminders.app's UI vs. EKCalendar**: Reminders lists are `EKCalendar` objects with `allowedEntityTypes = .reminder`. Same identifier scheme as Calendar.
5. **iCloud Reminders' "Smart Lists"** (Today, Scheduled, Flagged, Assigned to Me) are not real lists; they're predicate-based views in Reminders.app. We don't expose them as `ReminderList`. Instead, our `reminders_tasks/read` filters serve the same use cases (`due_before: today`, etc.).
6. **`structuredLocation` on alarms** with proximity (geofence) is an EventKit feature — we expose, but iCloud sync of geofenced alarms across devices is unreliable historically; document.
7. **Subtask depth**: EventKit allows arbitrary depth, but Reminders.app UI flattens beyond 1 level. We expose the full tree but warn in tool output if depth >2.
8. **Native subtask availability check**: `EKReminder.subTasks` may be unavailable on macOS <14.4. Detect with `if #available` + fall back to our SQLite table.
9. **Initial-subtasks atomicity**: when `create` is called with `initialSubtasks: [...]`, we create the parent first, then subtasks. If a subtask creation fails mid-way, we surface a partial-success result rather than rolling back — partial creation is a more recoverable state than nothing.

#### Performance budget

| Operation | Target |
|---|---|
| `reminders_lists/read` | <30 ms |
| `reminders_tasks/read` (default list, <100 reminders) | <100 ms |
| `reminders_tasks/read` (all lists, query, ~1000 reminders) | <500 ms |
| `reminders_tasks/create` | <100 ms (local) / <500 ms (iCloud) |
| `reminders_tasks/move_to_list` (same source) | <100 ms |
| `reminders_tasks/move_to_list` (cross-source AppleScript fallback) | <2 s |

#### Testing strategy

**Unit tests**: input encoder/decoder, tag extraction, subtask materialization, AppleScript-fallback routing logic, ReminderInput validation.

**Integration tests** (gated): dedicated `apple-mcp-test-reminders` list on a test account; CRUD cycle; native-subtask round-trip; cross-source move triggers AppleScript path verifiable via mocked AppleScriptRunner that records the script body.

**Mocks**: `MockEventStore` reused from Calendar tests, extended with reminders entity coverage. `RecordingAppleScriptRunner` for verifying the fallback script content without actually sending Apple Events.

**What's not testable without a real account**: iCloud sync conflict resolution behavior; geofenced-alarm trigger reliability.

### 3.4 Contacts

**Donor(s):** iMCP (MIT — base scaffolding with `CNContactStore`), icloud-mcp-adamzaidi (MIT — CardDAV write paths for headless mode in v2.1).
**Effort:** S (days).
**Risk:** low.
**Target version:** v1.0.

#### Library/protocol choice and rationale

**Contacts.framework (`CNContactStore`), native.** Already in iMCP. Same trade-off shape as Calendar: native is faster, simpler, and covers all locally-configured contact sources (iCloud, Google, Exchange, On My Mac) uniformly through a single API.

We extend iMCP's existing read+search to add update + delete + create-from-vCard, plus a richer field surface (postal addresses, social profiles, instant-message handles, dates beyond birthday).

**vCard handling**: `CNContactVCardSerialization` ships in Foundation. Use it for both import (`vCard string → CNContact`) and export (`CNContact → vCard 4.0 string`). No third-party parser needed.

**Why not CardDAV directly for v1.0**: same headless-mode reasoning as Calendar — defer to v2.1 when we add iCloud Contacts via CardDAV against `contacts.icloud.com` for the no-Contacts.app case.

#### Authentication & credentials

**No credentials required for native path.**

CardDAV path (v2.1) will reuse the same Keychain-stored app-specific password as Mail/Calendar. Specifically: a `CardDAVKeychainItem` at `kSecClassInternetPassword` with `server = "contacts.icloud.com"`.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Contacts access** | First `CNContactStore.requestAccess(for: .contacts)` | "Apple Core would like to access your contacts" | All Contacts tools fail with typed error. |

**Info.plist usage strings**:

```xml
<key>NSContactsUsageDescription</key>
<string>Apple Core reads, searches, and updates your contacts when you ask Claude to look up someone or save a new card.</string>
```

**Entitlement**: `com.apple.security.personal-information.contacts`.

#### Data model

```swift
struct Contact: Codable, Sendable, Identifiable {
    let id: String                // CNContact.identifier
    let givenName: String
    let middleName: String
    let familyName: String
    let nickname: String
    let organization: String
    let department: String
    let jobTitle: String
    let phoneNumbers: [LabeledValue<PhoneNumber>]
    let emailAddresses: [LabeledValue<String>]
    let postalAddresses: [LabeledValue<PostalAddress>]
    let urlAddresses: [LabeledValue<String>]
    let socialProfiles: [LabeledValue<SocialProfile>]
    let instantMessageAddresses: [LabeledValue<InstantMessage>]
    let dates: [LabeledValue<DateComponents>]   // birthday + custom dates
    let relations: [LabeledValue<String>]       // "spouse", "child", etc.
    let notes: String?                          // requires NSContactsUsageDescription
    let imageDataAvailable: Bool                // we don't return image bytes by default — too big
}

struct LabeledValue<T: Codable & Sendable>: Codable, Sendable {
    let label: String?            // "_$!<Home>!$_" → normalized to "home"
    let value: T
}

struct PhoneNumber: Codable, Sendable {
    let raw: String               // as user typed
    let normalized: String        // E.164 best-effort: "+14155551234"
}

struct PostalAddress: Codable, Sendable {
    let street: String
    let city: String
    let state: String
    let postalCode: String
    let country: String
    let isoCountryCode: String
}

struct SocialProfile: Codable, Sendable {
    let service: String           // "twitter", "linkedin", "github", ...
    let username: String
    let urlString: String?
}

struct InstantMessage: Codable, Sendable {
    let service: String
    let username: String
}

struct ContactInput: Codable, Sendable {
    // Same fields as Contact, all optional.
    // For update: only set fields are updated. Use null literal `value: null` to clear a field.
    // For create: required = at least one of givenName, familyName, organization.
    ...
}
```

`Contact` JSON-LD-encodes as Schema.org `Person` via `Ontology` (already in iMCP).

**Phone-number normalization**: lift dhravya/super's helper. Return both raw and normalized forms. The normalized form is best-effort E.164: parse with `PhoneNumberKit` (a maintained Swift wrapper around libphonenumber, MIT) — *or* hand-roll for North American numbers and degrade to raw for everything else. Decision: pull `PhoneNumberKit` in v1.0; the matching workflows it enables (fuzzy phone search, iMessage-buddy resolution) are worth one well-maintained dep.

**Label normalization**: Apple's `_$!<Home>!$_` etc. normalized to lowercase strings (`"home"`, `"work"`, `"mobile"`, `"main"`, `"other"`). Custom labels pass through unchanged. We round-trip both ways on write.

#### MCP tool inventory

- `contacts_search(query, fields?, limit=20) -> [Contact]` — read-only.
  - `query`: matches against name, email, phone, organization. Single-token AND match.
  - `fields`: optional restrict to which fields are returned (e.g., `["name", "email"]` for slim payloads).

- `contacts_get(id) -> Contact` — read-only.
- `contacts_me() -> Contact?` — returns the user's "me" card if set in Contacts.app.
- `contacts_create(input: ContactInput) -> Contact`.
- `contacts_update(id, input: ContactInput) -> Contact`.
- `contacts_delete(id) -> {deleted: Bool}` — destructive.
- `contacts_lookup_phone(phone) -> Contact?` — read-only convenience for iMessage workflows; matches against normalized E.164.
- `contacts_import_vcard(vcard_string, target_group_id?) -> [Contact]` — destructive (creates).
- `contacts_export_vcard(ids: [String]) -> {vcard: String}` — read-only.

Groups (smart and manual) deferred to v1.1.

#### Edge cases & gotchas

1. **The "me" card** is a per-user setting that may not be set. `contacts_me()` returns `null` if not configured; callers should not assume it exists.
2. **Image bytes** can be megabytes. We expose `imageDataAvailable: Bool` but don't include bytes by default; a separate `contacts_get_image(id)` tool returns base64 data on demand.
3. **Notes field** requires the `NSContactsUsageDescription` to mention notes specifically on macOS 14+; otherwise it's nil even with full Contacts access. Our string already mentions "look up someone" which generally suffices, but we monitor for empty notes when populated-elsewhere is expected.
4. **Read-only sources**: Exchange and Google contacts in some configurations are read-only via Contacts.framework. Updates fail with `CNError.policyViolation`. Surface as a typed error, not a generic failure.
5. **vCard 4.0 vs 3.0**: Apple's serializer emits 3.0 by default for legacy compat. We use 4.0 (`.v4_0`) for richer field coverage.
6. **Custom labels**: round-trip preserves the `_$!<Custom>!$_` form so updates don't lose user-specified labels.
7. **Identifier stability**: CNContact identifiers are stable across app launches but may change after iCloud sync conflicts. Tools that store an ID for later use should refresh against the live store.

#### Performance budget

| Operation | Target |
|---|---|
| `contacts_search` (5,000-contact store, 20 results) | <100 ms |
| `contacts_get` | <20 ms |
| `contacts_create` | <100 ms |
| `contacts_lookup_phone` (with normalization) | <50 ms |
| `contacts_export_vcard` (10 contacts) | <50 ms |

#### Testing strategy

**Unit tests**: vCard round-trip, phone normalization, label normalization, ContactInput validation.

**Integration tests** (gated): create a `apple-mcp-test` group on a test account, exercise CRUD, then delete the group. The group container makes cleanup trivial.

**Mocks**: `MockContactStore` protocol-conforming fake.

**What's not testable without a real account**: cross-account sync conflicts, group-membership behavior across iCloud/Exchange.

### 3.5 Notes

**Donor(s):** apple-mcp-dhravya/supermemoryai (MIT — AppleScript create+search), icloud-mcp-mrgo2 (MIT — JXA-with-JSON pattern + AppleScript-runner shape).
**Effort:** M (weeks).
**Risk:** medium-high. Notes has no native macOS API. Everything is AppleScript or JXA. Update is a documented gap none of the donor repos solved well.
**Target version:** v1.1 (read+create), v2.0 (update).

#### Library/protocol choice and rationale

**AppleScript / JXA via the shared `AppleScriptRunner` actor.**

There is no public Notes API on macOS. The options are:

- **AppleScript via `tell application "Notes"`**: works for read, search, create. Update via `set body of note to ...` works but rewrites the entire body and loses formatting if the new body isn't HTML.
- **JXA (`Application('Notes')`) — same surface, JSON-friendly**: cleaner property access for reads. For complex object graphs, output `JSON.stringify(...)` to stdout and parse on the Swift side.
- **Reading the SQLite store at `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`**: technically possible. Schema is undocumented, encrypted notes are not readable without the user's password, and Apple can change the schema at any release. **We don't.** The cost in maintenance dwarfs the speed win.

The choice is JXA where the shape benefits (reading note metadata into structured JSON), AppleScript for writes. Both go through the shared `AppleScriptRunner` actor (described in §1, summarized here):

```swift
actor AppleScriptRunner {
    enum Language { case applescript, jxa }
    enum AppleScriptError: Error {
        case permissionDenied(app: String)    // -1743
        case appNotRunning(app: String)
        case notFound(detail: String)
        case timeout
        case unknown(stderr: String, exitCode: Int)
    }
    func run(_ language: Language, script: String, timeout: TimeInterval = 30) async throws -> String
    func runJSON<T: Decodable>(_ language: Language, script: String, as: T.Type, timeout: TimeInterval = 30) async throws -> T
}
```

The runner spawns `osascript -l <lang>` with the script body on **stdin** (per mrgo2's pattern, avoiding argv length limits). It captures stdout/stderr separately. Stderr is regex-matched to map known patterns to typed errors (the `1743` -> `permissionDenied` mapping is the key one for TCC). Scripts have a hard timeout — Notes operations sometimes hang Apple Events indefinitely.

**Update strategy** (v2.0):

The hard problem with note update is concurrent edits. If the user has the note open in Notes.app and we replace the body, we may clobber unsaved changes. Our approach:

1. On `notes_update(id, ...)`: read the current body via JXA; compute SHA-256 hash; if the caller passed an `expected_hash` and it doesn't match, fail with `notes_update_conflict`.
2. If `expected_hash` matches (or wasn't provided), perform the AppleScript `set body` write.
3. Return the new hash so callers can chain updates.

This is *optimistic concurrency control* — the LLM has to opt into safety by reading first and supplying the hash. Without it, last-writer-wins, which is what every other AppleScript Notes tool does silently.

#### Authentication & credentials

**No credentials.** Notes accounts are configured by the user; we read whatever Notes.app sees.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Apple Events → Notes.app** | First AppleScript/JXA call | "Apple Core wants permission to control Notes" | All Notes tools fail with typed error pointing at Privacy & Security → Automation. |

**Info.plist usage strings**:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Apple Core uses AppleScript to read, search, create, and update notes when you ask Claude to manage your Notes.</string>
```

(This string is shared with Mail's AppleScript path and any other AppleScript-driven surface. Single key; comprehensive description.)

#### Data model

```swift
struct NoteFolder: Codable, Sendable, Identifiable {
    let id: String                // AppleScript "id" property of folder
    let name: String              // "Notes", "Recipes", "Shared with me"
    let accountName: String       // "iCloud", "On My Mac"
    let parentId: String?         // for nested folders
    let noteCount: Int            // hint, not authoritative
}

struct NoteSummary: Codable, Sendable, Identifiable {
    let id: String
    let folderId: String
    let title: String             // first line of body, derived
    let snippet: String           // first 200 chars of plain-text body
    let creationDate: Date
    let modificationDate: Date
    let isLocked: Bool            // encrypted notes
    let attachmentCount: Int
}

struct Note: Codable, Sendable, Identifiable {
    let id: String
    let summary: NoteSummary
    let bodyHTML: String          // empty if isLocked
    let bodyText: String          // SwiftSoup-derived plain text
    let attachments: [NoteAttachment]
    let bodyHash: String          // SHA-256 of bodyHTML for optimistic concurrency
}

struct NoteAttachment: Codable, Sendable, Identifiable {
    let id: String
    let filename: String?
    let mimeType: String?
    let size: Int?
    let kind: AttachmentKind      // .image, .pdf, .audio, .scan, .drawing, .other
}

struct NoteInput: Codable, Sendable {
    let folderId: String?
    let title: String             // becomes the first <h1> of HTML body
    let bodyText: String?         // mutually exclusive with bodyHTML
    let bodyHTML: String?
    let expectedHash: String?     // for update only; optional
}
```

**HTML body composition for create/update**: Notes treats the first `<h1>` (or first line) as the title. Our composer wraps user-supplied plain-text bodies in safe HTML: `<h1>{escaped title}</h1><div>{escaped body with <br> for newlines}</div>`. Tags and AppleScript-injection vectors (quotes, backslashes, curly quotes) are escaped at HTML and AppleScript-string layers — both, because the AppleScript value is a literal HTML string.

**Locked notes**: Notes.app encrypts with a per-user password. We surface `isLocked: true` and never attempt to unlock; that's a user UI action.

#### MCP tool inventory

- `notes_folders(action) -> ...`
  - `read() -> [NoteFolder]`.

- `notes(action, ...) -> ...` — multiplexed.
  - `list(folder_id?, modified_after?, limit=50) -> [NoteSummary]` — read-only.
  - `search(query, folder_id?, scope="all", limit=20) -> [NoteSummary]` — read-only.
    - `scope`: `"all" | "title" | "body"`.
  - `get(id) -> Note` — read-only.
  - `create(input: NoteInput) -> Note`.
  - `update(id, input: NoteInput) -> Note` — destructive (replaces body). v2.0.
  - `delete(id) -> {deleted: Bool}` — destructive.
  - `move(id, target_folder_id) -> Note` — destructive in source.

- `notes_attachments(action, ...) -> ...`
  - `list(note_id) -> [NoteAttachment]`.
  - `get(note_id, attachment_id) -> {kind, filename, mime_type, content: Base64String?}` — base64 for images, pdfs; metadata-only for drawings/scans we can't extract.

#### Edge cases & gotchas

1. **iCloud-vs-On-My-Mac default**: when creating a note without a folder, AppleScript Notes defaults to the first account in the sidebar order — usually iCloud. We surface the actual destination folder in the result so the model can confirm.
2. **HTML escaping double-up**: AppleScript strings need their own escaping (quotes, backslashes), and HTML strings need theirs (`&`, `<`, `>`, `"`, `'`). We escape *HTML first*, then wrap the result in an AppleScript string with separate escaping. Test rigorously with property-based tests over Unicode + quotes + brackets.
3. **Encrypted (locked) notes** never have body content available, even after the user unlocks in Notes.app — Notes only briefly decrypts in memory. We always surface metadata and `isLocked: true`; reads return body fields empty.
4. **Notes with attachments fail HTML-only re-write**: if a note contains a PDF attachment and we set body to plain HTML, the attachment may be lost. Our update path warns when the existing note has attachments and refuses to write unless `force_drop_attachments: true` is passed.
5. **Folder hierarchy traversal**: Notes folders can nest. JXA returns flat `Application('Notes').folders()`; we walk the parent property and reconstruct the tree.
6. **"Shared with me" notes**: shared notes appear in a special folder; writes against them require the user to be the owner. We expose them as read-only by default and document.
7. **Title-from-first-line heuristic**: Notes.app derives the title from the first line of the body, ignoring leading whitespace and markdown-y `#` markers. Our `title` field on `NoteSummary` does the same derivation, never the AppleScript "name" property (which lies on iCloud notes).
8. **Modification date isn't always updated** when adding an attachment — Notes considers the body unchanged. Document the heuristic.
9. **Concurrent edit detection** is best-effort. If the user types while we're computing the hash, we may not see their edit. The `expected_hash` is *advisory*; the model can pass `null` to force-write.

#### Performance budget

| Operation | Target |
|---|---|
| `notes_folders/read` | <500 ms |
| `notes/list` (200-note folder) | <2 s |
| `notes/search` (full-store, ~5,000 notes) | <5 s |
| `notes/get` | <500 ms |
| `notes/create` | <1 s |
| `notes/update` | <1.5 s (read for hash + write) |

These budgets are looser than other surfaces because every operation is an AppleScript IPC round-trip. AppleScript Notes is genuinely slow; nothing fixes this short of reading the SQLite directly, which we declined.

#### Testing strategy

**Unit tests**: HTML/AppleScript escaping, body-hash computation, NoteInput validation, folder-tree reconstruction logic, plain-text-from-HTML extraction.

**Integration tests** (gated): create a dedicated `apple-mcp-test` folder on a test account; CRUD; verify hash-based conflict detection by interleaving an out-of-band edit; clean up folder. Slower than other surfaces' integration tests because of the AppleScript latency.

**Mocks**: `RecordingAppleScriptRunner` records every script body and returns canned responses, allowing us to test that we send well-formed scripts without actually invoking osascript.

**What's not testable without a real account**: encrypted-note unlock behavior; Notes' "Shared with me" sync; iCloud Notes sync conflicts.

### 3.6 Messages

**Donor(s):** iMCP (MIT — `madrid` typedstream decoder integration), apple-mcp-dhravya/supermemoryai (MIT — phone-number normalization, hybrid SQLite-read + AppleScript-send pattern).
**Effort:** S read (already in iMCP) + S send (~days).
**Risk:** low.
**Target version:** v1.0 read, v1.1 send.

#### Library/protocol choice and rationale

**Hybrid: direct SQLite read for receive/search, AppleScript for send.**

This split is the single most important Messages design decision and it's already correct in iMCP — we keep it.

**Read & search via `~/Library/Messages/chat.db` (SQLite)**:

- 10-100× faster than scripting Messages.app.
- Schema is undocumented but stable across multiple macOS versions. We treat it as private API and pin a schema-version probe.
- Body text is stored in a typedstream-encoded `attributedBody` blob in modern macOS — plain `text` column may be nil. The `madrid` package (Mattt's, MIT) decodes the typedstream format. **Already a dep in iMCP.**
- Direct file open at `~/Library/Messages/chat.db` (unsandboxed v1, FDA-gated). No security-scoped bookmark needed.

**Send via AppleScript Messages**:

- chat.db is *write-locked* by Messages.app. Inserting a row to send a message would corrupt the store. Don't try.
- AppleScript `tell application "Messages" to send "..." to buddy "..."` is the supported path. Slower (1-2s per send) but the only safe one.

**Why not iMessage's private framework (`IMCore`)**: undocumented, every macOS update breaks signatures, App Store rejects, and the security implications are nontrivial. Pure no-go.

**Why not Apple Push Notification network sends**: requires being a registered iMessage client identity, which only Messages.app has on this Mac. Architectural non-starter.

#### Authentication & credentials

**No credentials.** Messages is signed in via the user's Apple ID at the OS level; we read what's there.

**chat.db access** (unsandboxed v1, per §0 decision 3): open `~/Library/Messages/chat.db` directly via `Database(fileURL:)`. Full Disk Access (TCC) is the only gate. Drop iMCP's `NSOpenPanel` + security-scoped bookmark dance entirely — that pattern only existed because iMCP was sandboxed.

If a future major version re-sandboxes for Mac App Store, the security-scoped bookmark + `NSOpenPanel` pattern from iMCP returns. Documented in iMCP's `MessageService` for that hypothetical.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Full Disk Access** | First chat.db read | macOS does not auto-prompt for FDA — the user grants manually in System Settings → Privacy & Security → Full Disk Access. The .app's doctor surfaces a guided dialog directing them there. | Without FDA, all Messages read tools fail with typed `messagesFullDiskAccessRequired` error. |
| **Apple Events → Messages.app** | First send | "Apple Core wants permission to control Messages" | Send fails with typed error pointing at Privacy & Security → Automation. |

**Info.plist usage strings**:

```xml
<key>NSAppleEventsUsageDescription</key>
<string>Apple Core uses AppleScript to send messages from Messages.app at your request.</string>
```

(Shared with Notes/Mail; one comprehensive description.)

**Entitlements** for sandbox compatibility (already in iMCP):

```xml
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/Users/USERNAME/Library/Messages/</string>
</array>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

#### Data model

```swift
struct MessagesHandle: Codable, Sendable {
    let id: Int64                 // chat.db rowid in `handle` table
    let address: String           // "+14155551234" or "oliver@icloud.com"
    let normalizedAddress: String // E.164 for phones, lowercased for emails
    let service: HandleService    // .iMessage, .SMS, .RCS
    let contactName: String?      // resolved via Contacts.framework if present
}

enum HandleService: String, Codable, Sendable {
    case iMessage = "iMessage"
    case SMS
    case RCS
}

struct Chat: Codable, Sendable, Identifiable {
    let id: Int64                 // chat.db rowid in `chat` table
    let guid: String              // chat.db GUID
    let displayName: String?      // group chat name
    let participants: [MessagesHandle]
    let isGroup: Bool
    let lastMessageDate: Date?
    let lastMessageSnippet: String?
    let unreadCount: Int
}

struct Message: Codable, Sendable, Identifiable {
    let id: Int64                 // chat.db rowid in `message` table
    let guid: String
    let chatId: Int64
    let handleId: Int64?          // nil if isFromMe
    let isFromMe: Bool
    let date: Date                // converted from Apple's Mac absolute time
    let dateRead: Date?
    let dateDelivered: Date?
    let text: String              // decoded from typedstream attributedBody if needed
    let isRead: Bool
    let attachments: [MessagesAttachment]
    let isReply: Bool
    let replyToGuid: String?      // for threaded reactions/replies
    let reactionType: ReactionType?  // for tap-back reactions
}

enum ReactionType: String, Codable, Sendable {
    case love, like, dislike, laugh, emphasize, question, removed
}

struct MessagesAttachment: Codable, Sendable, Identifiable {
    let id: Int64
    let guid: String
    let filename: String
    let mimeType: String?
    let transferState: TransferState
    let totalBytes: Int64
}

enum TransferState: String, Codable, Sendable {
    case waitingToBeFetched, fetching, fetched, failed
}
```

`Chat` JSON-LD-encodes as Schema.org `Conversation` via `Ontology` (already in iMCP).

#### MCP tool inventory

- `messages_search(query?, handle_address?, before?, after?, only_unread=false, limit=50, offset=0) -> {results: [Message], total: Int}` — read-only.
  - `query`: matches against decoded message text.
  - `handle_address`: limit to a specific buddy.

- `messages_recent_chats(limit=20) -> [Chat]` — read-only. Sorted by `lastMessageDate` descending.

- `messages_get_chat(id, message_limit=50, message_offset=0) -> {chat: Chat, messages: [Message]}` — read-only.

- `messages_get_thread(message_id, depth=2) -> [Message]` — read-only. Walks `replyToGuid` graph.

- `messages_unread_count(per_chat=false) -> {total: Int, per_chat?: [{chat_id: Int64, unread: Int}]}` — read-only.

- `messages_get_attachment(attachment_id) -> {filename: String, mime_type: String, content: Base64String}` — read-only; resolves `~/Library/Messages/Attachments/...` and returns base64.

- `messages_send(to: [String], text: String, service?: "iMessage" | "SMS") -> {sent: Bool, message_guid: String?}` — destructive. (v1.1.)
  - `to`: array of phone numbers or Apple IDs. We resolve via phone-number normalization + buddy lookup.
  - `service`: defaults to iMessage; falls back to SMS if iMessage isn't available for the recipient (Messages.app handles this automatically).

- `messages_lookup_buddy(address) -> {handle?: MessagesHandle, normalized_addresses: [String]}` — read-only convenience for "is this number on iMessage?"

#### Edge cases & gotchas

1. **Apple Mac absolute time**: chat.db stores dates as nanoseconds since 2001-01-01 UTC (`CFAbsoluteTime`). Convert with `Date(timeIntervalSinceReferenceDate: timestamp / 1_000_000_000)`. Older messages used seconds, not nanoseconds — detect by magnitude.
2. **`text` column is nil on modern macOS**; body lives in `attributedBody` as typedstream. Always try `attributedBody` first via `madrid`, fall back to `text`.
3. **Phone-number matching**: when sending to `+14155551234`, Messages may have the buddy stored as `+1 (415) 555-1234` or `+14155551234@imessage` or `4155551234`. Try all candidates produced by the phone-number normalizer; on the first one that resolves to an actual buddy, send.
4. **Group MMS chats** have multiple `handle` rows linked via `chat_handle_join`. Display name is the group's `display_name` column or, if nil, comma-joined participants.
5. **Tap-back reactions** are full message rows with `associated_message_type` indicating reaction kind. Surface as `reactionType` on the reacting message; don't filter them from results unless asked.
6. **Stickers and rich link previews** appear as messages with empty body and an attachment. Surface attachment metadata; the text snippet falls back to the attachment kind ("[Sticker]", "[Link]").
7. **Read receipts privacy**: surfacing `dateRead` reveals whether the user has read receipts on. We expose it (it's the truth) but document.
8. **Send via SMS forwarding** requires the user has SMS forwarding configured between their iPhone and Mac. If not, the send falls back to iMessage-only and SMS recipients fail. Surface a typed error.
9. **`chat.db` lock contention**: we open with `SQLITE_OPEN_READONLY` and `SQLITE_OPEN_NOMUTEX` to avoid blocking Messages.app. WAL mode means our reads see a consistent snapshot.
10. **Attachment files** at `~/Library/Messages/Attachments/<x>/<y>/<guid>/<filename>` may be `.icloud` placeholders if the user offloads. Detect zero-byte files with the `.icloud` extension and surface `transferState: .waitingToBeFetched`.

#### Performance budget

| Operation | Target |
|---|---|
| `messages_recent_chats` | <100 ms |
| `messages_search` (1k-message scope) | <200 ms |
| `messages_search` (full DB ~50k messages) | <2 s |
| `messages_get_chat` (50 messages) | <100 ms |
| `messages_get_thread` (depth 2) | <50 ms |
| `messages_send` (iMessage round-trip) | <2 s |
| `messages_get_attachment` (100 KB image) | <50 ms |

#### Testing strategy

**Unit tests**: typedstream decoder integration with `madrid` against fixture blobs; Mac-absolute-time conversion; phone-number candidate generation; AppleScript escaping for send.

**Integration tests** (gated, manual-trigger only): require a real chat.db. We can't write to chat.db in tests (read-locked), so send tests verify by sending a message to ourselves and reading it back via the SQLite path — checking the round-trip works.

**Fixtures**: a redacted `chat.db` snapshot with synthetic conversations under `Tests/MessagesServiceTests/Fixtures/`. We hand-craft this; do not include real user data.

**What's not testable without a real account**: real iMessage delivery; SMS-forwarding fallback behavior; group MMS interactions.

### 3.7 Maps

**Donor(s):** iMCP (MIT — full MapKit coverage including search, directions, ETA, static map render), apple-mcp-dhravya/supermemoryai (MIT — JXA Maps for Guides, which MapKit doesn't expose).
**Effort:** S (already mostly in iMCP).
**Risk:** low.
**Target version:** v1.0.

#### Library/protocol choice and rationale

**MapKit, native, in-process.** No external Apple Maps API; no online service to call. MapKit runs locally and includes:

- `MKLocalSearch` and `MKLocalSearchCompleter` for POI search.
- `MKDirections` for routing (auto/walk/transit).
- `MKMapSnapshotter` for static PNG rendering.
- `CLGeocoder` for forward/reverse geocoding (already in iMCP under Location).

**Why not Apple Maps Server API**: requires a paid token, has rate limits, and works against the same data as MapKit. MapKit is free, on-device, and has no quota. Use it.

**Why JXA for Guides**: Apple Maps Guides (saved POI collections) have no MapKit API. Reading and writing them requires JXA against Maps.app. We add this as a v1.1 extension.

#### Authentication & credentials

**No credentials.**

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Network** (MapKit downloads tiles) | First search/directions | None — implicit | Network errors surface as typed `mapsNetworkError`. |
| **Apple Events → Maps.app** (Guides only, v1.1) | First Guides JXA call | "Apple Core wants permission to control Maps" | Guides tools fail; non-Guides tools unaffected. |

**Info.plist usage strings**: none required for MapKit native paths.

**Entitlement**: `com.apple.security.network.client` (already in iMCP).

#### Data model

```swift
struct MapItem: Codable, Sendable, Identifiable {
    let id: String                // composite of name + coordinates (MKMapItem doesn't have stable id)
    let name: String
    let formattedAddress: String?
    let coordinate: Coordinate
    let category: POICategory?    // .restaurant, .gasStation, .park, ...
    let phoneNumber: String?
    let url: URL?
    let timeZone: String?
}

struct Coordinate: Codable, Sendable {
    let latitude: Double
    let longitude: Double
}

enum POICategory: String, Codable, Sendable {
    case airport, amusementPark, aquarium, atm, bakery, bank, beach, brewery
    case cafe, campground, carRental, evCharger, fireStation, fitnessCenter
    case foodMarket, gasStation, hospital, hotel, laundry, library, marina
    case movieTheater, museum, nationalPark, nightlife, park, parking
    case pharmacy, police, postOffice, publicTransport, restaurant, restroom
    case school, stadium, store, theater, university, winery, zoo, other
}

struct Route: Codable, Sendable {
    let name: String?             // "Fastest" or "Avoid Tolls"
    let distanceMeters: Double
    let expectedTravelTimeSeconds: Double
    let transportType: TransportType
    let steps: [RouteStep]
    let polyline: [Coordinate]    // detailed path for rendering
}

enum TransportType: String, Codable, Sendable {
    case automobile, walking, transit, cycling
}

struct RouteStep: Codable, Sendable {
    let instructions: String      // "Turn left onto Market St"
    let distanceMeters: Double
    let coordinate: Coordinate
}

struct MapSnapshot: Codable, Sendable {
    let pngData: Data             // base64-encoded over MCP
    let widthPoints: Int
    let heightPoints: Int
    let centerCoordinate: Coordinate
    let span: MapSpan             // extent of view
}

struct MapSpan: Codable, Sendable {
    let latitudeDelta: Double
    let longitudeDelta: Double
}

struct MapGuide: Codable, Sendable, Identifiable {
    let id: String                // JXA-derived
    let name: String
    let itemCount: Int
}
```

#### MCP tool inventory

- `maps_search(query, near?: Coordinate, radius_meters?, categories?: [POICategory], limit=10) -> [MapItem]` — read-only.
- `maps_directions(from, to, transport_type="automobile", departure_time?, alternates=true) -> [Route]` — read-only. `from`/`to`: `Coordinate | "current_location" | String (address)`.
- `maps_eta(from, to, transport_type="automobile", departure_time?) -> {distance_meters, expected_seconds}` — read-only convenience.
- `maps_explore(near: Coordinate, radius_meters=2000, categories?: [POICategory], limit=20) -> [MapItem]` — read-only. Same as `maps_search` with empty query but kept separate for prompt clarity.
- `maps_static_image(center, span?, width=600, height=400, annotations?: [Coordinate], show_traffic=false, show_buildings=true) -> MapSnapshot` — read-only. PNG rendering via `MKMapSnapshotter`.
- `maps_guides(action, ...) -> ...` — v1.1, JXA-backed.
  - `list() -> [MapGuide]`.
  - `read(id) -> {guide: MapGuide, items: [MapItem]}`.
  - `create(name) -> MapGuide`.
  - `add_item(guide_id, map_item) -> {added: Bool}`.

#### Edge cases & gotchas

1. **`MKLocalSearch` rate limits**: MapKit applies a soft rate limit per process. Bursts are fine; sustained >10 RPS will get throttled. Surface as `mapsRateLimited` error; document.
2. **Geocoding accuracy varies**: addresses outside the US/EU may return coarser results. We surface `accuracy: .pointOfInterest | .address | .area | .country` if possible.
3. **Transit directions** require a transit-supported region; many locations return empty arrays for `.transit` even when other modes work. Surface as empty result, not error.
4. **Static map snapshots are slow first-run** (tile download). Subsequent renders of nearby regions are <500 ms.
5. **Categories are an Apple-defined set**; we expose the subset that's stable across macOS versions. Adding a new POI category requires a rebuild (it's an enum).
6. **Departure-time prediction**: `MKDirectionsRequest.departureDate` for transit affects suggested routes; auto/walk paths are mostly time-independent. Document.
7. **Coordinate validation**: silently invalid coordinates (lat > 90, etc.) crash MapKit's snapshotter. Validate at the tool layer.

#### Performance budget

| Operation | Target |
|---|---|
| `maps_search` | <800 ms |
| `maps_directions` | <1.5 s |
| `maps_eta` | <500 ms |
| `maps_static_image` (cached region) | <500 ms |
| `maps_static_image` (cold) | <2 s |

#### Testing strategy

**Unit tests**: coordinate validation, JSON-LD encoding, polyline encoding/decoding.

**Integration tests** (gated, network-required): a small set of stable searches ("Apple Park", "Times Square") that should always return valid results. Tests that exercise rate limiting are excluded from CI to avoid burning the limit.

**What's not testable without network**: actual MapKit results vary day-to-day as Apple updates POI data; we test schemas not specific values.

### 3.8 Weather

**Donor(s):** iMCP (MIT — full WeatherKit coverage with conditional compilation).
**Effort:** S (already in iMCP).
**Risk:** low.
**Target version:** v1.0 (entitlement-gated).

#### Library/protocol choice and rationale

**WeatherKit (`Weather` framework), native.**

Apple's first-party weather service. Replaced Dark Sky after Apple acquired it. Free quota: 500K calls/month per Apple Developer account; reasonable for our scale.

**Why not third-party services**:

- **OpenWeatherMap, AccuWeather, etc.**: require API keys, rate-limited differently, generally less accurate for hyperlocal forecasts. The user already has WeatherKit on their Mac via system services.
- **Dark Sky**: shut down December 2022. Don't.

**Why conditional**: iMCP gates WeatherKit calls behind `#if WEATHERKIT_AVAILABLE` so unsigned dev builds compile without the entitlement (which requires a paid Apple Developer Program membership). We keep this pattern. Decision pending on §7.8.

**Quota management**: 500K calls/month sounds like a lot but a single user running an LLM in a tight loop can burn it. We apply per-process rate limiting (max 10 RPS) plus a 5-minute response cache keyed on `(lat, lon, kind)` to coalesce repeated queries.

#### Authentication & credentials

**WeatherKit entitlement** is the credential. Provisioning profile must include `com.apple.developer.weatherkit`. No runtime token; the entitlement signature is sufficient.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Network** | First weather call | None | `URLError`-shaped failure surfaced as `weatherNetworkError`. |

**Info.plist usage strings**: none for the user; WeatherKit is a service that doesn't prompt.

**Entitlement**:

```xml
<key>com.apple.developer.weatherkit</key>
<true/>
```

**Conditional compilation**: SwiftPM build setting `-D WEATHERKIT_AVAILABLE` flips on when the entitlement is present in the build's provisioning profile. CI builds without the entitlement compile cleanly with the conditional.

#### Data model

```swift
struct CurrentWeather: Codable, Sendable {
    let location: Coordinate
    let asOf: Date
    let temperature: Measurement   // Celsius and Fahrenheit
    let apparentTemperature: Measurement
    let humidity: Double           // 0.0 to 1.0
    let condition: WeatherCondition
    let conditionDescription: String  // "Partly Cloudy"
    let windSpeed: Measurement     // m/s, mph
    let windDirection: Double      // degrees
    let pressure: Double           // mbar
    let visibility: Double         // meters
    let uvIndex: Int
    let cloudCover: Double         // 0.0 to 1.0
}

struct DailyForecast: Codable, Sendable {
    let day: Date                  // start of day in target zone
    let temperatureHigh: Measurement
    let temperatureLow: Measurement
    let condition: WeatherCondition
    let conditionDescription: String
    let precipitationChance: Double
    let precipitationAmount: Measurement?
    let snowfallAmount: Measurement?
    let sunrise: Date?
    let sunset: Date?
    let moonPhase: MoonPhase
}

struct HourlyForecast: Codable, Sendable {
    let hour: Date
    let temperature: Measurement
    let condition: WeatherCondition
    let precipitationChance: Double
    let windSpeed: Measurement
}

struct MinuteForecast: Codable, Sendable {
    let summary: String           // "Light rain in 5 min"
    let minutes: [{
        let minute: Date
        let precipitationChance: Double
        let precipitationIntensity: Double
    }]
}

enum WeatherCondition: String, Codable, Sendable {
    case clear, mostlyClear, partlyCloudy, mostlyCloudy, cloudy
    case rain, drizzle, heavyRain, snow, heavySnow, sleet, hail
    case thunderstorm, foggy, windy, hot, cold, blizzard
    case other
}

enum MoonPhase: String, Codable, Sendable {
    case new, waxingCrescent, firstQuarter, waxingGibbous
    case full, waningGibbous, lastQuarter, waningCrescent
}

struct Measurement: Codable, Sendable {
    let value: Double
    let unit: String              // "celsius", "mps", "mbar"
    let displayUS: String         // "72°F"
    let displayMetric: String     // "22°C"
}
```

JSON-LD: condition + temperature encode as Schema.org `WeatherForecast` via `Ontology` (already in iMCP).

#### MCP tool inventory

- `weather_current(latitude, longitude) -> CurrentWeather` — read-only.
- `weather_daily(latitude, longitude, days=10) -> [DailyForecast]` — read-only.
- `weather_hourly(latitude, longitude, hours=24) -> [HourlyForecast]` — read-only.
- `weather_minute(latitude, longitude) -> MinuteForecast?` — read-only; returns null if user is outside a minute-forecast region.

Coordinate inputs: accept `(latitude, longitude)` as separate Doubles. We do not accept addresses here — composition with `location_geocode` is the path.

#### Edge cases & gotchas

1. **Minute forecast availability** is regional (US, UK, Ireland, parts of Europe). Outside coverage, returns null.
2. **Apple Privacy & Attribution**: WeatherKit requires us to display "Weather" and the source attribution where the data appears. For an MCP that returns raw data to an LLM, we put the attribution string in every result and document that the LLM is expected to surface it in user-facing summaries. (Trustworthy LLMs will; this is the contractual covering.)
3. **Time zones**: forecasts return dates in UTC; the `daily` tool's `day` field is "start of day in the location's local zone" — we look up the zone via CLGeocoder and convert.
4. **Quota exhaustion**: when WeatherKit returns HTTP 429, we surface a typed `weatherQuotaExceeded` and fall back to cache if a result <1 hour old exists.
5. **Coordinate precision**: very high precision (8+ decimal places) doesn't help — WeatherKit grids data. We round to 4 decimals before query for cache-friendliness.
6. **Quota budgeting per-user vs global**: WeatherKit quota is per Apple Developer account (us), not per user. Heavy use by one user can starve others. v1.0 ships per-process rate limit; if quota becomes an issue, v1.x adds per-user accounting via `UserDefaults`-backed counters.

#### Performance budget

| Operation | Target |
|---|---|
| `weather_current` (cache hit) | <10 ms |
| `weather_current` (cache miss) | <500 ms |
| `weather_daily/10d` | <500 ms |
| `weather_hourly/24h` | <500 ms |
| `weather_minute` | <500 ms |

#### Testing strategy

**Unit tests**: coordinate rounding, cache key generation, attribution string presence in every encoded response.

**Integration tests** (gated, requires entitlement): canned coordinates that should always have weather (Apple Park) tested for non-empty responses.

**Mocks**: `MockWeatherService` protocol-conforming fake; tool-layer tests run against this so they don't burn quota.

**What's not testable**: minute-forecast availability for arbitrary coordinates; quota-exceeded behavior in CI without artificial injection.

### 3.9 Location

**Donor(s):** iMCP (MIT — full Core Location coverage with delegate-to-async bridging).
**Effort:** S (already in iMCP).
**Risk:** low.
**Target version:** v1.0.

#### Library/protocol choice and rationale

**Core Location, native.** `CLLocationManager` with delegate-to-async bridging (iMCP's pattern, kept).

**`requestWhenInUseAuthorization()`** on first request — we do NOT request `requestAlwaysAuthorization` because we don't run in the background and the prompt is more invasive. WhenInUse covers everything our MCP needs.

**Geocoding via `CLGeocoder`**: forward (address → coordinate) and reverse (coordinate → address). Apple's geocoding is rate-limited softly (~50 RPS per app); we don't expect to bump it.

#### Authentication & credentials

**No credentials.**

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Location services** | First `requestLocation()` | "Apple Core would like to use your location" with **Allow While Using App** / **Allow Once** / **Don't Allow** | All location tools fail with typed error directing to System Settings → Privacy & Security → Location Services. |

**Info.plist usage strings** (already in iMCP):

```xml
<key>NSLocationUsageDescription</key>
<string>Apple Core uses your location when you ask Claude about nearby places, weather, or directions.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Apple Core uses your location when you ask Claude about nearby places, weather, or directions.</string>
```

#### Data model

```swift
struct Location: Codable, Sendable {
    let coordinate: Coordinate    // shared with Maps
    let altitude: Double          // meters above sea level
    let horizontalAccuracy: Double  // meters; -1 = invalid
    let verticalAccuracy: Double
    let speed: Double             // m/s; -1 = invalid
    let course: Double            // degrees; -1 = invalid
    let timestamp: Date
    let placemark: Placemark?     // reverse-geocoded if requested
}

struct Placemark: Codable, Sendable {
    let name: String?
    let thoroughfare: String?     // street name
    let subThoroughfare: String?  // street number
    let locality: String?         // city
    let subLocality: String?      // neighborhood
    let administrativeArea: String?  // state/province
    let subAdministrativeArea: String?
    let postalCode: String?
    let country: String?
    let isoCountryCode: String?
    let timeZone: String?
}
```

`Location` JSON-LD-encodes as Schema.org `Place` via `Ontology`.

#### MCP tool inventory

- `location_current(reverse_geocode=true, accuracy="best") -> Location` — read-only.
  - `accuracy`: `"best" | "ten_meters" | "hundred_meters" | "kilometer"`. Coarser is faster and uses less battery.
- `location_geocode(address) -> [Placemark]` — read-only. Multiple results possible.
- `location_reverse_geocode(latitude, longitude) -> Placemark?` — read-only.
- `location_distance(from: Coordinate, to: Coordinate) -> {meters: Double, miles: Double, kilometers: Double}` — read-only utility, no permissions.

#### Edge cases & gotchas

1. **First call cold-start**: `CLLocationManager` may take 5-30 seconds to acquire a fix on a Mac (which has no GPS, only Wi-Fi-based location). We expose a `timeout` parameter (default 10s) and fail fast on timeout.
2. **Allow Once vs. Allow While Using**: "Allow Once" is a single-shot grant. We detect the next request prompts again and surface the result accordingly.
3. **Wi-Fi disabled location**: a Mac without Wi-Fi cannot determine location reliably. Surface as a typed `locationUnavailable` error with the cause.
4. **Geocoding quota**: hard rate limit per app/process. Cache forward-geocoded addresses in-memory for 1 hour to mitigate.
5. **Country/ISO discrepancies**: addresses without country may have country = nil; we don't infer from coordinate.
6. **`horizontalAccuracy = -1`**: an invalid fix. Our `location_current` retries up to 3 times within the timeout before giving up.
7. **Indoor mall/office accuracy**: 100 m typical, can be worse. We surface the accuracy value so callers can assess.

#### Performance budget

| Operation | Target |
|---|---|
| `location_current` (warm) | <500 ms |
| `location_current` (cold first call) | <10 s |
| `location_geocode` | <500 ms |
| `location_reverse_geocode` | <500 ms |
| `location_distance` | <1 ms (pure math) |

#### Testing strategy

**Unit tests**: coordinate distance math (great-circle); placemark Codable round-trip.

**Integration tests** (gated): geocode known addresses ("1 Apple Park Way") and check returned placemark fields. Skip `location_current` in CI (CI has no real location).

**Mocks**: `MockLocationManager` returning canned `CLLocation`.

### 3.10 Capture (camera, audio, screen)

**Donor(s):** iMCP (MIT — AVCaptureSession + ScreenCaptureKit).
**Effort:** S (already in iMCP).
**Risk:** low (technical), but high TCC cost — kept behind a feature flag.
**Target version:** v1.0 behind flag.

#### Library/protocol choice and rationale

**AVFoundation + ScreenCaptureKit, native.**

- **Camera stills**: `AVCaptureSession` + `AVCapturePhotoOutput`. Single-frame still capture from the default video device.
- **Audio recording**: `AVCaptureSession` + `AVCaptureAudioDataOutput` with AAC encoding via `AVAssetWriter`. Time-bounded (caller specifies duration).
- **Screen capture**: `ScreenCaptureKit` (`SCStream` + `SCStreamConfiguration` + `SCDisplay`). One-shot still via `SCScreenshotManager` on macOS 14+. Falls back to legacy `CGDisplayCreateImage` if SCK isn't available.

**Why not `screencapture` shell-out**: works but requires Screen Recording permission attribution to /usr/sbin/screencapture, not our app. ScreenCaptureKit is the modern, attribution-correct path.

**Feature flag rationale**: capture tools have very high TCC cost (camera, microphone, screen recording — three separate prompts). Many users will never use them but every prompt erodes user trust in the app. We default these tools off, surface them in the Settings panel as "Capture tools (advanced)", and require explicit opt-in.

#### Authentication & credentials

**No credentials.**

#### TCC / entitlements

Three separate TCC permissions, prompted only when the corresponding tool is invoked.

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Camera** | First `capture_take_picture` | "Apple Core would like to access the camera" | Tool fails. |
| **Microphone** | First `capture_record_audio` | "Apple Core would like to access the microphone" | Tool fails. |
| **Screen Recording** | First `capture_take_screenshot` | "Apple Core would like to record the screen" | Tool fails; user must approve in System Settings → Privacy & Security → Screen Recording then *quit and reopen* the app (system requirement). |

**Info.plist usage strings**:

```xml
<key>NSCameraUsageDescription</key>
<string>Apple Core captures images from your camera when you explicitly invoke the capture_take_picture tool.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Apple Core records audio when you explicitly invoke the capture_record_audio tool.</string>
```

Screen Recording does not have a corresponding `NS<X>UsageDescription` key prior to macOS 14. On 14+, `NSScreenCaptureUsageDescription` exists but isn't always honored — the screen recording prompt is system-driven. iMCP already declares the entitlement; we keep that.

#### Data model

```swift
struct CaptureResult: Codable, Sendable {
    let mimeType: String          // "image/png", "audio/m4a"
    let widthPixels: Int?         // for image captures
    let heightPixels: Int?
    let durationSeconds: Double?  // for audio
    let timestamp: Date
    let content: Data             // base64 over MCP
}
```

#### MCP tool inventory

All capture tools have `destructiveHint: false` (they create files but don't destroy data) and `openWorldHint: true` (interact with hardware/screen).

- `capture_take_picture(camera_device_id?: String, format="png") -> CaptureResult` — disabled by default.
- `capture_record_audio(duration_seconds, format="m4a", sample_rate=44100) -> CaptureResult` — disabled by default.
- `capture_take_screenshot(display_id?: Int, region?: {x, y, width, height}, format="png", include_cursor=false) -> CaptureResult` — disabled by default.
- `capture_list_devices() -> {cameras: [{id, name}], microphones: [{id, name}], displays: [{id, name, width, height}]}` — read-only.

#### Edge cases & gotchas

1. **Camera in use by another app** (FaceTime, Zoom): capture fails with `cameraInUse` error. Suggest closing the other app.
2. **External vs internal cameras**: external USB cameras may not be the default. Provide `camera_device_id` for selection.
3. **Audio sample rate**: 44.1 kHz is broadly compatible; some USB mics native at 48 kHz benefit from passing 48000.
4. **Screen Recording's quit-and-reopen requirement**: macOS demands this after granting. Our doctor surfaces a special-case "Screen Recording granted but app needs restart" message.
5. **HDR/wide-color capture**: by default we capture in sRGB to keep payloads compatible. P3 capture is opt-in via a parameter.
6. **Privacy nudge**: every capture appears in the menu bar's "currently using" indicators; users can see we're capturing in real time, which is the right UX.
7. **macOS Studio + multiple displays**: when no `display_id`, screen capture uses primary. List devices to disambiguate.
8. **Audio compression in real time**: m4a (AAC) is the default; raw WAV is opt-in for cases where compression is unwanted (transcription accuracy).

#### Performance budget

| Operation | Target |
|---|---|
| `capture_take_picture` | <500 ms (warm-up cost on first call ~1 s) |
| `capture_record_audio` (10 s clip) | <12 s (10s + processing) |
| `capture_take_screenshot` (single 5K display, PNG) | <500 ms |
| `capture_list_devices` | <100 ms |

#### Testing strategy

**Unit tests**: format encoding, region clipping math.

**Integration tests**: skipped in CI (no camera/mic/display permissions in the runner). Manual testing only, with a documented script.

### 3.11 Shortcuts

**Donor(s):** iMCP (MIT — shells out to `/usr/bin/shortcuts list` / `run`).
**Effort:** S (already in iMCP, with input-validation hardening).
**Risk:** low.
**Target version:** v1.0.

#### Library/protocol choice and rationale

**`/usr/bin/shortcuts` CLI shell-out** via `Process` API.

This is the only path. Apple does not expose a public framework API for invoking Shortcuts. The CLI ships with the OS and runs Shortcuts in-process on the user's behalf with their installed shortcuts.

**Hardening over iMCP**: iMCP validates only the name shape (no slashes, etc.). We harden by:

1. On startup, run `shortcuts list --output-type=plist` and cache the live shortcut name set.
2. Reject any `shortcuts_run` call where the name doesn't appear in the cache.
3. Refresh the cache on demand (`shortcuts_refresh`) and on a 5-minute timer.

This stops a hostile MCP client from passing a crafted name like `; rm -rf ~`. Combined with `Process`'s array-arg API (no shell interpretation of arguments), the attack surface is minimal.

**Input/output**: Shortcuts can accept text input via stdin and produce text output to stdout. We expose `input` (string) and capture stdout as `output`. Binary I/O via attachment files isn't exposed in v1.0 (most LLM-driven Shortcuts use cases are text).

#### Authentication & credentials

**No credentials.**

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **None directly** — but each Shortcut may trigger its own prompts (Calendar, Contacts, etc.) | Per-shortcut | Determined by what the shortcut does | Shortcut returns failure exit code; we surface stdout/stderr. |

#### Data model

```swift
struct ShortcutInfo: Codable, Sendable, Identifiable {
    let id: String                // shortcut name (canonical identifier per Apple)
    let name: String
    let folderName: String?       // user-organized folder
    let icon: ShortcutIcon?       // emoji + color name
    let actionCount: Int?         // when available
}

struct ShortcutIcon: Codable, Sendable {
    let emoji: String?
    let glyph: String?            // SF Symbols name
    let backgroundColor: String?
}

struct ShortcutResult: Codable, Sendable {
    let exitCode: Int
    let output: String            // stdout
    let stderr: String?
    let durationSeconds: Double
}
```

#### MCP tool inventory

- `shortcuts_list(folder?: String) -> [ShortcutInfo]` — read-only.
- `shortcuts_run(name: String, input?: String, timeout_seconds=300) -> ShortcutResult` — destructive (Shortcut may take destructive actions).
- `shortcuts_refresh() -> {count: Int}` — refresh the cached name list.

`shortcuts_run` carries `destructiveHint: true` because we don't know what the shortcut does.

#### Edge cases & gotchas

1. **Name collisions**: a user can have two shortcuts with the same name in different folders. The CLI matches the first by lookup order. We document this; if it bites users we add `folder_hint` parameter.
2. **Shortcuts requiring user interaction**: some shortcuts present a dialog. If we don't pipe to a tty, they may hang. We use a 5-minute default timeout and surface timeout as a typed error.
3. **Shortcut takes longer than expected**: timeout aborts with `SIGTERM`; document the cap.
4. **Shortcut output is binary** (e.g., generates an image): stdout will be raw bytes that don't round-trip as JSON. We require Shortcuts that need to return binary to write to a file and return the path; document.
5. **Privacy of shortcut content**: shortcut names can leak sensitive info ("Send rent payment to landlord"). We surface them; users who want privacy can use the per-tool gate in Settings.
6. **`shortcuts run` exit code**: 0 on success, non-zero on failure. We pass through.

#### Performance budget

| Operation | Target |
|---|---|
| `shortcuts_list` | <300 ms (cold), <50 ms (cached) |
| `shortcuts_run` | bounded by the shortcut itself; no overhead beyond process start (<200 ms) |
| `shortcuts_refresh` | <500 ms |

#### Testing strategy

**Unit tests**: name validation against cached set; stdin/stdout plumbing.

**Integration tests** (gated): create a fixture shortcut on a test account ("apple-mcp-test-echo") that just echoes its input. Verify round-trip.

**What's not testable without a real shortcut**: any specific shortcut's behavior; we test only the harness.

### 3.12 Safari tabs

**Donor(s):** icloud-mcp-mrgo2 (MIT — AppleScript Safari tab read/open/close).
**Effort:** S.
**Risk:** low.
**Target version:** v1.1.

#### Library/protocol choice and rationale

**AppleScript via the shared `AppleScriptRunner` actor.** Safari exposes a stable AppleScript dictionary: list windows, list tabs per window, get URL/title/source per tab, open a new tab with a URL, close a tab.

JXA works equivalently and we use it for the read paths because the JSON-friendly object model is cleaner.

**Why not WebKit / Safari Web Extension**: those are different products. WebKit gives us in-process web views (we don't want); Safari Web Extensions are JavaScript browser extensions installed in Safari (we don't ship those). We're driving the user's existing Safari from outside.

**No public framework API.** Safari's JS bridge / private frameworks are not options.

#### Authentication & credentials

**No credentials.**

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Apple Events → Safari** | First call | "Apple Core wants permission to control Safari" | Tools fail with typed error. |

**Info.plist usage strings**: shared `NSAppleEventsUsageDescription` from §3.5 / §3.6.

#### Data model

```swift
struct SafariWindow: Codable, Sendable, Identifiable {
    let id: Int                   // AppleScript window index, NOT stable across launches
    let title: String?
    let isMinimized: Bool
    let isFullScreen: Bool
    let tabs: [SafariTab]
    let activeTabIndex: Int?
}

struct SafariTab: Codable, Sendable, Identifiable {
    let id: String                // composite: window-index + ":" + tab-index
    let windowId: Int
    let tabIndex: Int             // 1-based per AppleScript
    let title: String
    let url: URL
    let isLoading: Bool?
    let isPrivate: Bool?
    let isPinned: Bool?
    let groupName: String?        // tab group, if any
}
```

#### MCP tool inventory

- `safari_tabs(action, ...) -> ...` — multiplexed.
  - `list(window_id?: Int) -> [SafariTab]` — read-only.
  - `current() -> SafariTab?` — read-only; the active tab in the frontmost window.
  - `get(id) -> SafariTab` — read-only; includes additional details if any.
  - `open_url(url, in_window_id?: Int, in_background=false) -> SafariTab` — opens new tab.
  - `close(id) -> {closed: Bool}` — destructive.
  - `activate(id) -> {activated: Bool}` — bring tab to front.
  - `reload(id) -> {reloaded: Bool}`.
- `safari_get_page_text(tab_id, max_length=10000) -> {text: String, truncated: Bool}` — read-only. Useful for "summarize this page" workflows. Uses Safari's `do JavaScript` — requires "Allow JavaScript from Apple Events" in Safari Develop menu.

#### Edge cases & gotchas

1. **Window/tab indexes are not stable**: AppleScript indexes change as windows/tabs open and close. We surface composite IDs but warn that long-lived caching of IDs is unsafe. Always re-list before operating on a previously-seen tab.
2. **Private windows**: AppleScript can read private window URLs. Surfacing them via MCP is privacy-sensitive; we surface a warning result and require `include_private: true` to actually return the URLs.
3. **`do JavaScript` permission**: requires explicit user opt-in via Safari → Develop menu. If disabled, `safari_get_page_text` fails with a typed error directing user to enable.
4. **Pinned vs. regular tabs**: AppleScript exposes `pinned` property on macOS 14+; older versions don't. Conditional.
5. **Tab Groups** (macOS 13+): tabs may belong to a group. Surface `groupName`; v1.1 doesn't expose group management (rename/move).
6. **Reader mode**: Reader-Mode-active tabs return processed HTML rather than raw page source via `do JavaScript`. Document; consumers wanting raw should explicitly disable Reader.
7. **No Safari Tab Sync**: tabs from other devices via iCloud Tabs are not in scope; AppleScript only sees this device's Safari.

#### Performance budget

| Operation | Target |
|---|---|
| `safari_tabs/list` | <500 ms |
| `safari_tabs/open_url` | <1 s (load time bounded by network) |
| `safari_get_page_text` (medium page) | <2 s |

#### Testing strategy

**Unit tests**: ID parsing/encoding, AppleScript escaping for URLs.

**Integration tests** (gated): open a known URL, list tabs, find it, close it. Requires Safari to be running.

### 3.13 Safari history (gap surface)

**Donor(s):** none — no donor repo covers this. Schema is documented in third-party reverse-engineering writeups.
**Effort:** M (weeks).
**Risk:** medium. Schema is private and Apple may change between macOS versions.
**Target version:** v2.1.

#### Library/protocol choice and rationale

**Direct SQLite read of `~/Library/Safari/History.db`.**

Schema (public knowledge):

- `history_items(id, url, domain_expansion, visit_count, daily_visit_counts, ...)` — one row per distinct URL.
- `history_visits(id, history_item, visit_time, title, load_successful, ...)` — one row per visit; `visit_time` is `CFAbsoluteTime`.
- `history_tombstones(...)` — for sync conflict resolution.

We read this with GRDB.swift (same dep as Mail). Sandbox + FDA needed.

**Why not AppleScript Safari**: Safari's AppleScript dictionary doesn't include history. Direct SQLite is the only path.

**Why not iCloud-synced Safari history via web service**: there is no public API. Skip.

#### Authentication & credentials

**No credentials.** History.db is a local file; FDA gates access.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Full Disk Access** | First read | None auto-prompt; user grants in System Settings | Tool fails with typed error directing user to System Settings → Privacy & Security → Full Disk Access. |

**Info.plist**: temp-exception read for `~/Library/Safari/`:

```xml
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/Users/USERNAME/Library/Safari/</string>
    <!-- plus existing paths from §3.1 Mail, §3.6 Messages -->
</array>
```

#### Data model

```swift
struct SafariHistoryItem: Codable, Sendable, Identifiable {
    let id: Int64                 // history_items.id
    let url: URL
    let domain: String            // host
    let visitCount: Int
    let firstVisitDate: Date
    let lastVisitDate: Date
    let title: String?            // most recent visit's title
}

struct SafariHistoryVisit: Codable, Sendable, Identifiable {
    let id: Int64
    let itemId: Int64
    let url: URL
    let title: String?
    let visitDate: Date
    let loadSuccessful: Bool
}
```

#### MCP tool inventory

- `safari_history_search(query, since?, until?, limit=50, offset=0) -> {results: [SafariHistoryItem], total: Int}` — read-only.
  - `query`: matches against URL or title (substring, case-insensitive).
- `safari_history_recent(limit=20) -> [SafariHistoryVisit]` — read-only.
- `safari_history_top_domains(since?, limit=20) -> [{domain: String, visit_count: Int}]` — read-only.
- `safari_history_visits_to(url) -> [SafariHistoryVisit]` — read-only; all visits to a specific URL.

We do NOT expose write/delete tools for history. Privacy-sensitive; not a feature we want LLMs near.

#### Edge cases & gotchas

1. **Schema version drift**: Apple periodically updates the schema. We probe table columns on first read and surface a typed `safariHistorySchemaUnsupported` error if our expected columns are missing.
2. **WAL mode contention**: Safari often holds write locks. We open with `SQLITE_OPEN_READONLY` and let WAL give us a consistent snapshot.
3. **Mac Absolute Time**: same conversion as Messages — seconds (older) or nanoseconds (newer) since 2001-01-01.
4. **Private browsing**: never appears in History.db. We surface this in tool documentation; users can't search private history.
5. **iCloud-synced history**: appears with same schema as local. We don't distinguish.
6. **Tombstones**: visits marked tombstoned shouldn't surface to users. Filter at query time.
7. **Title may be nil**: pages that didn't fully load have no title. Surface as null.

#### Performance budget

| Operation | Target |
|---|---|
| `safari_history_search` | <200 ms (typical 50k-row history) |
| `safari_history_recent` | <50 ms |
| `safari_history_top_domains` (1 month window) | <300 ms |

#### Testing strategy

**Unit tests**: schema-version detection logic, MAT-conversion math, URL/domain parsing.

**Fixtures**: hand-crafted SQLite file at `Tests/SafariHistoryServiceTests/Fixtures/History-fixture.db` with synthetic visits. Author from documented schema.

**Integration tests** (gated): require a real `~/Library/Safari/History.db`. Skip in CI by default.

### 3.14 iCloud Drive (gap surface)

**Donor(s):** none — no donor repo covers iCloud Drive.
**Effort:** L (month-plus).
**Risk:** high — entitlements, file coordination, lazy-download semantics.
**Target version:** v2.1.

#### Library/protocol choice and rationale

**Foundation `FileManager` + `NSFileCoordinator` + ubiquity APIs against `~/Library/Mobile Documents/`.**

The decision tree:

- **Reading user files**: works without an iCloud container entitlement. We open via `NSOpenPanel` for explicit user selection (which gives us security-scoped access), or read paths the user explicitly mentions.
- **Browsing iCloud Drive structure**: Apple exposes the local mirror at `~/Library/Mobile Documents/com~apple~CloudDocs/`. We can enumerate this directly with `FileManager`.
- **Triggering downloads of `.icloud` placeholders**: `FileManager.startDownloadingUbiquitousItem(at:)` works against any iCloud-managed file the user has permission to access.
- **Writing user-selected paths**: requires the user to explicitly grant via `NSOpenPanel` (`canCreateDirectories: true`).
- **Writing to our own iCloud container**: requires `iCloud.com.oliverames.applecore` container entitlement and Apple Developer Program. We **do not** ship our own container in v2.1; we operate against the user's existing files.

**Why not CloudKit Web Services**: requires a public Apple-Developer-registered container; doesn't expose iCloud Drive *user files*; complex auth.

**Why not Files-app-style FileProvider**: FileProviders are for adding *new* drives. We want to read existing ones.

#### Authentication & credentials

**No credentials for read of local mirror.** iCloud Drive sync runs as a system service; we read the file system.

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Full Disk Access OR user-selected file** | Reading `~/Library/Mobile Documents/...` | FDA: manual grant in System Settings. User-selected: `NSOpenPanel` per file/dir. | Without FDA, only user-selected works. With FDA, we can read the full tree. |

**Entitlements**:

```xml
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

Plus, optionally for FDA-authorized read:

```xml
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/Users/USERNAME/Library/Mobile Documents/com~apple~CloudDocs/</string>
</array>
```

We persist user-granted security-scoped bookmarks to remember user-picked roots across launches.

#### Data model

```swift
struct iCloudFile: Codable, Sendable, Identifiable {
    let id: String                // hashed absolute path
    let path: URL                 // for app's use
    let displayPath: String       // user-friendly relative path
    let name: String
    let isDirectory: Bool
    let sizeBytes: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let isDownloaded: DownloadStatus
    let mimeType: String?
}

enum DownloadStatus: String, Codable, Sendable {
    case downloaded             // file is local, fully synced
    case downloading            // partial, in progress
    case notDownloaded          // .icloud placeholder; not yet local
    case unknown
}
```

#### MCP tool inventory

- `icloud_drive_list(path: String, recursive=false, limit=200) -> [iCloudFile]` — read-only. `path` is "/" for root or a relative path under it.
- `icloud_drive_read(path: String) -> {mime_type: String, size_bytes: Int64, content: Base64String, truncated: Bool}` — read-only. Triggers download if needed; returns content (capped at 10 MB by default; truncation flagged).
- `icloud_drive_search(query, root_path?, file_extension?, modified_after?, limit=50) -> [iCloudFile]` — read-only. Spotlight-backed via `NSMetadataQuery` against the iCloud scope.
- `icloud_drive_status(path) -> iCloudFile` — read-only; expanded metadata including download state.
- `icloud_drive_download(path, wait_until_ready=true, timeout_seconds=120) -> {downloaded: Bool, size_bytes: Int64}` — non-destructive but has side effects (triggers download). Polls until complete or timeout.
- `icloud_drive_pick(prompt?: String) -> [String]` — special tool that displays an `NSOpenPanel` to the user and returns selected paths. The model can ask for a path; the user picks. v2.1 may defer this to v2.2.

We do **not** expose write/move/delete tools in v2.1. Adding write requires more thinking about the security model (the LLM creating files in iCloud Drive is a much higher-stakes operation than reading them).

#### Edge cases & gotchas

1. **`.icloud` placeholders**: zero-byte files with `.icloud` extension represent unsynced files. Our `read` triggers download via `startDownloadingUbiquitousItem(at:)` and waits up to `timeout_seconds`.
2. **File coordination**: writing to a file another app is reading concurrently can corrupt. v2.1 is read-only so this is moot, but write tools in v3.x must use `NSFileCoordinator`.
3. **Path encoding**: `~/Library/Mobile Documents/com~apple~CloudDocs/` contains the literal `~` character (not home expansion). We treat paths as URLs for normalization.
4. **Permission boundary surprises**: shared folders, work-managed iCloud accounts, and folders with custom ACLs can fail reads with permission denied even with FDA. Surface typed errors.
5. **Spotlight scope**: `NSMetadataQuery` for iCloud results is fast but indexed asynchronously. New files may take seconds to minutes to appear.
6. **Large file streaming**: 10 MB cap on `read` is a default; consumers needing more should chunk. We don't expose chunked-read in v2.1.
7. **Symlinks**: iCloud Drive uses symlinks for some folder aliases. We resolve via `URL.resolvingSymlinksInPath()` for path operations but report the resolved path so consumers can detect the redirect.

#### Performance budget

| Operation | Target |
|---|---|
| `icloud_drive_list` (200 entries) | <200 ms |
| `icloud_drive_read` (10 MB cached) | <500 ms |
| `icloud_drive_read` (10 MB needs download) | bounded by network |
| `icloud_drive_search` (Spotlight) | <500 ms |

#### Testing strategy

**Unit tests**: path normalization, download-status detection logic, mime-type guessing.

**Integration tests** (gated): require an iCloud-signed-in test account with a fixture folder `apple-mcp-test/` containing known files. Tests verify list/read/download work.

**What's not testable**: iCloud sync conflict resolution; download speed under flaky network.

### 3.15 iCloud Photos / Photos library (gap surface)

**Donor(s):** none — no donor repo covers Photos.
**Effort:** M (weeks).
**Risk:** medium — Apple's Photos library has heavy permission semantics and large datasets.
**Target version:** v2.1.

#### Library/protocol choice and rationale

**PhotoKit (`Photos.framework`), native.**

The standard, supported API for Photos library access. Exposes `PHAsset` (photo/video item), `PHAssetCollection` (album), `PHFetchOptions` (queries), `PHImageManager` (image data fetch). Works against iCloud Photos transparently — when iCloud Photos is enabled, the framework returns assets that may need to be downloaded.

**Why not the local SQLite at `~/Pictures/Photos Library.photoslibrary/database/photos.db`**: undocumented schema, encrypted in some configurations, and PhotoKit handles iCloud-Photos-not-yet-downloaded transparently. Stay on the supported API.

**Why not iCloud Photos Web Services**: there is no public API. Apple does not expose iCloud Photos to third parties via web service.

#### Authentication & credentials

**No credentials.**

#### TCC / entitlements

| Capability | Triggered by | First-run prompt | Failure mode |
|---|---|---|---|
| **Photos library access** | First fetch | "Apple Core would like access to your photos" with **All Photos** / **Selected Photos** / **Don't Allow** | If denied: tools fail. If "Selected Photos": only assets the user has explicitly chosen are visible — surface as a reduced result set with a hint. |

**Info.plist**:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Apple Core reads your photos when you ask Claude to find or describe images.</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Apple Core saves images to your Photos library when explicitly requested.</string>
```

**Entitlement**: not strictly required for sandboxed read; we do declare:

```xml
<key>com.apple.security.assets.pictures.read-only</key>
<true/>
```

#### Data model

```swift
struct PhotoAsset: Codable, Sendable, Identifiable {
    let id: String                // PHAsset.localIdentifier
    let mediaType: PhotoMediaType
    let mediaSubtypes: [PhotoMediaSubtype]
    let creationDate: Date?
    let modificationDate: Date?
    let location: Coordinate?
    let pixelWidth: Int
    let pixelHeight: Int
    let durationSeconds: Double?  // for video
    let isFavorite: Bool
    let isHidden: Bool
    let burstId: String?
    let originalFilename: String?
    let sourceType: PhotoSourceType  // .userLibrary, .iCloudShared, .photoStream, .syncedAlbum
}

enum PhotoMediaType: String, Codable, Sendable { case image, video, audio, unknown }
enum PhotoMediaSubtype: String, Codable, Sendable {
    case live, panorama, hdr, screenshot, depthEffect
    case streamedVideo, highFrameRateVideo, timelapseVideo, cinematicVideo, spatialVideo
}
enum PhotoSourceType: String, Codable, Sendable {
    case userLibrary, iCloudShared, photoStream, syncedAlbum, none
}

struct PhotoAlbum: Codable, Sendable, Identifiable {
    let id: String                // PHAssetCollection.localIdentifier
    let title: String
    let kind: AlbumKind
    let assetCount: Int
    let startDate: Date?
    let endDate: Date?
}

enum AlbumKind: String, Codable, Sendable {
    case userAlbum, smartAlbum, sharedAlbum, syncedAlbum
    case favorites, hidden, recents, screenshots, selfies, panoramas, videos
}

struct PhotoData: Codable, Sendable {
    let assetId: String
    let mimeType: String
    let widthPixels: Int
    let heightPixels: Int
    let sizeBytes: Int
    let content: Data             // base64 over MCP
}
```

#### MCP tool inventory

- `photos_search(query?, after?, before?, near?: Coordinate, radius_meters?, media_types?: [PhotoMediaType], is_favorite?, has_location?, limit=50, offset=0) -> {results: [PhotoAsset], total: Int}` — read-only.
  - `query`: matches against album names, location names. (Apple's "describe what's in this photo" search isn't exposed via PhotoKit.)
- `photos_albums() -> [PhotoAlbum]` — read-only.
- `photos_album_assets(album_id, limit=100, offset=0) -> {results: [PhotoAsset], total: Int}` — read-only.
- `photos_get_asset(id, with_metadata=true) -> PhotoAsset` — read-only.
- `photos_get_image(id, target_size?: {width, height}, format="jpeg", quality="high") -> PhotoData` — read-only. Resizes via `PHImageManager.requestImage(for:targetSize:contentMode:options:resultHandler:)`.
- `photos_get_video_thumbnail(id, time_seconds=0, target_size?) -> PhotoData` — read-only.
- `photos_recent(limit=20) -> [PhotoAsset]` — read-only convenience.
- `photos_save_image(content: Base64String, format: String, location?: Coordinate, album_id?: String) -> PhotoAsset` — destructive=false (creates).

We do not expose delete tools in v2.1. The blast-radius on accidental deletion is large.

#### Edge cases & gotchas

1. **Selected Photos mode**: when user grants only specific assets, queries return only those assets. We surface a `selectedPhotosMode: true` flag in tool responses so the LLM understands the result set is constrained.
2. **iCloud Photos download lag**: assets may not be local. `PHImageManager.requestImage(...)` with `isNetworkAccessAllowed: true` will download; with false, returns nothing for not-local assets. We default to allow with a 30s timeout.
3. **Live Photos**: surface the still image by default via `requestImage`. Live-Photo movie data via separate `requestLivePhoto` if requested.
4. **HEIF/HEIC compatibility**: PhotoKit returns HEIC by default on modern Macs. For wider LLM compatibility, we transcode to JPEG by default; HEIC is opt-in via `format` parameter.
5. **Spatial / Cinematic / Apple Vision content**: surface via media subtypes. Don't try to extract depth maps or 3D content unless explicitly requested.
6. **Location stripping in iCloud Shared albums**: shared assets often have GPS stripped. Our location field will be nil; this is correct and expected.
7. **Hidden album access** requires a separate `NSPhotoLibraryUsageDescription` accommodation; iCloud-synced hidden albums require Touch ID/passcode in some configurations. We surface an error if hidden access is denied.
8. **Bursts**: a single burst is a parent + children. Surface burstId so consumers can group.
9. **Identifier persistence**: `PHAsset.localIdentifier` is stable on this device but does not survive library re-import. Document.

#### Performance budget

| Operation | Target |
|---|---|
| `photos_search` (typical, indexed) | <300 ms |
| `photos_albums` | <100 ms |
| `photos_album_assets` (100 assets) | <500 ms |
| `photos_get_image` (downloaded, 12 MP, target 1920) | <500 ms |
| `photos_get_image` (needs iCloud download) | bounded by network |

#### Testing strategy

**Unit tests**: media-subtype encoding, fetch-options builder for queries.

**Integration tests** (gated): require Photos.app with an `apple-mcp-test` album seeded with known assets. CI skips because no Photos library on a runner.

**What's not testable without a real library**: actual asset metadata; iCloud download behavior under throttle.

### 3.16 Find My (documented-blocked surface)

**Status:** Will not implement. Documented here so future contributors don't waste effort revisiting.

**Why blocked**: there is no public API for Find My. The `FindMyKit` framework that exists is internal to Apple's own apps. Reverse-engineering Apple ID auth tokens to talk to `fmf.icloud.com` is:

1. **Brittle.** Apple has rotated auth schemes multiple times. Each rotation breaks third-party Find My integrations within days.
2. **Privacy-sensitive.** A tool that reveals device locations to an LLM is a privacy hazard the value proposition doesn't justify.
3. **TOS-adjacent.** Apple has historically issued takedowns to projects that scrape Find My.

**If a contributor finds a public path**: the surface to add would be a `findmy_devices` read tool returning `[Device]` with name/model/location/last-seen. We don't have a design for it.

**Documented gap.** No further action.

### 3.17 Health (documented-blocked surface)

**Status:** Will not implement on macOS. Possibly add iOS companion app in v3+.

**Why blocked on macOS**: HealthKit (`HealthKit.framework`) is iOS, watchOS, and visionOS only. There is no macOS HealthKit. Health data syncs to iCloud but is not accessible on the Mac via any framework.

**Possible future**: an iOS companion app that reads HealthKit and exposes data to a connected Mac via Multipeer Connectivity or our own push channel. Not v1, v2, or v3.0.

**Documented gap.** No further action for macOS-only product.

---

## 4. License posture

Per §0 decision 4: **Apple Core is licensed GPL-3.0-or-later**, matching `apple-mail-mcp`. This dissolves the clean-room discipline we'd previously planned around Mail.

### 4.1 What this means in practice

- **Apple Core's own source code is GPL-3.0-or-later.** Ship a `LICENSE` file at the repo root with the GPL-3.0 text. Every new file we author carries an SPDX header `// SPDX-License-Identifier: GPL-3.0-or-later`.
- **We can lift `apple-mail-mcp` source directly.** Translate the Python to Swift function-by-function. Disk-first `.emlx` parser, FTS5 schema, state-reconciliation diff, MailCore JXA facade — all fair game. Attribute properly (see §4.2).
- **We can lift the six MIT donors directly too.** MIT-into-GPL is one-way compatible: you can incorporate MIT code into a GPL work as long as the MIT license terms (preserve copyright + permission notice) are honored on the relevant files. We do not relicense their files; their MIT headers stay intact on the files we lift, and our combined project is GPL because of the GPL parts.

### 4.2 Attribution discipline

- **`THIRD_PARTY_LICENSES/`** at the repo root contains a copy of the LICENSE text from each donor we lift code from:
  - `apple-mail-mcp.LICENSE` (GPL-3.0)
  - `iMCP.LICENSE` (MIT, Mattt 2025)
  - `mcp-server-apple-events.LICENSE` (MIT, Frad LEE 2025)
  - `icloud-mcp-adamzaidi.LICENSE` (MIT, Adam Zaidi 2026)
  - `apple-mcp-dhravya.LICENSE` (MIT, Dhravya Shah 2025)
  - `icloud-mcp-mrgo2.LICENSE` (MIT, Carlos Lorenzo 2026)
- **`NOTICE`** at the repo root acknowledges each donor by name + URL + which surfaces or patterns we lifted. Plain English; not a legal document but a courtesy.
- **Per-file SPDX headers.** Files lifted from a donor keep their original copyright line and SPDX-License-Identifier. New files we author carry our copyright + GPL-3.0-or-later. Mixed files (we extended a lifted file substantially) get both copyright lines + SPDX `GPL-3.0-or-later AND <donor-license>` if the donor was MIT, or just GPL-3.0-or-later if from `apple-mail-mcp`.
- **Commit log discipline.** When porting `apple-mail-mcp` code, commit messages reference the source: "Translate Python `index/sync.py:reconcile()` to Swift `MailIndex.reconcile()`." This makes attribution traceable.

### 4.3 Dependencies (no GPL contamination concerns the other way)

Every SPM dependency we pull in is permissive (MIT or Apache-2.0 — see §2.1). GPL-3.0-or-later is *compatible* with linking permissive deps; the combined work is GPL. The risk we *would* have had — needing GPL-compatible deps — vanishes because GPL is the ceiling, not the floor.

If we ever consider an LGPL or Apache-2.0-with-patent-grant dep, both are GPL-3-compatible. Apache-2.0 has known compatibility with GPL-3 specifically (patent termination clauses align). LGPL fine if dynamically linked. AGPL would be a problem (only AGPL-compatible) but we don't need any AGPL libraries.

---

## 5. Build sequence

### 5.1 Tracer bullet — Calendar

**Pick: Calendar.**

Calendar exercises every layer of the architecture without requiring any new code paths beyond what iMCP already proves works:

- **TCC.** Calendar prompts on first use (`EKEventStore.requestFullAccessToEvents()`). Forces us to validate that the .app's signed bundle identity (`com.oliverames.applecore`) is what macOS attributes the prompt to — not Claude Desktop or whichever client launched the CLI.
- **MCP wiring.** Three tools (`calendar_list_calendars`, `calendar_list_events`, `calendar_create_event`) round-trip through stdio → CLI → XPC → app → EventKit → app → XPC → CLI → stdio.
- **IPC overhaul.** First surface to exercise the Bonjour → NSXPCConnection swap. If Calendar round-trips, every other surface plugs into the same wire unchanged.
- **JSON-LD output.** Reuses iMCP's `Ontology` `Event` type — sanity-checks our typed-result discipline through the XPC `NSDictionary` round-trip.
- **Build pipeline.** First end-to-end pass through `xcodebuild` for the .app target + bundled CLI + ad-hoc codesign with `--options runtime`. Notarization deferred (optional per §0).
- **Doctor command shape.** Calendar's doctor entry (does `EKAuthorizationStatus.fullAccess` return true?) becomes the template every other surface follows.

We deliberately don't pick Mail as the tracer. Mail is the highest-effort surface and depends on layers we want already debugged when we get to it (FTS5 indexer, IMAP client, state-reconciliation sync). Calendar is already 80% in iMCP; the tracer-bullet effort is wiring the EventKit service through the new XPC bridge and validating the build pipeline.

**Smallest possible smoke test before the tracer.** Port iMCP's `Utilities` service (single tool: `utilities_beep`) to the forked repo over the new XPC wire. If Claude Desktop calls `utilities_beep` and we hear a beep, the entire CLI ↔ XPC ↔ app ↔ tool-dispatcher loop works. Half a day of work. Do this before Calendar.

### 5.2 Version targets

**v1.0 — "iMCP+ on the new IPC"**
- All iMCP-existing surfaces (Calendar, Reminders, Contacts, Location, Maps, Messages-read, Weather, Capture, Shortcuts).
- Bonjour → XPC IPC overhaul.
- Per-client approval gate, hardened.
- Doctor command.
- Sparkle in-app updates configured.
- Homebrew tap wired up.
- CI: lint + unit tests + a tiny set of EventKit integration tests against a dedicated test calendar.

**v1.1 — "the AppleScript surfaces"**
- Notes (read + create).
- Messages (send).
- Safari tabs.
- Reminders extensions: subtasks (in our own table), full recurrence, structured-location alarms (port apple-events' shape, attribute FradSer).
- Calendar extensions: same recurrence/alarms work for events.
- Three-phase safe move (manifest, but not yet wired to Mail because Mail isn't there yet).

**v1.2 — "the saved-rules engine and the doctor's full sweep"**
- Saved-rules engine (port adamzaidi's pattern, attribute him).
- Session journal (`log_write` / `log_read` / `log_clear`).
- Per-surface preflight error strings (port dhravya's pattern).
- Lazy loading + safe-mode fallback.

**v2.0 — "Mail"**
- Disk-first `.emlx` parser, translated function-by-function from `apple-mail-mcp` (Python → Swift). Attribute per §4.2.
- FTS5 cache via GRDB.swift.
- State-reconciliation sync (lifted from apple-mail-mcp).
- Strategy cascade for single-email reads.
- IMAP send/draft/bulk via swift-nio-imap.
- Three-phase safe move wired up against Mail.
- Notes (update) — content-hash conflict detection.

**v2.1 — "iCloud surfaces"**
- iCloud Calendar via CalDAV (headless mode).
- iCloud Contacts via CardDAV.
- iCloud Photos via PhotoKit.
- iCloud Drive read access (NSFileCoordinator).
- Safari history.

**v3.0 — "polish and reach"**
- Notarized for distribution outside Sparkle/Homebrew.
- Mac App Store submission (if sandbox ergonomics work out).
- Localization, accessibility audit (`/axiom:audit accessibility`).
- Shortcuts donation / App Intents bridge — donate read-only tools as App Intents so the user can drive the MCP from Apple Shortcuts. (`build-ios-apps-codex:ios-app-intents` skill applies even though we're macOS.)

### 5.3 Skills to invoke during implementation

These skills become load-bearing once we start writing Swift, not before. Listed for the build-time agent's reference.

- **`build-macos-apps-codex:swiftui-patterns`** — for the menu-bar UI work.
- **`build-macos-apps-codex:appkit-interop`** — for the NSXPCConnection / Mach service plumbing.
- **`build-macos-apps-codex:signing-entitlements`** — for the sandbox + hardened runtime + temp-exception entitlements dance.
- **`build-macos-apps-codex:packaging-notarization`** — for the codesign + notarytool + Sparkle appcast pipeline.
- **`build-macos-apps-codex:swiftpm-macos`** — for SPM package layout when we extract subsystems.
- **`build-macos-apps-codex:window-management`** — for the menu bar + settings panel ergonomics.
- **`swiftui-pro`** — comprehensive review pass on each PR touching SwiftUI.
- **`axiom-concurrency`** — actor isolation for the IPC layer and the AppleScript runner.
- **`axiom-data`** — GRDB schema design for the Mail index.
- **`axiom-build`** — when Xcode misbehaves on CI.

---

## 6. Distribution

Per §0 decision 5: personal use, no Mac App Store, no Sparkle, no Homebrew cask in v1. Notarization optional.

### 6.1 Personal-build path

The v1 install loop, given the hard-fork iMCP base + .app target + bundled CLI:

```bash
# 1. Build the .app via xcodebuild (Apple Core.xcodeproj produces both targets:
#    the .app, and the bundled CLI at Apple Core.app/Contents/MacOS/apple-core)
git clone https://github.com/oliverames/apple-core
cd apple-core
xcodebuild -project "Apple Core.xcodeproj" \
           -scheme "Apple Core" \
           -configuration Release \
           -derivedDataPath build \
           CODE_SIGN_IDENTITY="-" \
           CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

# 2. Locate the built .app
APP_PATH="build/Build/Products/Release/Apple Core.app"

# 3. Drag-install
cp -R "$APP_PATH" /Applications/

# 4. Launch once so the .app registers as a running process
#    (this also lets the user grant Accessibility / Automation prompts in advance
#    if they want to short-circuit the first-tool-call experience)
open "/Applications/Apple Core.app"

# 5. Register the bundled CLI with Claude Desktop.
#    The CLI lives inside the .app bundle; the path is stable.
# Edit ~/Library/Application Support/Claude/claude_desktop_config.json:
{
  "mcpServers": {
    "apple-core": {
      "command": "/Applications/Apple Core.app/Contents/MacOS/apple-core"
    }
  }
}

# 6. Restart Claude Desktop. First tool call:
#    - CLI launches under Claude Desktop
#    - CLI opens NSXPCConnection to com.oliverames.applecore.xpc
#    - .app accepts the connection, presents the per-client approval alert
#    - On Approve: tool executes, TCC prompts attribute to "Apple Core"
```

Same shape for Claude Code and Cursor — all three read MCP server configs that point at a stdio-launchable binary.

**Optional: register Apple Core.app as a Login Item** so it's already running when MCP clients launch the CLI. Avoids the auto-launch step in the lifecycle (§1.2), making the first connection a few hundred milliseconds faster.

### 6.2 Code signing notes

Ad-hoc signing (`CODE_SIGN_IDENTITY="-"` in xcodebuild) is sufficient for personal use. Both binaries — the .app and the bundled CLI — get signed with identifier `com.oliverames.applecore`. macOS will:

- Persist TCC grants keyed on the **.app's** signed identifier. Once granted to "Apple Core" for a given surface (Calendar, Contacts, etc.), subsequent rebuilds with the same identifier reuse the grants. No re-prompt on every `xcodebuild`.
- Show "from an unidentified developer" Gatekeeper friction on first launch of the .app (right-click → Open). Annoying but one-time per install.

The `--options runtime` flag (set via `OTHER_CODE_SIGN_FLAGS = --options runtime` in build settings) enables the hardened runtime. Required for:

- Apple Events automation under macOS 26+ when the calling process must be hardened-runtime to attribute Automation prompts properly.
- Notarization, if we ever opt in.

**Hardened runtime requires entitlements declared at sign time.** The .app ships an `Apple Core.entitlements` file with the minimum set:

```xml
<plist version="1.0">
<dict>
    <!-- Disable library validation so SwiftPM-fetched dylibs (swift-nio etc.) load -->
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <!-- Allow JIT for Swift dynamic dispatch surfaces -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <!-- Apple Events: required to drive Mail, Notes, Messages, Safari, Reminders -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
    <!-- WeatherKit (gated, only if we ever opt in to entitlements) -->
    <!-- <key>com.apple.developer.weatherkit</key> <true/> -->
</dict>
</plist>
```

The bundled CLI uses a leaner entitlements file (`apple-core-cli.entitlements`) with only the library-validation and JIT exceptions — the CLI never directly drives Apple Events; it proxies to the .app over XPC.

### 6.3 TCC purpose strings (Info.plist in the .app bundle)

The .app's `Info.plist` lives at `Apple Core.app/Contents/Info.plist` (managed by the Xcode project) and contains all TCC purpose strings. macOS attributes prompts to the .app's bundle identity. The bundled CLI inherits attribution by virtue of being launched from inside the .app's `Contents/MacOS/` — but in practice TCC-protected APIs are only called from the .app process anyway (the CLI is a courier, not an actor).

```xml
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.oliverames.applecore</string>
    <key>CFBundleName</key>
    <string>Apple Core</string>
    <key>CFBundleDisplayName</key>
    <string>Apple Core</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSUIElement</key>
    <true/>  <!-- menu bar agent, no Dock icon -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Apple Core uses AppleScript to drive Notes, Mail, Messages, Safari, and Reminders when you ask Claude to read or modify them.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Apple Core reads and creates calendar events at your request.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Apple Core needs full access to read and modify calendar events.</string>
    <key>NSRemindersUsageDescription</key>
    <string>Apple Core reads and creates reminders at your request.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Apple Core needs full access to read and modify reminders.</string>
    <key>NSContactsUsageDescription</key>
    <string>Apple Core reads, searches, and updates your contacts at your request.</string>
    <key>NSLocationUsageDescription</key>
    <string>Apple Core uses your location for nearby search, weather, and directions.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Apple Core uses your location for nearby search, weather, and directions.</string>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Apple Core reads your photos when you ask Claude to find or describe images.</string>
    <key>NSPhotoLibraryAddUsageDescription</key>
    <string>Apple Core saves images to your Photos library when explicitly requested.</string>
    <key>NSCameraUsageDescription</key>
    <string>Apple Core captures images when you explicitly invoke the capture_take_picture tool.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Apple Core records audio when you explicitly invoke the capture_record_audio tool.</string>
</dict>
```

The bundled CLI does *not* embed an Info.plist. FradSer's `-Xlinker -sectcreate __TEXT __info_plist` trick is unnecessary for our shape because the CLI is a Mach-O executable inside an .app bundle and macOS treats its TCC attribution through the parent .app where it matters.

### 6.4 Notarization (optional, for v1)

Skipped for personal use. The cost-benefit if we change our minds:

- **Cost**: $99/yr Apple Developer Program membership; one-time setup of `notarytool` keychain credentials; ~5 minutes added to each release build for `xcrun notarytool submit ...` + `xcrun stapler staple`.
- **Benefit**: removes the right-click-to-open Gatekeeper friction on the .app; required if we ever publish broadly.

If we publish to GitHub and want strangers to be able to install without yelling at Gatekeeper, notarize. Otherwise skip.

### 6.5 Future distribution channels (v2.0+ if ever published broadly)

Documented for completeness. None of these are in scope for v1.

- **Sparkle in-app updater**: appcast XML at a stable URL (e.g., `https://applecore.oliverames.com/appcast.xml`). The .app already has the right shape for Sparkle; it's just configuration.
- **Homebrew cask**: `brew install --cask oliverames/tap/apple-core`. Requires our own tap repo with a Cask formula pointing at the notarized .dmg.
- **Mac App Store**: would force re-sandboxing, removing Sparkle, and reducing the surface set (Mail/iCloud Drive don't fit MAS sandbox cleanly). Off the table per §0.
- **DXT (Claude Desktop one-click)**: a `.dxt` bundle that wraps the .app + a `claude_desktop_config.json` snippet. Useful for non-developer audiences if we ever target them.

---

## 7. Open questions for Oliver

Four questions previously listed here have been resolved by §0 (project name + bundle ID, sandboxing, license, architecture/repo-strategy). The remaining open items:

1. **Apple Developer Program membership.** Do you have one? Determines whether we can ship WeatherKit (entitlement-gated) and whether notarization is even available. Recommendation: skip for v0/v1 personal use; revisit only if we want WeatherKit or broad publishing.

2. **WeatherKit.** Requires Apple Developer Program membership + `com.apple.developer.weatherkit` entitlement. iMCP gates behind `#if WEATHERKIT_AVAILABLE`. Without the entitlement, the weather surface returns "weather unavailable in this build" errors. Recommendation: gate it; ship without WeatherKit in v1; revisit if you sign up for ADP for any other reason.

3. **Telemetry.** Any opt-in usage analytics? Recommendation: ship none. Personal use means you ARE the telemetry. Add opt-in MetricKit-style only if we ever publish broadly.

4. **Mail v1 strategy.** Mail is still scheduled for v2.0 (after the AppleScript long tail in v1.1 and the saved-rules engine in v1.2). The clean-room overhead is gone (§4) but the translation work — Python `email`, MIME, FTS5 schema, state-reconciliation — is still ~2-3 weeks of focused effort. Recommendation: keep Mail at v2.0. Want confirmation.

---

## 8. Status

- **Reviews:** complete (`reviews/*.md`).
- **Synthesis:** complete (`SYNTHESIS.md`).
- **Build plan:** this document, including 17 contributor-grade per-surface deep dives in §3 plus six locked decisions in §0.
- **Next deliverable:** hard-fork `mattt/iMCP` to `oliverames/apple-core`, rename to "Apple Core", change bundle ID to `com.oliverames.applecore`, swap the Bonjour `NetService` discovery for `NSXPCConnection` over Mach service `com.oliverames.applecore.xpc`, drop iMCP's `MessageService` security-scoped-bookmark code (no longer needed unsandboxed), preserve iMCP's `LICENSE` + add a top-level `NOTICE` attributing Mattt's original work, change the project license to GPL-3.0-or-later (MIT files keep their original headers; combined work is GPL). Then verify the `utilities_beep` smoke test round-trips end-to-end before touching Calendar.

---

## 9. At-a-glance summary

**Tracer bullet:** Calendar ([§3.2](#32-calendar)) — already 80% in iMCP, exercises EventKit + TCC + JSON-LD output + the build/install loop. The path is: hard-fork iMCP, rename to Apple Core, change bundle ID to `com.oliverames.applecore`, swap Bonjour for NSXPCConnection over `com.oliverames.applecore.xpc`, drop the chat.db security-scoped-bookmark code, change project license to GPL-3.0-or-later (preserving iMCP's MIT headers on lifted files), `xcodebuild` with `CODE_SIGN_IDENTITY="-"`, drag `Apple Core.app` to `/Applications`, register `Apple Core.app/Contents/MacOS/apple-core` with Claude Desktop, observe TCC prompt attribute to "Apple Core", see calendars list.

**Pre-tracer smoke test:** port iMCP's `Utilities` service (single tool: `utilities_beep`) over the new XPC wire. Half a day. Validates the entire CLI ↔ XPC ↔ app ↔ tool-dispatcher loop end-to-end before EventKit is in the picture.

**Decisions locked, work unblocked:** the six §0 decisions (name, bundle ID, sandboxing, license, distribution, architecture) close every previously-blocking question. Remaining items in §7 are either advisory recommendations (repo strategy is settled to hard-fork by §0 #6, telemetry stays off) or wait-and-see (Apple Developer membership, WeatherKit gating, Mail timing). None of them block the start of v0.
- **First code:** v1.0 tracer-bullet branch starts with the Utilities-beep port to validate the new XPC IPC, then the Calendar surface as the real tracer. After Calendar is green end-to-end (build, sign, notarize, install, run, see beep, see calendar list in Claude Desktop), the rest of v1.0 ports proceed in parallel.
