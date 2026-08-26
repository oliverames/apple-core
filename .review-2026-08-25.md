# apple-core code review — 2026-08-25

Scope: App.swift, ServerController, all Views/, Models/, Extensions/, Integrations/, CLI/main.swift. Research only; no files changed. All line numbers from `main` @ e5137be.

## Findings

### 1. Concurrent approval requests for different clients clobber each other's window, handlers, and trust state
SEVERITY: HIGH | LOCATION: App/Controllers/ServerController.swift:424-470, App/Views/ConnectionApprovalView.swift:102,128
EVIDENCE:
- `ServerController.showConnectionApprovalAlert` keeps exactly one slot of state per dialog regardless of client: `self.pendingConnectionID = clientID` (424), `pendingClientName = clientID` (436), `currentApprovalHandlers = (approve:, deny:)` (437), then `approvalWindowController.showApprovalWindow(...)` (439).
- The coalescing guard at 427 (`guard !activeApprovalDialogs.contains(clientID)`) only dedupes the SAME client.
- `ConnectionApprovalWindowController.showApprovalWindow` overwrites both single slots: `pendingDeny = onDeny` (102) and `self.window = window` (128). The previous window is never closed.
FAILURE SCENARIO: Claude Desktop connects while a second client also connects. Two approval windows are shown; controller state points at client2 only. Clicking Allow on window1 runs c1's approve, sets `pendingDeny = nil` (dropping c2's deny), then `closeWindow()` closes window2 (the wrong one); window1 stays on screen with dead state. If window1 is instead closed via titlebar, `windowWillClose` fires a deny for whichever pendingDeny survives — cross-wiring clients. Any client whose closures get dropped never has its `withCheckedContinuation` resumed (ServerController.swift:337), hanging that connection task forever, and its ID stays in `activeApprovalDialogs`, so every future connection from that client is silently appended to `pendingApprovals` (429) and never resolved until app restart.
SUGGESTED FIX: Key dialogs by clientID — one window controller slot per pending client (or queue requests so only one is presented at a time and the rest wait), remove the ID from `activeApprovalDialogs` in all resolution paths, and resume every continuation.
CONFIDENCE: HIGH

### 2. 10-second setup reaper kills connections while the human is still reading the approval dialog
SEVERITY: HIGH | LOCATION: App/Controllers/ServerController.swift:745-758
EVIDENCE:
```swift
// Time out stalled setups to avoid orphaned connections.
Task {
    try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
    if self.connectionTasks[connectionID] != nil,
        self.connections[connectionID] != nil { ... await removeConnection(connectionID) }
```
The setup task stays registered in `connectionTasks` until `MCPConnectionManager.start` returns, which blocks on the approval handler — i.e., on a human clicking Allow/Deny. `removeConnection` → `stop()` → `sseSession.close()` finishes all streams (App/Services/Serving/MCPTransportBridge.swift:166-184).
FAILURE SCENARIO: A user takes 11 seconds to decide; the SSE session is torn down under them, the MCP client sees the stream die, and clicking Allow afterwards resumes a continuation into a dead connection. Same-client retries coalesced in `pendingApprovals` are approved into nothing.
SUGGESTED FIX: Pause/extend the timer while an approval dialog is pending for that connection (or arm the timeout only after approval completes), or raise it well past human decision time.
CONFIDENCE: HIGH (mechanism proven by code path; product intent uncertain)

