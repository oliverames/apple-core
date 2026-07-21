# Apple Core

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

A personal macOS MCP (Model Context Protocol) server that exposes local Apple services, including Calendar, Reminders, Contacts, Mail, Notes, Messages, Maps, Location, Capture, and Shortcuts, to MCP clients such as Claude Desktop, Claude Code, and Cursor.

**Status:** release preparation. The app builds, serves MCP locally and through an optional authenticated Cloudflare Tunnel, and has 77 tools in the standard build. Apple Core began as a hard-fork of [`mattt/iMCP`](https://github.com/mattt/iMCP); it now runs those per-surface implementations plus expanded Notes and Mail surfaces behind the HTTP/SSE serving shell ported from [Bridgeport](https://github.com/oliverames/bridgeport), replacing the original Bonjour transport. The architecture pivot is recorded in [`docs/planning/BUILD_PLAN.md` §0a](docs/planning/BUILD_PLAN.md).

No public release has been cut yet. The repository and signed Sparkle appcast infrastructure exist, but the first Developer ID signed and notarized build remains deliberately unpublished.

## Origin and license

Apple Core is licensed **GPL-3.0-or-later** (see [`LICENSE.md`](LICENSE.md) and [`NOTICE`](NOTICE)). It began as a hard-fork of `mattt/iMCP`; iMCP's MIT license is preserved at [`THIRD_PARTY_LICENSES/iMCP.LICENSE`](THIRD_PARTY_LICENSES/iMCP.LICENSE). The license copies and attribution for additional donor designs used by the implementation are in [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES) and [`NOTICE`](NOTICE). Code ported from Bridgeport and ping-warden is Oliver's own.

## Architecture

A single menu-bar app (`com.oliverames.applecore`) runs every Apple surface in-process and serves MCP over HTTP/SSE. A bundled CLI is retained only for stdio-only MCP clients:

- **Local**: MCP clients connect to `http://127.0.0.1:8756/mcp` (Streamable HTTP + SSE) with a locally-generated bearer token (`~/.config/apple-core/config.json`). A thin bundled CLI (`Contents/MacOS/apple-core`) bridges stdio-only clients to the same endpoint.
- **Remote**: an optional Cloudflare Tunnel (managed in-app) exposes selected surfaces to cloud clients such as Claude custom connectors and ChatGPT apps, behind bearer authentication or OAuth 2.1 + PKCE.
- **Per-surface control**: each surface (Calendar, Notes, Mail, …) has an enable toggle and a separate Remote Access toggle (local-only by default; remote access always requires authentication — it is never anonymous), managed in a Bridgeport-style settings window (Dashboard / Services / Security / Cloudflare / Cloud Clients / Server panes).
- **Menu bar**: an AppKit `NSStatusItem` app with per-client connection approval and a persistent trust list. The canonical app icon is reproducibly rendered in Swift by `Scripts/generate_app_icon.swift` from the same connection symbol used in the menu bar.
- **Daemon**: a LaunchAgent keeps the server available in the background.

Full architecture rationale, per-surface deep dives, and the build sequence are in [`docs/planning/BUILD_PLAN.md`](docs/planning/BUILD_PLAN.md).

## Surfaces

The standard build exposes 77 tools: Calendar (5), Reminders (6), Contacts (4), Location (3), Maps (5), Messages (3), Capture (3), Shortcuts (2), Notes (19), Mail (26), and Utilities (1). Four WeatherKit tools remain entitlement-gated and are not part of the standard release build.

## Build

```bash
xcodebuild -project "Apple Core.xcodeproj" \
           -scheme "Apple Core" \
           -configuration Debug \
           build
```

Release mechanics are documented in [`RELEASING.md`](RELEASING.md); CI (lint, build, unit tests, Gitleaks) runs via GitHub Actions.

The opt-in runtime harness is [`Scripts/integration_test.py`](Scripts/integration_test.py). Its default mode performs read-only authenticated enumeration. Apple-account writes require named disposable containers and the explicit safety acknowledgement documented in [`RELEASING.md`](RELEASING.md).

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
