# Apple Core

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

A personal macOS MCP (Model Context Protocol) server that exposes your local Apple data — Calendar, Reminders, Contacts, Mail, Notes, Messages, Maps, Weather, Location, Capture, Shortcuts, Safari tabs, Photos, iCloud Drive — to MCP clients like Claude Desktop, Claude Code, and Cursor.

**Status:** active hard-fork of [`mattt/iMCP`](https://github.com/mattt/iMCP) being adapted into a single combined Apple-services MCP. The architecture, surface coverage, donor mapping, and build sequence are documented in [`docs/planning/BUILD_PLAN.md`](docs/planning/BUILD_PLAN.md). The synthesis review of the seven upstream MCP servers we drew from lives in [`docs/planning/SYNTHESIS.md`](docs/planning/SYNTHESIS.md).

This is currently a personal-use project, not a published product. There's no Mac App Store listing, no Sparkle appcast, no Homebrew cask. Build instructions are at the bottom of this file once the v0 surface set lands; until then, treat the planning docs as source of truth.

## Origin and license

Apple Core is a hard-fork of `mattt/iMCP` with patterns being incorporated from six additional upstream projects (full list in [`docs/planning/DONORS.md`](docs/planning/DONORS.md)). The original iMCP source files retain their MIT copyright headers (Copyright © 2025 Mattt). New files authored for Apple Core will carry GPL-3.0-or-later headers in a queued relicensing pass — Apple Core itself is being relicensed to GPL-3.0-or-later to match the most-permissively-incompatible donor (`apple-mail-mcp`, GPL-3.0). MIT-into-GPL is one-way compatible, so this is legal; the combined work becomes GPL via composition.

See [`LICENSE.md`](LICENSE.md) (currently iMCP's MIT — kept verbatim until relicense lands) and the upstream attribution in `docs/planning/DONORS.md` for the full picture.

## Architecture

`.app` + CLI proxy via `NSXPCConnection` over a Mach service named `com.oliverames.applecore.xpc`. The .app is a long-lived menu bar host that holds TCC permissions under its own signed bundle identity (`com.oliverames.applecore`); the bundled CLI (`Apple Core.app/Contents/MacOS/apple-core`) is a stdio shim that MCP clients launch and that proxies tool calls to the .app over XPC.

Full architecture rationale, per-surface deep dives, and the build sequence are in [`docs/planning/BUILD_PLAN.md`](docs/planning/BUILD_PLAN.md).

## Build (work in progress)

```bash
xcodebuild -project "Apple Core.xcodeproj" \
           -scheme "Apple Core" \
           -configuration Debug \
           build
```

The renamed iMCP shell currently builds clean. Surface implementations beyond what iMCP already provides (Calendar, Reminders, Contacts, Location, Maps, Messages-read, Weather, Capture, Shortcuts) are queued. The full v1.0 / v1.1 / v1.2 / v2.0 / v2.1 / v3.0 sequence is at `docs/planning/BUILD_PLAN.md` §5.2.

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