### 3. HTTP bind failure leaves UI claiming "Running"; double restart strands an orphaned listener
SEVERITY: MEDIUM | LOCATION: App/Controllers/ServerController.swift:365-368, 598-630; App/Views/DiagnosticsView.swift:127-134
EVIDENCE: `startServer()` sets `updateServerStatus("Running")` immediately after `networkManager.start()`. Inside the actor, `isRunningState = true` (600) precedes the actual bind; the bind happens asynchronously in `serverTask` and its failure is swallowed: `catch { log.error("HTTP/SSE server failed: ...") }` (623-629) — no status revert, no retry. `start()` also overwrites `self.httpServer` (605) without stopping any previous instance. Diagnostics "Restart Server" (129-130) and `save(restartServer: true)` (ServingSettingsModel.swift:158-164) are unguarded against overlapping invocations.
FAILURE SCENARIO: (a) Port 8756 taken by another process → menu/diagnostics show green "Running" forever while nothing listens. (b) Restart clicked twice quickly → actor interleaves A.stop/B.stop/A.start(X)/B.start(Y); X binds the port but Y replaces the reference, Y dies with EADDRINUSE (only logged), status says Running, and `stop()` can never reach X — the old-config listener serves until process exit.
SUGGESTED FIX: Have the serverTask report terminal failure back through the actor (set isRunningState false + status "Failed"), and make start() stop/nil out any existing httpServer before creating a new one (or refuse if already running).
CONFIDENCE: HIGH

### 4. Stdio bridge permanently 404s after the app-side session is reaped or the app restarts
SEVERITY: MEDIUM | LOCATION: CLI/main.swift:67-88; App/Services/Serving/AppleCoreHTTPServer.swift:640-641, 1177
EVIDENCE: The bridge stores `sessionID` once and replays it on every POST (`if let sessionID { request.setValue(sessionID, ...) }`, 67-69; captured at 78-80). It treats non-200/202 as a one-off error line and never clears the stale id. The server reaps idle sessions after 600 s (`sessionIdleTimeout = 600`, AppleCoreHTTPServer.swift:1177) and answers unknown session ids with 404 ("Session not found", 640-641).
FAILURE SCENARIO: A stdio MCP client sits quiet for >10 minutes, or Apple Core restarts/rebinds (Rotate Token restarts the server via ServingSettingsModel.save). Every subsequent tool call gets 404; `send` prints `apple-core-cli: HTTP 404` to stderr and returns nil, so the client receives no JSON-RPC response and hangs. No recovery exists without restarting the client process.
SUGGESTED FIX: On 404, clear `sessionID` (the next POST without a session header creates a fresh session, AppleCoreHTTPServer resolveSession `.new` path) and emit a JSON-RPC error response so the client can re-initialize.
CONFIDENCE: HIGH

### 5. Claude Desktop config updater can wipe the whole file when its JSON doesn't decode
SEVERITY: MEDIUM | LOCATION: App/Integrations/ClaudeDesktop.swift:161-190, 195-210, 50-56
EVIDENCE: Both load attempts swallow decode errors (`catch { log.error(...) }`, 141-145 and 172-176), leaving `loadedConfiguration == nil`; the fallback fabricates `["mcpServers": .object([:])]` (183-190). `updateConfig` then writes that object over the existing file atomically (276-287). Meanwhile the confirmation dialog promises "Your existing server configurations won't be affected." (50-56). Note the same mistake was already caught and fixed in this repo's own serving config: ServingConfigManager.load logs loudly and refuses to let a save clobber an undecodable file (App/Services/Serving/ServingConfig.swift:123-135).
FAILURE SCENARIO: User hand-edits claude_desktop_config.json and leaves a trailing comma → next "Set Up" click silently replaces the entire file with just the apple-core entry, destroying their other servers and top-level keys.
SUGGESTED FIX: Distinguish "file missing" from "file present but undecodable"; abort with an error message in the latter case, as ServingConfigManager does.
CONFIDENCE: HIGH

