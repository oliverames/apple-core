# apple-mail-mcp — Review
**URL:** https://github.com/imdinu/apple-mail-mcp
**Reviewed:** 2026-04-30

## Identity
- **Author / maintainer:** Ioan-Mihail Dinu (iodinu@icloud.com), GitHub `imdinu`. Active solo maintainer.
- **License:** GPL-3.0-or-later (LICENSE file is the standard GPLv3 text).
- **Last commit:** 2026-04-13 (commits in last 90 days: 31)
- **Activity signal:** Very active. Tagged releases v0.1.2 → v0.2.2 in the last quarter, with CHANGELOG, GitHub Actions CI, MkDocs docs site, PyPI Trusted Publisher pipeline, and a benchmark harness against six competitors.

## Stack
- **Language / runtime:** Python 3.11+ (type hints, ruff, async). Embeds JXA (JavaScript for Automation) snippets executed via `osascript`.
- **MCP transport(s):** stdio via `fastmcp` (>=3.0.0b1).
- **Build / install path:** Hatchling backend, `pipx install apple-mail-mcp`. Dev: `uv sync`, `uv run pytest`. Optional `[watch]` extra pulls `watchfiles`.
- **Distribution:** PyPI (sdist + wheel) plus `server.json` for MCP registries. Tag-push release pipeline.

## Apple surfaces covered
Apple Mail only — accounts, mailboxes, messages, attachments, links. README explicitly positions itself as the Mail-portion replacement for the archived supermemoryai/apple-mcp.

## Tool inventory
- `list_accounts()` — list configured Mail accounts.
- `list_mailboxes(account?)` — list mailboxes per account.
- `get_emails(filter?, limit?)` — filters: `all`, `unread`, `flagged`, `today`, `last_7_days`.
- `get_email(message_id)` — full content + attachment metadata via a 4-strategy cascade (disk → JXA-by-mailbox → index lookup + JXA → iterate-all-mailboxes).
- `search(query, scope?, before?, after?, highlight?, limit?, offset?)` — scopes: `all`, `subject`, `sender`, `body`, `attachments`; date range, FTS5 highlighting, pagination.
- `get_email_links(message_id)` — extract links from an email body.
- `get_email_attachment(message_id, filename)` — extract attachment content.
- `get_attachment(...)` — deprecated alias.

All tools also exposed as JSON-emitting CLI subcommands, plus admin commands `index`, `status`, `rebuild`, `serve`, and `integrate claude` (writes a Claude Code skill file).

## How it talks to Apple Mail
Hybrid, three-path architecture:
1. **Disk-first `.emlx` parsing of `~/Library/Mail/V10/`.** `index/disk.py` walks the per-account `*.mbox/Data/.../Messages/*.emlx` tree, parses MIME with stdlib `email` + BeautifulSoup, and reads the trailing plist footer to recover Mail.app's flag bitmask (bit 0 = read, bit 4 = flagged). Version directory auto-detected (V10/V11+).
2. **FTS5 SQLite cache** at `~/.apple-mail-mcp/index.db` (schema v4): `emails`, `attachments`, `sync_state`, plus an external-content `emails_fts` virtual table (`porter unicode61`). State reconciliation between `get_disk_inventory()` and `get_db_inventory()` computes NEW/DELETED/MOVED diffs in <5s, replacing a 60s JXA sync. Optional `watchfiles` watcher keeps it live.
3. **JXA via `osascript -l JavaScript`** for live ops and fallbacks. A shared `MailCore` facade (`jxa/mail_core.js`) does batch property fetching (documented at 87× faster than per-message iteration); a `QueryBuilder` constructs scripts from Python with `json.dumps()` for safe interpolation. Mail's own `~/Library/Mail/.../Envelope Index` SQLite is also read for metadata.

No IMAP, no Spotlight — full-text body search is FTS5 over the project's own index, which is what underwrites the ~20ms body-search numbers vs AppleScript-only competitors.

## Permissions / TCC model
- **Full Disk Access** required to read `~/Library/Mail/V10/`; README and CLAUDE.md call this out and tell the user to grant FDA to Terminal.
- **Automation/Apple Events** prompt for Mail.app on first JXA call (osascript is the host).
- Unsigned pipx install, no notarization or entitlements; index DB created with 0600 perms.

## Testing posture
Solid for a solo project: 13 `test_*.py` files mirroring the modules plus a `test_v016.py` regression suite, `pytest-asyncio` configured. CI runs lint only (`ruff check` + `format --check`); pytest is local because it needs macOS + Mail.app.

## Notable strengths (worth stealing)
1. **Disk-first single-email read.** Strategy 0 parses `.emlx` directly in 1–5ms, bypassing JXA when the index knows the path; the cascade falls back to JXA, then index-assisted JXA, then full iteration.
2. **State-reconciliation sync.** Two cheap walks keyed on `(account, mailbox, msg_id)` produce add/delete/move diffs deterministically — simpler than diffing AppleScript snapshots, and it catches deletions/moves that JXA-only servers miss.
3. **FTS5 external-content table with sync triggers.** `emails_fts` shares storage with `emails`, triggers keep them aligned, and search escapes FTS5 special characters via regex; highlighting and pagination are first-class.
4. **`MailCore` JXA facade with batch property fetching.** One shared JS object fetches property arrays in a single IPC round-trip — the canonical fix for AppleScript iteration slowness.
5. **Real benchmark harness.** `benchmarks/` runs a JSON-RPC stdio MCP client across seven competitors and emits Plotly charts; lift wholesale to validate any combined server's performance claims.

## Gotchas / things to avoid
1. **GPL-3.0-or-later.** Strong copyleft, incompatible with an MIT/Apache-2.0 combined release. Single biggest blocker.
2. **FDA is non-optional for fast paths.** Without Full Disk Access the indexer can't read `.emlx`, Strategy 0 fails, and the server degrades to JXA-only. Plan a guided permission flow.
3. **`message_id` is per-mailbox, not global.** Schema enforces `UNIQUE(account, mailbox, message_id)`; any consumer caching IDs across mailboxes will collide.
4. **JXA per-message iteration is an order-of-magnitude trap.** CLAUDE.md flags an 87× slowdown from naive `for msg of inbox.messages()` loops; anything new must go through `MailCore.batchFetch`.
5. **Index drift.** Defaults cap at 5,000 emails per mailbox with a 24h staleness window; excluded mailboxes (default `Drafts`) won't return search hits; watcher mode is opt-in via the `watchfiles` extra; a future Apple Mail storage-format bump can still surprise the parser.

## License compatibility for our combined project
Incompatible with an MIT or Apache-2.0 combined release: GPL-3.0-or-later would force the whole combined work to GPL, so we should treat this repo as a reference to study and reimplement, not vendor.

## Verdict
The most technically polished Mail-specific MCP in the field — disk-first `.emlx` parsing, FTS5 cache, state-reconciliation sync, and a benchmark suite that proves its 5–20ms claims. Likely role: a reference implementation whose architecture (strategy cascade, batch JXA via shared MailCore, disk-diff sync, FTS5 schema) we reimplement under our own license, since GPL-3.0 blocks direct vendoring.
