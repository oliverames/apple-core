# apple-mcp (Dhravya) — Review
**URL:** https://github.com/Dhravya/apple-mcp
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Dhravya Shah (supermemory.ai); npm package `apple-mcp` (v1.0.0).
- **License:** MIT (Copyright 2025 Dhravya Shah).
- **Last commit:** 2025-08-10 (commits in last 90 days: 0).
- **Activity signal:** Dormant since August 2025. Recent history shows a "total revamp with tests" plus DXT bundling, then trickling README polish. The README itself points users to supermemory's fork, suggesting the author has shifted focus there.

## Stack
- **Language / runtime:** TypeScript on Bun (with Node fallback via `bun build` to `dist/index.js`).
- **MCP transport(s):** stdio only (`StdioServerTransport`); `mcp-proxy` is a dependency but only stdio is wired in `index.ts`.
- **Build / install path:** `bun install && bun run index.ts` for dev; `bun run build` produces a minified `dist/index.js`. Published to npm as `apple-mcp`, installable via `bunx apple-mcp@latest` or Smithery (`npx -y install-mcp apple-mcp`).
- **Distribution:** npm + Smithery + a 27 MB pre-built `apple-mcp.dxt` (Claude Desktop one-click installer) committed at the repo root.

## Apple surfaces covered
- Contacts (read/search)
- Notes (read/search/create)
- Messages / iMessage (send, read, schedule, unread)
- Mail (unread, search, send, list mailboxes/accounts, latest)
- Reminders (list, search, open, create, listById)
- Calendar (list, search, open, create)
- Maps (search, save, directions, pin, list/add/create guides)
- Web search via Safari (utility module, not exposed as a tool)

## Tool inventory
Seven MCP tools, each polymorphic via an `operation` enum:
- `contacts` — name search / list-all
- `notes` — search | list | create
- `messages` — send | read | schedule | unread
- `mail` — unread | search | send | mailboxes | accounts | latest
- `reminders` — list | search | open | create | listById
- `calendar` — search | open | list | create
- `maps` — search | save | directions | pin | listGuides | addToGuide | createGuide

## How it talks to Apple
Almost everything is AppleScript executed via `run-applescript`, with each util module wrapping a `tell application "X"` block (`Notes`, `Contacts`, `Mail`, `Reminders`, `Calendar`, `Messages`). The Maps module is the exception: it uses `@jxa/run` for JXA bindings, which is a better fit for Maps' richer object model. The Messages module also reads `~/Library/Messages/chat.db` directly via `sqlite3 -json` shelled out through a Node child-process helper for read/unread/scheduled queries. Scheduled messages are persisted to a JSON file on disk and triggered by a cron-style background loop. Web search drives Safari via AppleScript navigation and DOM scraping with a spoofed user-agent.

## Permissions / TCC model
Unsigned Node script; relies entirely on macOS TCC prompts triggered by AppleScript/JXA invocation. Each util has a `checkXAccess()` probe and a `requestXAccess()` helper that returns human-readable instructions ("Open System Settings, Privacy and Security, Automation, enable Notes...") rather than attempting programmatic entitlement requests. Messages additionally needs Full Disk Access for `chat.db` reads. No entitlements file, no code signing, no privacy manifest.

## Testing posture
A meaningful Bun-test suite under `tests/integration/` covering all seven surfaces (contacts, messages, notes, mail, reminders, calendar, maps), plus `tests/mcp/handlers.test.ts`. Driven by a `test-runner.ts` orchestrator with per-surface npm scripts. Tests are real integration tests that touch live macOS apps (e.g., creating a Note in a "Claude" folder with a timestamped title), so they are not hermetic. There is **no CI configuration** (no `.github/workflows`); the suite must be run locally on a Mac with permissions granted.

## Notable strengths (worth stealing)
- **Lazy module loading with eager-loading fallback** in `index.ts` (~1720 lines): avoids paying the AppleScript bridge cost for surfaces the user never touches, with a watchdog timer that flips to "safe mode" if startup hangs.
- **Phone-number normalization helper** in `utils/message.ts` that produces multiple format candidates (`+1XXXXXXXXXX`, `1XXX...`, `XXX...`) for fuzzy iMessage buddy matching.
- **Polymorphic-tool pattern** (one `operation` enum per surface) keeps the tool count low (7), which is friendly for models with limited tool-budget windows.
- **Friendly TCC failure messages**: instead of cryptic osascript errors, every util short-circuits with step-by-step System Settings instructions when access is denied.
- **Pre-built DXT** committed in-repo: makes the Claude Desktop install path one-click without a release pipeline.

## Gotchas / things to avoid
- **Repo is dormant** (no commits since 2025-08-10) and the README itself points users at supermemory's fork; treat this as the historical source, not the active line.
- **String-interpolated AppleScript** with only ad-hoc `replace(/"/g, '\\"')` escaping (e.g., `sendMessage`); a message body containing a backslash, newline, or curly-quote can break or inject script.
- **27 MB binary `.dxt` checked into git** bloats clones; should live on a Releases page, not main.
- **No Sendable / no zod validation at the tool boundary** despite zod being a declared dep; args are hand-validated with type guards, so schema drift between `tools.ts` and util signatures is easy to introduce.
- **`web-search.ts` exists but is never registered as a tool**, and it scrapes Google via Safari with a spoofed UA; a fragile and ToS-adjacent path to leave as dead code.

## License compatibility for our combined project
MIT, fully compatible with an MIT or Apache-2.0 combined project; preserve the copyright notice.

## Verdict
The original Apple-surface MCP and still the canonical reference for the AppleScript-per-surface pattern, with the broadest coverage (7 tools incl. Maps) of any candidate. Best used in synthesis as a feature-checklist and as a source of specific AppleScript snippets, not as the active upstream; supermemory's fork should be the live base.
