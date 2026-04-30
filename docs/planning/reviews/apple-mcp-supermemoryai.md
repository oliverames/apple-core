# apple-mcp (supermemoryai) — Review
**URL:** https://github.com/supermemoryai/apple-mcp
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Dhravya Shah (dhravya@supermemory.com); repo lives under the `supermemoryai` org because Dhravya works there. All commits in the history are his.
- **License:** MIT (Copyright 2025 Dhravya Shah)
- **Last commit:** 2025-08-10 (commits in last 90 days: 0)
- **Activity signal:** Active through Aug 2025, then quiet. The Aug 9 2025 "Apple mcp total revamp with tests" commit was a major rewrite; nothing has landed since the README touch-up the next day.
- **Fork relationship:** Not a fork in the sibling sense. This is effectively the same project as Dhravya/apple-mcp, republished under the supermemoryai org. The git history includes merges from `Dhravya/apple-mcp` and `jxnl/apple-mcp`, the package.json `repository` field still points at `dhravya/apple-mcp`, and the manifest author is Dhravya. Treat it as the supermemory-branded mirror of the same upstream — not a meaningful divergence.

## Stack
- **Language / runtime:** TypeScript, Bun for dev (`bun run index.ts`), Node for production (`dist/index.js` after `bun build --target=node --minify`).
- **MCP transport(s):** Stdio only (`StdioServerTransport`); `mcp-proxy` and `@hono/node-server` are pulled in as deps but the entry point wires up stdio.
- **Build / install path:** `bun install`, then `bun run dev` or `bun run build`. Published to npm as `apple-mcp`; `bunx --no-cache apple-mcp@latest` is the documented config.
- **Distribution:** npm package, Smithery listing (`@Dhravya/apple-mcp`), and a prebuilt `apple-mcp.dxt` (~27 MB) attached for one-click Claude Desktop install. macOS only (`compatibility.platforms: ["darwin"]`).

## Apple surfaces covered
- Contacts (Apple Contacts)
- Notes (Apple Notes)
- Messages (iMessage / SMS via Messages app + chat.db)
- Mail (Apple Mail)
- Reminders (Apple Reminders)
- Calendar (Apple Calendar)
- Maps (Apple Maps, including Guides)
- Web search via Safari scraping (utility exists in `utils/web-search.ts` but is not registered as an MCP tool)

## Tool inventory
Seven tools, each operation-multiplexed via an `operation` enum:
- `contacts` — search/list
- `notes` — search, list, create
- `messages` — send, read, schedule, unread
- `mail` — unread, search, send, mailboxes, accounts, latest
- `reminders` — list, search, open, create, listById
- `calendar` — search, open, list, create
- `maps` — search, save, directions, pin, listGuides, addToGuide, createGuide

## How it talks to Apple
Predominantly AppleScript via `run-applescript`, with two targeted exceptions. Contacts, Notes, Mail, Reminders, Calendar, and Messages-send all build AppleScript strings and shell out. Maps uses JXA (`@jxa/run`) for richer object access, with AppleScript UI-automation fallbacks for guide listing. Messages reads from the chat.db SQLite directly via `sqlite3` shelled from Node (`~/Library/Messages/chat.db`) for read/unread/scheduled queries, then uses AppleScript only to actually send. Web search drives Safari through AppleScript and scrapes the resulting DOM. No native Swift helper, no EventKit/Contacts framework binding.

## Permissions / TCC model
Unsigned Node/Bun process, so the user grants TCC permissions to whatever terminal/host runs it (Claude Desktop, iTerm, etc.). Each util has a `checkXAccess`/`requestXAccess` preflight that runs a trivial AppleScript (`tell application "X" to return name`) and, on failure, returns a human-readable instruction string telling the user to open System Settings > Privacy & Security > Automation. Full Disk Access is required for Messages because of the chat.db reads, though that is not stated in the README. No entitlements file, no signing, no sandboxing.

## Testing posture
A real Bun test suite under `tests/integration/` covering all seven surfaces (~2,000 lines), plus `tests/helpers/test-utils.ts` and a `test-runner.ts` orchestrator. Tests are integration-style — they hit the live macOS apps — so they need a configured machine to actually pass. There is no GitHub Actions workflow (`.github/workflows/` does not exist; only `FUNDING.yml` is present), so nothing runs in CI.

## Notable strengths (worth stealing)
- **Eager-load with timeout fallback to lazy "safe mode"** in `index.ts`: the server tries to import all utils on boot, but if loading exceeds 5 seconds it flips a flag and switches to per-call dynamic imports. Useful pattern for an MCP that touches flaky native APIs.
- **Per-surface preflight with human-actionable error strings**: every util has the `checkAccess`/`requestAccess` pair that returns a paragraph explaining exactly which Privacy pane to visit. Much friendlier than a raw osascript exit code.
- **Hybrid sqlite + AppleScript for Messages**: reading via chat.db is dramatically faster than scripting Messages.app, and writing via AppleScript avoids touching a write-locked database. Sensible split.
- **Operation-multiplexed tool shape**: seven tools instead of dozens keeps the LLM's tool list small while still exposing rich verbs through a discriminated `operation` field. Easier prompt economy than one-tool-per-verb.
- **DXT bundling**: ships a Claude Desktop one-click `.dxt` artifact alongside the npm package — concrete reference for how to package an MCP for non-developer users.

## Gotchas / things to avoid
- **AppleScript string concatenation for user-supplied content** (note bodies, message text, email subjects) with no consistent escaping helper. A note title with an unescaped quote will crash the script; worse, it is a script-injection surface.
- **Unsigned `bunx`-from-network execution model**: the documented install runs `bunx --no-cache apple-mcp@latest` on every launch, meaning the user re-downloads npm code that gets full Automation, Contacts, Mail, and chat.db access. Reproducibility and supply-chain posture are both poor.
- **No CI**: 2,000 lines of integration tests sit unrun on GitHub. Combined with the rapid-fire "fix", "fix: merge", "readme pudate" commits in Aug 2025, regressions are likely silent.
- **Stalled since Aug 2025**: nine months of no commits, while macOS Tahoe has shipped AppleScript and Messages changes. The mail-search and reminder fixes earlier in 2025 suggest Apple breaks this code regularly.
- **Web search util is dead code**: `utils/web-search.ts` exists but is not in `tools.ts`, so it never reaches the MCP surface. Easy to assume it works and find out otherwise.

## License compatibility for our combined project
MIT — fully compatible with an MIT or Apache-2.0 combined project, requiring only attribution.

## Verdict
Functionally identical to Dhravya/apple-mcp because it is the same project under a different org name, with the additional Aug 2025 revamp that added the integration test suite and DXT packaging. Prefer this URL over the older Dhravya remote for the test scaffolding and DXT artifact, but expect the same staleness and the same AppleScript fragility — neither is meaningfully maintained right now.
