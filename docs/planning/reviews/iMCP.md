# iMCP — Review
**URL:** https://github.com/mattt/iMCP
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Mattt (mat.tt). Originally under Loopwork org, transferred to `mattt/iMCP` (commit `abe4463`). Author of the official Swift MCP SDK.
- **License:** MIT (copyright "Mattt 2025").
- **Last commit:** 2026-01-30 (commits in last 90 days: 4)
- **Activity signal:** Lightly active. Big bursts (transfer, CI, format rules, Shortcuts service, release automation) in late Jan 2026; cadence sporadic but maintained, releases tagged (1.4.0), Sparkle appcast configured.

## Stack
- **Language / runtime:** Swift, macOS 15.3+, built with Xcode 26. Two targets: SwiftUI menu-bar app (`App/`) and CLI executable `imcp-server` (`CLI/main.swift`). SPM deps: `swift-sdk` (official MCP SDK), `JSONSchema`, `Ontology`, `madrid` (iMessage typedstream parser), `swift-service-lifecycle`, `swift-log`, `MenuBarExtraAccess`.
- **MCP transport(s):** stdio at the client boundary with a twist. The `imcp-server` CLI is the stdio endpoint clients launch; internally it discovers the running iMCP.app over Bonjour (`_mcp._tcp` on `local.`) and proxies bytes between stdin/stdout and an `NWConnection` TCP socket using `NetworkTransport`. The app is the actual MCP server.
- **Build / install path:** Install .app, open it, toggle services (each triggers a real TCC prompt), run `claude mcp add --scope user iMCP -- /Applications/iMCP.app/Contents/MacOS/imcp-server`. App's own menu has a "Configure Claude Desktop" item that edits `claude_desktop_config.json` directly.
- **Distribution:** Signed/notarized macOS .app via `brew install --cask mattt/tap/iMCP` and a Sparkle appcast at `https://downloads.imcp.app/appcast.xml`. CLI ships inside the app bundle.

## Apple surfaces covered
- Calendar (EventKit, `EKEventStore`)
- Reminders (EventKit, `.reminder` access)
- Contacts (Contacts framework, `CNContactStore`)
- Location (Core Location)
- Maps (MapKit: search, directions, ETA, POI, static map image generation)
- Messages (read-only via `~/Library/Messages/chat.db` SQLite + `madrid` typedstream decoder)
- Weather (WeatherKit, gated behind `#if WEATHERKIT_AVAILABLE`)
- Capture (camera stills, audio recording, screenshots via ScreenCaptureKit/AVFoundation)
- Shortcuts (shells out to `/usr/bin/shortcuts list` / `run`)
- Utilities (system beep — small grab bag)

## Tool inventory
- **Calendar:** `calendars_list`, `events_fetch`, `events_create`
- **Contacts:** `contacts_me`, `contacts_search`, `contacts_update`, `contacts_create`
- **Location:** `location_current`, `location_geocode`
- **Maps:** `maps_search`, `maps_directions`, `maps_explore`, `maps_eta`, `maps_generate` (static map PNG)
- **Messages:** `messages_fetch`
- **Reminders:** `reminders_lists`, `reminders_fetch`, `reminders_create`
- **Capture:** `capture_take_picture`, `capture_record_audio`, `capture_take_screenshot`
- **Weather:** `weather_current`, `weather_daily`, `weather_hourly`, `weather_minute`
- **Shortcuts:** `shortcuts_list`, `shortcuts_run`
- **Utilities:** `utilities_beep`

## How it talks to Apple
Native frameworks only — no AppleScript, no JXA. Calendar/Reminders use `EKEventStore.requestFullAccessToEvents()`/`…toReminders()`. Contacts uses `CNContactStore` with custom JSON-LD encoders in `Contacts+Extensions.swift`. Location uses Core Location with delegate-to-async bridging. Maps uses `MKLocalSearchCompleter`, `MKDirections`, `MKMapSnapshotter`. Weather uses WeatherKit, conditional-compiled via `WEATHERKIT_AVAILABLE` so unsigned dev builds still compile. Capture uses `AVCaptureSession` and ScreenCaptureKit. Messages is the outlier: SQLite over `chat.db` with the `madrid` package decoding Apple's `typedstream` format. Shortcuts is the only shell-out: `Process` + `/usr/bin/shortcuts list`/`run`. All results are encoded as Schema.org JSON-LD via `Ontology`.

