# Adversarial repo review — 2026-08-25

Full-repo bug pass at commit `e5137be`. Five independent finders reviewed distinct angles
(serving stack, service layer, app shell/UI, scripts/CI/appcast, docs/dead code). Every
finding then went to an independent skeptic whose default stance was refute; verdicts below
reflect that second pass. Baseline before the pass: build green, 41 unit tests green,
`swift format lint --strict` red with 24 errors (fixed in `e5137be`).

## Dispositions

| ID | Finding | Sev | Verdict | Disposition |
|---|---|---|---|---|
| A1 | Unauthenticated handlers buffer full request body before the size cap (FlyingFox has no internal cap) | high | confirmed | fixed |
| A2 | Remote-access wizard saves config but never restarts server; live issuer/origin allowlist stay stale until relaunch | high | confirmed | fixed |
| A3 | OAuth tokens can never authorize `/sse`/`/message`; WWW-Authenticate points at a nonexistent metadata route | med | confirmed | fixed |
| A4/C2 | 10 s setup reaper tears down connections while the human approval dialog is open; continuation leaks | med/high | confirmed | fixed |
| A5 | `runShellDetached` leaks a zombie process per Cloudflare login | low | confirmed | fixed |
| A6 | IPv6 bind host produces malformed cloudflared ingress URL (`http://::1:8756`) — invalid URL, YAML stays valid | low | partial | fixed |
| A7 | `ensureDNSRoute` treats any "already exists" failure as routing success, even when record points elsewhere | med | confirmed | fixed |
| A8 | Blocking shell-outs and `Thread.sleep` inside actor-isolated methods stall the cooperative pool | low | confirmed | fixed (main-thread half first, actor half in follow-up `cf80869`: async runShell + LaunchAgent wrappers, every CloudflareManager shell path awaits) |
| A9 | Session-cap check races past `maxSessions` across the factory await | low | confirmed | fixed |
| A10/C3 | Bind failure leaves menu bar reporting "Running"; overlapping `start()` strands an orphaned listener | med | confirmed | fixed |
| A11 | stdio CLI bridge wedges permanently after the server reaps its idle session (silent 404 loop) | med | confirmed | fixed |
| A12 | CLI cannot build URL for IPv6 `bindHost` from config and exits | low | confirmed | fixed |
| B1 | Integer JSON values rejected/mishandled by Weather, Maps, Location, Calendar proximity alarms, Capture (`case .double` / `.doubleValue` vs SDK decoding ints as `.int`) — schemas declare `"number"` so clients are spec-compliant | high | confirmed | fixed |
| B2 | Calendar/Reminders create silently fall back to default calendar when requested name doesn't match (update path throws) | med | confirmed | fixed |
| B3 | `messages_fetch` limit has no ceiling; huge limits reach madrid's `Int32(limit)` conversion → memory blowup or crash | med | confirmed | fixed |
| B4 | One-sided `start`/`end` on `messages_fetch` silently ignored → unfiltered results presented as time-scoped | med | confirmed | fixed |
| B5 | Shortcuts `capture()` reads pipes only after termination → deadlock over 64 KB output; no timeout | med | confirmed | fixed |
| B6 | `filesystem_read` loads entire file before applying 512 KB cap; mid-codepoint truncation misclassifies text as binary | med | confirmed | fixed |
| B7 | Unknown status/availability strings silently become `.none`/`.busy` filters | low-med | confirmed | fixed |
| B8 | `mail_list_messages` promises "(newest first)" but sorts nothing | low | confirmed | fixed |
| B9 | Missing lists table silently drops list filter in `reminders_sections` (sections-table twin throws) | low | confirmed | fixed + test |
| B10 | `notes_stats` converts query failures into zero counts | low | confirmed | fixed |
| B11 | `messages_unread` sums unread after SQL LIMIT truncation, labels it totalUnread | low | confirmed | fixed + test |
| B12 | Dangling-symlink final component passes containment for out-of-process writes (Mail/Notes/Shortcuts) | low-med | partial | fixed in follow-up (`e83957d`): lstat the final component, throw `danglingSymlink`; regression test added |
| B13 | `LocationService.activate` overwrites pending continuation (leak/hang); `latestLocation` unsynchronized | low | confirmed | fixed |
| C1 | Concurrent approval dialogs clobber shared slots; stranded client locked out until restart | high | confirmed | fixed |
| C4 | ClaudeDesktop updater wipes undecodable config despite "won't be affected" promise | med | confirmed | fixed |
| C5 | `excludeMenuBar` predicate inverted; whole `ScreenCaptureFilter` enum dead | low-med | confirmed | removed |
| C6 | launchctl runs synchronously on main thread at every launch and Diagnostics refresh | med-low | confirmed | fixed |
| C7 | Hardcoded `/Users/<name>` config path instead of home directory API | low | confirmed | fixed |
| C8 | ISO8601 parser rejects non-3-digit fractional seconds | low | **refuted** | none — empirically parsed .5/.12/.123456 fine |
| C9 | Birthday month/day = 0 accepted, fails late at save | low | confirmed | fixed |
| S1 | `find_sign_update` searches wrong DerivedData root; glob can match legacy DSA signer or other projects' copies | med | confirmed | fixed |
| S2 | Appcast enclosure URL hardcodes repo + asset name, ignoring GITHUB_REPOSITORY/APP_NAME overrides | med | confirmed | fixed |
| S3 | RELEASING.md documents nonexistent `--print-sign-update-path` flag | low | confirmed | fixed |
| S4 | Local `release.sh release` discards curated notes CI prefers | low | confirmed | fixed |
| S5 | Crash between appcast write and re-sign leaves stale-signed feed the duplicate guard refuses to repair | low | confirmed | fixed |
| S6 | RELEASING.md implies DMG distribution nothing produces | low | confirmed | fixed |
| D1 | README "fresh install advertises 101 tools" wrong: only Maps+Utilities default on → 11 | med | confirmed | fixed |
| D2 | WEATHERKIT_AVAILABLE defined nowhere; Weather excluded from Debug too | info | confirmed | doc wording |
| D3 | DONORS.md still describes XPC transport that never shipped | med | confirmed | fixed |
| D4 | Plan docs say chat.db picker dropped; code ships picker+bookmark | low-med | confirmed | fixed |
| D5 | MCP_COMPLIANCE.md cites stale 81/77 tool totals as current audit results | low | confirmed | stamped historical |
| DC1 | Six dead methods on ServingSettingsModel (+ cascades) | med | confirmed | removed |
| DC2 | Three dead Contacts label arrays | low | confirmed | removed |

