# apple-mcp-synthesis

Review and design pass for a combined Apple-services MCP server. **No implementation in this directory** — only per-repo reviews and a synthesis design doc to drive the build.

## What this is

We reviewed seven Apple-related MCP server projects, scored their coverage and architecture, and produced a synthesis recommending a hybrid TypeScript-frontend + Swift-sidecar design for our own combined server.

## Repos reviewed

Cloned to `repos/` (shallow, depth 50):

1. [`iMCP`](repos/iMCP) — mattt — Swift native, signed sandboxed app
2. [`mcp-server-apple-events`](repos/mcp-server-apple-events) — FradSer — TS + Swift sidecar (Reminders/Calendar)
3. [`icloud-mcp-mrgo2`](repos/icloud-mcp-mrgo2) — MrGo2 — Node, AppleScript + IMAP/CalDAV/CardDAV
4. [`icloud-mcp-adamzaidi`](repos/icloud-mcp-adamzaidi) — adamzaidi — Node, ~70 tools over IMAP/SMTP/CalDAV/CardDAV
5. [`apple-mcp-supermemoryai`](repos/apple-mcp-supermemoryai) — supermemoryai (= Dhravya) — Bun/TS, AppleScript-heavy
6. [`apple-mcp-dhravya`](repos/apple-mcp-dhravya) — Dhravya — same project as above, original org
7. [`apple-mail-mcp`](repos/apple-mail-mcp) — imdinu — Python, disk-first `.emlx` + FTS5 (GPL-3.0)

## What's here

```
apple-mcp-synthesis/
├── README.md            ← this file
├── SYNTHESIS.md         ← the design doc — start here
├── repos/               ← shallow clones of all seven projects
└── reviews/             ← one structured review per repo
    ├── iMCP.md
    ├── mcp-server-apple-events.md
    ├── icloud-mcp-mrgo2.md
    ├── icloud-mcp-adamzaidi.md
    ├── apple-mcp-supermemoryai.md
    ├── apple-mcp-dhravya.md
    └── apple-mail-mcp.md
```

## How to read it

Start with [`SYNTHESIS.md`](SYNTHESIS.md) — it has the feature matrix, the recommended stack, and the lift list with attribution. The per-repo reports under `reviews/` are the primary sources.

## Bottom line

Recommended stack: **TypeScript MCP frontend + per-surface Swift sidecars** (ad-hoc signed with hardened runtime, à la FradSer's `mcp-server-apple-events`), plus IMAP/CalDAV/CardDAV for iCloud-server paths and direct SQLite reads for `chat.db`. Keychain for credentials. See `SYNTHESIS.md` §5 for reasoning and §6 for the lift list.

License flag: `apple-mail-mcp` is GPL-3.0-or-later. We can study its architecture (disk-first `.emlx` parse + FTS5 cache + state-reconciliation sync) but cannot vendor any of its code into an MIT/Apache-2.0 combined project. Reimplement clean-room.

## Status

Review and design complete (2026-04-30). Build phase to follow as a separate effort.
