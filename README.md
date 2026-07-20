# Apple Core

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

A personal macOS MCP (Model Context Protocol) server that exposes your local Apple data — Calendar, Reminders, Contacts, Mail, Notes, Messages, Maps, Weather, Location, Capture, Shortcuts, Safari tabs, Photos, iCloud Drive — to MCP clients like Claude Desktop, Claude Code, and Cursor.

**Status:** revived 2026-07-20 with a new architecture, building and serving. Apple Core began as a hard-fork of [`mattt/iMCP`](https://github.com/mattt/iMCP); it now runs those per-surface service implementations — plus new native Notes and Mail surfaces — behind the HTTP/SSE serving shell ported from [Bridgeport](https://github.com/oliverames/bridgeport) (Oliver's personal MCP gateway; private repo), replacing the original Bonjour/XPC transport entirely. The pivot is recorded in [`docs/planning/BUILD_PLAN.md` §0a](docs/planning/BUILD_PLAN.md); surface coverage, donor mapping, and the build sequence live in the rest of that document, with the seven-project synthesis review in [`docs/planning/SYNTHESIS.md`](docs/planning/SYNTHESIS.md).

This is currently a personal-use project, not a published product. There's no Mac App Store listing, no Sparkle appcast, no Homebrew cask. Treat the planning docs as source of truth for what's built vs. queued.

## Origin and license

Apple Core is licensed **GPL-3.0-or-later** (see [`LICENSE.md`](LICENSE.md) and [`NOTICE`](NOTICE)). It began as a hard-fork of `mattt/iMCP`; the original iMCP source files retain their MIT copyright headers (Copyright © 2025 Mattt), preserved at [`THIRD_PARTY_LICENSES/iMCP.LICENSE`](THIRD_PARTY_LICENSES/iMCP.LICENSE) — MIT-into-GPL is one-way compatible, and the combined work is GPL via composition. Patterns from six additional upstream projects (full map in [`docs/planning/DONORS.md`](docs/planning/DONORS.md)) inform the design; when their code is actually lifted into a surface implementation, attribution lands in `NOTICE` and `THIRD_PARTY_LICENSES/` per `BUILD_PLAN.md` §4.2. Code ported from Bridgeport and ping-warden is Oliver's own and needs no third-party attribution.

## Architecture

A single signed menu-bar app (`com.oliverames.applecore`) — no XPC, no required helper process. The app holds all TCC permissions under its own bundle identity, runs every Apple surface in-process (EventKit, Contacts.framework, MapKit, AppleScript/JXA via a shared hardened runner, direct SQLite reads), and serves MCP over HTTP/SSE via the shell ported from Bridgeport:

- **Local**: MCP clients connect to `http://127.0.0.1:8756/mcp` (Streamable HTTP + SSE) with a locally-generated bearer token (`~/.config/apple-core/config.json`). A thin bundled CLI (`Contents/MacOS/apple-core`) bridges stdio-only clients to the same endpoint.
- **Remote**: an optional Cloudflare Tunnel (managed in-app) exposes selected surfaces to cloud clients — Claude custom connectors, ChatGPT apps — behind OAuth 2.1 + PKCE.
- **Per-surface control**: each surface (Calendar, Notes, Mail, …) has an enable toggle and a separate local-only vs. publicly-exposed toggle, managed in a Bridgeport-style settings window (Dashboard / Services / Security / Cloudflare / Cloud Clients / Server panes).
- **Menu bar**: ping-warden-style `NSStatusItem` app with a `cable.connector` SF Symbol icon; per-client connection approval with a persistent trust list.
- **Daemon**: a LaunchAgent keeps the server available in the background.

Full architecture rationale, per-surface deep dives, and the build sequence are in [`docs/planning/BUILD_PLAN.md`](docs/planning/BUILD_PLAN.md).

## Surfaces

Inherited from iMCP and serving today: Calendar, Reminders, Contacts, Location, Maps, Messages-read, Weather (entitlement-gated), Capture, Shortcuts. New native implementations: **Notes** (8 tools — folders, list, search, get with content hash, create, append, update, delete — AppleScript/JXA, injection-safe by construction) and **Mail** (read-only first slice: accounts, mailboxes, messages, get, search; the full disk-first `.emlx`/FTS5 design from `apple-mail-mcp` is queued per `BUILD_PLAN.md` §3.1). Remaining v1 roadmap: `BUILD_PLAN.md` §5.2.

## Build

```bash
xcodebuild -project "Apple Core.xcodeproj" \
           -scheme "Apple Core" \
           -configuration Debug \
           build
```

Release mechanics are documented in [`RELEASING.md`](RELEASING.md); CI (lint, build, unit tests, Gitleaks) runs via GitHub Actions.

## Acknowledgments

Apple Core is built on the work of seven upstream MCP servers. Without them this project wouldn't exist. Full attribution is in [`docs/planning/DONORS.md`](docs/planning/DONORS.md), but in particular:

- [**mattt/iMCP**](https://github.com/mattt/iMCP) — the structural base. Reference architecture for sandboxed Apple-MCP, signed menu bar app pattern, JSON-LD outputs via `Ontology`, `madrid` typedstream decoder for Messages.
- [**imdinu/apple-mail-mcp**](https://github.com/imdinu/apple-mail-mcp) — the disk-first `.emlx` + FTS5 + state-reconciliation Mail design we'll translate to Swift in v2.0. GPL-3.0 (compatible after our relicense).
- [**FradSer/mcp-server-apple-events**](https://github.com/FradSer/mcp-server-apple-events) — richest EventKit surface; donor for Reminders / Calendar action shapes.
- [**adamzaidi/icloud-mcp**](https://github.com/adamzaidi/icloud-mcp) — IMAP/SMTP/CalDAV/CardDAV patterns, three-phase safe-move, doctor self-test, connect-rate-limiting gate.

---

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=for-the-badge&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

<p align="center">
  <sub>
    Built by <a href="https://ames.consulting">Oliver Ames</a> in Vermont
    &bull; <a href="https://github.com/oliverames">GitHub</a>
    &bull; <a href="https://linkedin.com/in/oliverames">LinkedIn</a>
    &bull; <a href="https://bsky.app/profile/oliverames.bsky.social">Bluesky</a>
  </sub>
</p>