Additional real bugs found during verification, also fixed:

- Approval handler installed only after the network manager starts listening; a client
  arriving in the gap is rejected outright (startup race).
- Startup reconciliation saves merged config after the server froze its snapshot (same
  class as A2).
- `ServingConfigManager.load` refuses to clobber undecodable config, but
  `bootstrappedServingConfig` treats the nils as "changed" and overwrites the corrupt file
  on next launch anyway.
- `messages_fetch` with limit ≤ 0 silently returns empty.
- Calendar create skips the writability check the update path performs.
- `maps_explore` limit unclamped (consistency).
- `statusResponse` hardcodes `http://localhost:` regardless of bindHost.

Deferred items from the first pass were all subsequently resolved the same day:

- **B12 symlink hardening** — `FilesystemAccess.resolve` now lstats the final
  component and throws `danglingSymlink` instead of blessing a raw name whose
  link target it cannot see; covered by a new test (`e83957d`).
- **Reflected-Origin CORS** — kept, deliberately, and documented where it
  lives: browser-based public OAuth clients need cross-origin registration
  and code exchange, and those endpoints carry no ambient credentials, so
  reflection leaks nothing while allowlisting them would break legitimate
  third-party clients. The concrete defect hiding inside the finding was
  caching correctness, fixed with `Vary: Origin` on every reflected response
  (`4c2e944`). The origin allowlist continues to govern the data-bearing MCP
  routes only.
- **Actor shell-out offload (A8)** — `runShellAsync` plus LaunchAgentManager
  async wrappers; all CloudflareManager paths touching cloudflared or
  launchctl now suspend instead of pinning pool workers (`cf80869`).
- **Abandoned approval dialogs** (skeptic incidental) — a connection that
  drops mid-decision now denies its stranded request through the Deny path,
  closes the window, and presents the next queued one (`4517697`).

Dependency currency was verified against upstream release APIs on 2026-08-25:
Sparkle upgraded 2.9.4 → 2.9.6 for two security fixes including a
privilege-escalation path (`b081a1d`); FlyingFox 0.27.1 is current; the
swift-sdk revision pin is exactly its 0.12.1 release commit. The MCP
specification has since advanced to 2026-07-28 while the SDK targets
2025-11-25; tracking that is upstream work, and the Tasks extension for
long-running tools remains the notable future capability gap.

## Verification method

Finders were read-only subagents scoped by area. Skeptics re-read every cited file, checked
third-party behavior against the resolved package checkouts (FlyingFox 0.27.1,
swift-sdk MCP, madrid, JSONSchema), and empirically tested parser claims where possible.
One finding (C8) died under empirical refutation; two others were confirmed with framing
corrections (A6, A10). Search surface for dead-code claims: `rg` across Swift sources
excluding `dist/`, worktrees, and scratch files; tests referencing a symbol count as alive.
