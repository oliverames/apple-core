# Fourth runtime bug-fix pass: 2026-08-27

## Scope

This pass reviewed the launched macOS app, Streamable HTTP transport, bundled CLI, numeric tool inputs, onboarding, LaunchAgent recovery, filesystem roots, OAuth storage, and release automation.

Live checks used an isolated config directory on port 49811. The review did not change the production Cloudflare tunnel, DNS record, credentials, or personal Apple data. A temporary tunnel agent created during onboarding inspection was booted out, and its unique LaunchAgent file was moved to the Trash.

## Reproductions

- A bundled CLI process left one active MCP session after stdin reached EOF.
- `Int(1e300)` trapped with exit status 133, so unbounded JSON numeric conversion could terminate the process.
- A Streamable HTTP GET without a session identifier could allocate a session that no client could address.
- Duplicate persisted OAuth client identifiers could trap during dictionary construction.
- A shared root replaced by a symlink could retarget access after approval.
- The onboarding access step could advance or repeat while an asynchronous remote-access operation was active.

## Confirmed fixes

### Transport and numeric input

1. The bundled CLI sends an authenticated `DELETE /mcp` request when stdin closes.
2. Streamable HTTP GET requests reject missing, empty, and whitespace-only session identifiers without allocating a session.
3. Fractional and out-of-range numeric JSON-RPC identifiers are rejected before session allocation.
4. A headerless POST creates a session only for an `initialize` request, so notifications and other requests cannot exhaust the session pool.
5. Capture and Weather use finite, clamped numeric conversion instead of trapping `Int` initializers.
6. Capture identifiers require an exact `UInt32`, JPEG quality stays within range, and recording duration is bounded.
7. Weather date ranges and forecast counts are bounded, and every coordinate entry point validates latitude and longitude.

### Stored state and process recovery

8. Duplicate OAuth client records resolve deterministically instead of trapping at startup.
9. Filesystem access rejects a shared root replaced by a symlink that targets another directory.
10. LaunchAgent restart reports bootout failure when the old job remains loaded instead of reporting a false successful restart.

### Settings and onboarding

11. Onboarding initializes its remote-access choice from current state before an asynchronous refresh can overwrite user input.
12. Access setup and removal have one guarded in-flight action, and navigation stays disabled until the action completes.
13. Local-only onboarding stops an enabled temporary tunnel before advancing and restores the remote choice when removal fails.
14. Manual-hostname guidance takes precedence over generic remote-access errors.
15. Local endpoint rendering brackets bare IPv6 bind addresses.
16. Token-rotation copy distinguishes bearer-token clients from OAuth clients.

### Build and release automation

17. The CI cache key records the runner image version from the shell environment.
18. Release packaging respects an explicit `APP_BUNDLE` path.
19. Tag publication requires the tag to match the current main or master commit and pushes the branch and tag atomically.
20. LLVM `*.profraw` output is ignored, and the accidentally tracked empty artifact is removed.

## Regression coverage

New tests cover extreme and non-finite numeric values, geographic bounds, exact capture identifiers, duplicate OAuth records, malformed JSON-RPC numeric identifiers, retargeted shared roots, and LaunchAgent bootout failure.

## Live verification

- The launched Debug app reported a local-only endpoint and zero active sessions.
- Missing, empty, and whitespace-only MCP session headers returned HTTP 400 and left zero sessions.
- Headerless notifications and non-initialize requests returned HTTP 400 and left zero sessions.
- Fractional and oversized numeric JSON-RPC identifiers returned HTTP 400 and left zero sessions.
- The bundled CLI raised the session count from zero to one during initialization, exited successfully at EOF, and returned the count to zero.
- The read-only harness enumerated 106 unique tools with 106 output schemas from server version 1.1.0, then left zero sessions.
- The Settings Clients pane rendered successfully in the launched app.

## Final repository verification

- The complete Debug test suite passed with no failures.
- Strict recursive Swift format lint passed.
- Debug static analysis passed.
- The unsigned Release build passed.
- Shell syntax, release-script help, workflow YAML, the Xcode project file, and the final diff passed their checks.

## Deferred findings

- Trusted-client approval relies on a self-reported name. A robust fix needs an authenticated identity protocol.
- The stdio bridge does not forward server notifications or concurrent cancellation. A fix needs a bidirectional transport loop.
- Cloudflare adoption does not verify an existing DNS record against the tunnel before reuse.
- OAuth accepts a noncanonical resource value, and revocation behavior needs a product decision.
- Quarantine removal trusts the configured `cloudflared` path without first establishing publisher identity.
- Config save failures are not visible enough in Settings.
- Signed appcast release-note links remain relative. Correcting them requires a release update and a newly signed feed.
