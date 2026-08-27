# Runtime bug-fix pass, 2026-08-27

## Scope

This pass launched the Debug app, inspected its rendered Settings window, probed the live loopback HTTP server, and ran the read-only integration enumeration. It then reviewed the runtime paths implicated by those observations. It did not call Apple-service tools, change personal Apple data, edit the live Apple Core config, or alter Cloudflare resources.

Three independent read-only reviewer tasks were queued for UI, serving, and Apple-service code. All three were blocked before inspection by the account usage limit, so this pass does not count them as completed skeptic reviews. Each accepted finding instead required a direct live reproduction plus a second code or platform check.

## Runtime evidence

- The Debug app built and launched from the project-local DerivedData path.
- The app remained running, listened on `127.0.0.1:8756`, and rendered the Services pane instead of a blank window.
- An isolated profile rendered Services, Clients, Access, and Diagnostics. Local controls remained available, remote controls reflected the disabled isolated setting, and the diagnostics sheet reported the expected running server and unloaded background agent.
- Read-only MCP initialization advertised 101 unique tools, all with output schemas, from server version 1.1.0.
- The unauthenticated landing page, favicon routes, OAuth metadata, authenticated status route, forbidden-origin response, and unknown-route response returned the expected status and payload types.
- Five invalid JSON-RPC bodies returned HTTP 400 without allocating a session. The read-only integration run then returned the active-session count to zero.

## Confirmed findings and fixes

### 1. A persistent launchctl disable override blocked an enabled tunnel

The live config said remote access was enabled, but `launchctl print-disabled gui/501` marked the Cloudflare job disabled and no job was loaded. Launch logs showed repeated bootstrap attempts. The local `launchctl` manual confirms that a disabled service cannot load until it is enabled, and that this override persists across boots.

`LaunchAgentManager.bootstrap` now runs `launchctl enable` for the exact service target before `bootstrap`. A fake command-runner test proves the command order without touching the live launchd domain.

### 2. Malformed JSON allocated an MCP session and returned 202

An authenticated POST containing only `{` returned HTTP 202 and raised the active-session count. The MCP transport accepts one valid JSON-RPC request, notification, or response per POST. Invalid JSON is not an accepted notification.

The HTTP handler now classifies the body before session resolution. It returns HTTP 400 for malformed JSON, scalars, batches, missing JSON-RPC versions, invalid IDs, and invalid response envelopes. Unit tests cover valid requests, notifications, responses, and each rejected class.

### 3. The integration harness leaked its live session

One successful read-only enumeration left one active server session. Repeating the harness could consume the 64-session limit until the ten-minute idle reaper ran.

The client now sends `DELETE /mcp` in a `finally` block. Token loading also honors `APPLECORE_CONFIG_HOME`, so the same harness can verify an isolated app profile.

If cleanup fails after another test error, the harness now preserves the original failure and reports cleanup separately.

### 4. The run verifier accepted any process named Apple Core

The `--verify` path used `pgrep -x "Apple Core"`. An installed copy could satisfy that check even if the just-built bundle failed to launch.

The verifier now compares the running process command with the exact Debug executable path and reports when another copy may be blocking launch. The run path also forwards `APPLECORE_CONFIG_HOME` through LaunchServices, which permits an isolated runtime profile.

## Refuted candidates

- The first endpoint probe reported missing `Content-Type` headers because BSD `awk` did not honor the probe's case-insensitive flag. Direct header inspection showed correct content types on HTML, icon, OAuth, JSON, and error responses.
- A public OAuth issuer while no cloudflared process was running was not caused by a disabled Cloudflare setting. The live setting was enabled, and the persistent launchctl override explained the mismatch.
- Clients displayed `localhost` while Access displayed `127.0.0.1`. This did not expose a connection defect: both are permitted loopback origins, `localhost` fell back to the active IPv4 listener, and the server deliberately normalizes loopback status URLs to `localhost`.

## Final verification

- Strict Swift formatting, shell syntax, Python compilation and help output, project-file lint, appcast XML validation, Sparkle signature validation, and `git diff --check` passed.
- The complete test suite passed 47 test declarations and 58 parameterized executions with no failures, skips, expected failures, or runtime warnings.
- Static analysis passed, and an unsigned Release configuration built successfully.
- The final isolated app launch advertised 101 tools with 101 output schemas. Malformed JSON returned HTTP 400, and session counts remained zero after invalid input, an intentionally failed integration run, and a successful integration run.
- The isolated app was stopped, and its temporary profile and test result bundle were moved to the Trash after verification.