### 6. ScreenCaptureFilter.excludeMenuBar is inverted — and the whole enum is dead
SEVERITY: LOW-MEDIUM | LOCATION: App/Extensions/ScreenCaptureKit+Extensions.swift:63-66
EVIDENCE:
```swift
case .excludeMenuBar:
    let nonMenuBarWindows = content.windows.filter { $0.title?.contains("MenuBar") == true }
    return SCContentFilter(display: display, including: nonMenuBarWindows)
```
Keeps only windows whose title contains "MenuBar" — the opposite of excluding the menu bar (and SCWindow titles don't carry "MenuBar"). Repo-wide grep finds zero references to `ScreenCaptureFilter` outside its declaration (Capture.swift uses ContentType/Quality/ScreenshotFormat but never Filter).
FAILURE SCENARIO: Anyone adopting the filter gets a capture containing only supposed menu-bar windows.
SUGGESTED FIX: Delete the enum (dead code); if it is ever revived, invert the predicate and match windows properly.
CONFIDENCE: HIGH (dead), HIGH (inversion)

### 7. launchctl subprocesses run synchronously on the main thread at launch and from Settings
SEVERITY: MEDIUM-LOW | LOCATION: App/App.swift:146-147, 88-100; App/Services/Serving/LaunchAgentManager.swift:31-68 via ProcessShell.swift:13-52
EVIDENCE: `applicationDidFinishLaunching` calls `AppLaunchAgent.installIfNeeded()` (@MainActor, App.swift:25-26), which calls `LaunchAgentManager.isLoaded/bootstrap/restart` — plain static funcs running `runShell("/bin/launchctl", ...)`, and `runShell` blocks on `readDataToEndOfFile()` + `waitUntilExit()` (ProcessShell.swift:36-39). Also reached from the main thread via `ServingSettingsModel.refreshAppLaunchAgentStatus()/installAppLaunchAgent()` (ServingSettingsModel.swift:521-529), called from DiagnosticsView's `.task`.
FAILURE SCENARIO: launchctl stalls (system under load, logind hiccup) → app launch and the Settings UI freeze for the duration; there is no timeout on the child.
SUGGESTED FIX: Run installIfNeeded/isLoaded off the main actor (CloudflareManager already does this correctly by being an actor).
CONFIDENCE: HIGH (mechanism), impact depends on launchctl latency

### 8. CLI cannot talk to a server bound to ::1 — URL construction drops IPv6 brackets
SEVERITY: LOW | LOCATION: CLI/main.swift:126-131
EVIDENCE: `URL(string: "http://\(bindHost):\(port)/")` with bindHost "::1" (a value the app itself supports and advertises — ServingConfig.defaultAllowedOrigins emits `http://[::1]:port`) yields an invalid URL, so the guard exits(1) with "invalid bind host/port".
FAILURE SCENARIO: User sets bindHost to ::1 in config.json; the app serves fine on IPv6 loopback but the stdio bridge refuses to start.
SUGGESTED FIX: Bracket IPv6 literals before interpolation.
CONFIDENCE: HIGH

### 9. ClaudeDesktop hardcodes /Users/<name> instead of the home directory
SEVERITY: LOW | LOCATION: App/Integrations/ClaudeDesktop.swift:7-8
EVIDENCE: `private let configPath = "/Users/\(NSUserName())/Library/Application Support/Claude/claude_desktop_config.json"` — NSUserName() is the account name, not necessarily the home path; every other path in the codebase uses NSHomeDirectory/homeDirectoryForCurrentUser (e.g., MCPClientCatalog.swift:48, App.swift:43).
FAILURE SCENARIO: Home directory not under /Users (network/alternate-volume home) or username ≠ home folder name → load misses the real config and updateConfig's save-panel fallback writes a copy Claude never reads, while reporting success.
SUGGESTED FIX: Build from FileManager.default.homeDirectoryForCurrentUser.
CONFIDENCE: MEDIUM (edge-case environments)

### 10. Date parsing rejects 1-2 digit fractional seconds even though a timezone-less fallback exists
SEVERITY: LOW | LOCATION: App/Extensions/Foundation+Extensions.swift:12-47
EVIDENCE: ISO8601DateFormatter `.withFractionalSeconds` accepts exactly three fractional digits. Input "2026-08-25T10:00:00.5Z" fails option rows 1-6; the local-time fallback is then skipped because the regex at 40-44 sees the trailing `Z` and returns nil.
FAILURE SCENARIO: Calendar/Reminders tools receive ".5Z"-style timestamps (LLMs produce these) and return "unparseable date" despite the function's lenient contract.
SUGGESTED FIX: Normalize fractional digits to 3 (pad/truncate) before the formatter loop.
CONFIDENCE: MEDIUM

### 11. Contact birthday accepts month/day = 0
SEVERITY: LOW | LOCATION: App/Extensions/Contacts+Extensions.swift:104-117
EVIDENCE: `case let .int(day) = birthdayData["day"]` matches 0 and negatives; DateComponents(month: 0, day: 0) is passed straight to `CNContact.birthday`, deferring the failure to save time with a cryptic error.
SUGGESTED FIX: Range-check (1...12, 1...31) before constructing components.
CONFIDENCE: HIGH (code), LOW (real-world frequency)

### 12. Dead declarations (zero callers confirmed by repo-wide grep)
SEVERITY: LOW | LOCATIONS & EVIDENCE:
- `AppDelegate.setShowDockIcon(_:)` App/App.swift:502-514 — no callers anywhere.
- `ServiceConfig.isActivated` App/Controllers/ServerController.swift:34-38 — no callers (services' own `isActivated` is used by ServicePermissionCoordinator, not this wrapper).
- `currentApprovalHandlers` ServerController.swift:211 — write-only (assigned 298/437, never read); symptom of finding 1's lost-handler design.
- `MCPClient.requiresRemoteAccess` App/Integrations/MCPClientCatalog.swift:35 — assigned in all 11 initializers, never read (ClientsPane splits local/cloud arrays instead).
- `ClaudeDesktop.Config` outer struct ClaudeDesktop.swift:20-28 — only the nested `MCPServer` type is used; `Config` itself is never instantiated.
- `AppVersion` App/Views/Components.swift:15-23 — zero references.
- `SCDisplay.displayInfo` / `SCWindow.windowInfo` / `SCRunningApplication.applicationInfo` ScreenCaptureKit+Extensions.swift:99-114 — zero references.
- `ServingSettingsModel.runAsLaunchAgent` / `showDockIcon` @AppStorage wrappers ServingSettingsModel.swift:60-61 — never read by any view (readers use UserDefaults directly).
FAILURE SCENARIO: none live; maintenance drag, and finding 6 shows dead extension code rotting into incorrectness.
SUGGESTED FIX: Delete.
CONFIDENCE: HIGH

## Clean categories
- Retain cycles: no true leaks found. Delegate properties used are system-weak (NSMenu.delegate, NSWindow.delegate); long-lived closures either capture weakly ([weak self] in setSessionFactory/setSessionCloseHandler/sseSession.start) or are transient. Strong self-captures inside ConnectionApprovalWindowController closures form a cycle only between two app-lifetime objects and are cleared on dialog resolution.
- Notification/KVO hygiene: no NotificationCenter observers, Timers, or KVO in scope at all — nothing to leak or mis-key.
- Main-thread violations: server callbacks hop to @MainActor correctly (Task { @MainActor } around showConnectionApprovalAlert); UNUserNotificationCenter completions only log; Cloudflare shell-outs run off-main inside the CloudflareManager actor. Only violation is finding 7.
- Trust-list persistence itself (JSON-encoded Set in UserDefaults) round-trips safely with sane empty-set fallbacks.

## Health summary
The transport and dispatch core (actor-isolated ServerNetworkManager, ResumeGate-guarded continuations, merge-on-save config model) is carefully built and shows evidence of prior review passes. The remaining risk is concentrated in the human-interaction edges: the approval flow assumes one request at a time (findings 1-2), and the CLI bridge assumes sessions never expire (finding 4). One systemic pattern to fix once: single-slot state where a keyed map is needed.