## Permissions / TCC model
Sandboxed app. Entitlements declare WeatherKit, health personal-info, Apple-events temp exception for Terminal, mach-lookup for Sparkle services, and a temp-exception read path for `~/Library/Messages/`. Each menu toggle calls the framework's request API which fires the real TCC prompt; no manual fallback. Messages uses `NSOpenPanel` to select `chat.db`, then stores a security-scoped bookmark in `UserDefaults` for re-resolution. An in-app per-client approval dialog (`ConnectionApprovalView`) gates which MCP clients can connect over Bonjour; `trustedClients` is persisted via `@AppStorage`.

## Testing posture
No tests. CI workflow (`.github/workflows/ci.yml`) only runs `swift format lint --strict` and `xcodebuild build` on macOS 26 / Xcode 26.0. No unit, integration, or smoke tests checked in. The author leans on `swift format`, "warnings as errors" (commit `e8356bd`), and manual testing via the MCP Inspector / Companion (both documented in README).

## Notable strengths (worth stealing)
1. **App + CLI split with Bonjour + StdioProxy.** Keeps the MCP transport as stdio while the actual TCC-protected work runs inside a long-lived signed .app — the only architecture that cleanly survives sandboxing for Calendar/Contacts/etc. `StdioProxy` actor in `CLI/main.swift` is a clean reference, including explicit MCP heartbeat filtering.
2. **JSON-LD/Schema.org outputs via Ontology.** Tool results are typed (`Person`, `Conversation`) rather than ad-hoc dicts — legible to the model and self-documenting.
3. **Per-client approval gate.** `ServerController` shows an approval alert the first time a new client connects, then remembers it via `@AppStorage("trustedClients")`.
4. **Security-scoped bookmark pattern for `chat.db`.** `MessageService` is the canonical sandboxed-Messages access pattern: `NSOpenPanel` with a delegate locked to `chat.db`, read-only bookmark, `withSecurityScopedAccess` helper. Lift verbatim.
5. **MCP `Tool.Annotations` set on every tool** (`readOnlyHint`, `destructiveHint`, `openWorldHint`); `shortcuts_run` correctly carries `destructiveHint: true`.

## Gotchas / things to avoid
1. **Bonjour discovery is finicky.** CLI string-matches `String(describing: $0.endpoint).contains("iMCP")` to pick the service, with a 30s timeout and several `NWError` codes (54/57/96) handled explicitly. Recent commits (`c9daec8`, `e00864f`) patched real continuation/QoS hangs — the architecture costs robustness.
2. **No tests.** CI is `swift format lint` + `xcodebuild build` only.
3. **`shortcuts_run` shells out to `/usr/bin/shortcuts`** with a 5-minute timeout and no input validation beyond name.
4. **macOS-only, 15.3+.** Uses `MenuBarExtra(.window)`, ScreenCaptureKit, WeatherKit. Not portable; no headless story.
5. **Hardcoded Messages DB path** `/Users/\(NSUserName())/Library/Messages/chat.db` — bookmark fallback handles non-default cases but the default path is the happy path.

## License compatibility for our combined project
MIT, fully compatible with both MIT and Apache-2.0 licensing for our combined project (preserve the copyright notice).

## Verdict
This is the **reference architecture** for any sandboxed Apple-MCP project: ship a signed .app that handles TCC and a tiny stdio CLI proxy that clients launch. Steal the App+CLI+Bonjour split, the per-client approval gate, the chat.db security-scoped bookmark dance, and the JSON-LD/Ontology output convention. Don't inherit the test posture, and assume any combined project will need a non-Bonjour fallback for headless or remote use.
