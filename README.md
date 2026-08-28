# Apple Core

<p align="center">
  <a href="https://www.buymeacoffee.com/oliverames">
    <img src="https://img.shields.io/badge/Buy_Me_a_Coffee-support-f5a542?style=flat-square&logo=buy-me-a-coffee&logoColor=white" alt="Buy Me a Coffee">
  </a>
</p>

A personal macOS MCP (Model Context Protocol) server that exposes local Apple services, including Calendar, Reminders, Contacts, Mail, Notes, Messages, Maps, Location, Capture, and Shortcuts, to MCP clients such as Claude Desktop, Claude Code, and Cursor.

**Status:** Apple Core 1.0 is the first public release. The app serves MCP locally and through an optional authenticated Cloudflare Tunnel, with 122 tools in the standard build. Apple Core began as a hard-fork of [`mattt/iMCP`](https://github.com/mattt/iMCP); it now runs those per-surface implementations plus expanded Notes and Mail surfaces behind the HTTP/SSE serving shell ported from [Bridgeport](https://github.com/oliverames/bridgeport), replacing the original Bonjour transport. The architecture pivot is recorded in [`docs/planning/BUILD_PLAN.md` §0a](docs/planning/BUILD_PLAN.md).

Download the signed and notarized app from [GitHub Releases](https://github.com/oliverames/apple-core/releases/latest). Each installation creates its own bearer token and stores its configuration and OAuth state under that Mac user's `~/.config/apple-core/` folder. The release does not contain Oliver's token, Cloudflare tunnel credentials, OAuth clients, Apple account data, or service permissions. Remote access starts off; until you turn it on, Apple Core is reachable only from this Mac.

## Origin and license

Apple Core is licensed **GPL-3.0-or-later** (see [`LICENSE.md`](LICENSE.md) and [`NOTICE`](NOTICE)). It began as a hard-fork of `mattt/iMCP`; iMCP's MIT license is preserved at [`THIRD_PARTY_LICENSES/iMCP.LICENSE`](THIRD_PARTY_LICENSES/iMCP.LICENSE). The license copies and attribution for additional donor designs used by the implementation are in [`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES) and [`NOTICE`](NOTICE). Code ported from Bridgeport and ping-warden is Oliver's own.

## Architecture

A single menu-bar app (`com.oliverames.applecore`) runs every Apple surface in-process and serves MCP over HTTP/SSE. A bundled CLI is retained only for stdio-only MCP clients:

- **Local**: MCP clients connect to `http://127.0.0.1:8756/mcp` (Streamable HTTP + SSE) with a locally-generated bearer token (`~/.config/apple-core/config.json`). A thin bundled CLI (`Contents/MacOS/apple-core`) bridges stdio-only clients to the same endpoint.
- **Remote**: an optional Cloudflare Tunnel (managed in-app) exposes selected surfaces to cloud clients such as Claude custom connectors and ChatGPT apps, behind bearer authentication or OAuth 2.1 + PKCE.
- **Connector branding**: the HTTP server exposes the Apple Core app icon at `/favicon.ico` (a real single-entry ICO container, not a renamed PNG), explicit PNG favicon sizes from 16 through 256 pixels, `/apple-touch-icon.png`, and a versioned `/assets/apple-core-icon-v1.png`. The public landing page advertises the ICO plus the 16 and 32 pixel PNGs, because icon resolvers take the first usable declaration and listing every size put a 256x256 PNG ahead of anything cheap; all sizes stay served. These routes are unauthenticated and unconditional, so pointing your own Cloudflare Tunnel at the app vends the Apple Core logo from your own domain with no extra configuration.
- **Per-surface control**: each surface (Calendar, Notes, Mail, …) has one enable switch. A surface you enable is reachable wherever Apple Core is currently served, and remote requests always authenticate — access is never anonymous. Managed in a three-pane settings window (Services / Access / Clients), with server internals and repair actions behind a Diagnostics sheet.
- **Menu bar**: an AppKit `NSStatusItem` app with per-client connection approval and a persistent trust list. The canonical app icon is reproducibly rendered in Swift by `Scripts/generate_app_icon.swift` from the same connection symbol used in the menu bar.
- **Daemon**: a LaunchAgent keeps the server available in the background.

Full architecture rationale, per-surface deep dives, and the build sequence are in [`docs/planning/BUILD_PLAN.md`](docs/planning/BUILD_PLAN.md).

## Surfaces

The standard build exposes 122 tools: Notes (32), Mail (28), Contacts (12), Filesystem (10), Reminders (7), Calendar (6), Utilities (6), Maps (5), Messages (5), Capture (4), Shortcuts (4), and Location (3). Surfaces start off except Maps and Utilities, so a fresh install advertises 11 tools until you enable more during onboarding or in Settings. The ten Filesystem tools additionally stay hidden until you share a folder, and six WeatherKit tools are excluded from every current build because their `WEATHERKIT_AVAILABLE` compilation condition is never set.

Four Notes tools read the local Notes database rather than going through AppleScript, because Notes exposes no other route to them: `notes_get_link`, `notes_get_metadata`, `notes_get_checklist_state`, and `notes_get_sync_status`. They need Full Disk Access and report clearly when they do not have it; every other Notes tool works without it. Run `notes_doctor` to see which applies. Five tools that put a window on screen — the `notes_show_*` family and `notes_selected` — refuse on a Mac with no active desktop session, since a headless bridge has nobody to show anything to.

The Filesystem surface reports itself inactive and exposes nothing until you share a folder with it in Settings, so a fresh install has no filesystem access at all.

## macOS permissions

Enabling a service from the menu bar or Settings requests the access that service needs. Apple Core temporarily becomes a regular foreground app before it calls macOS, because Tahoe can refuse a background permission request without displaying a prompt.

| Service | Access requested when enabled |
| --- | --- |
| Calendar | Calendar full access |
| Capture | Camera, Microphone, and Screen Recording |
| Contacts | Contacts |
| Location | Location Services |
| Mail | Automation for Mail |
| Maps | Location Services |
| Messages | Automation for Messages, followed by the `chat.db` picker when direct database access is unavailable |
| Notes | Automation for Notes |
| Reminders | Reminders full access |
| Shortcuts | No macOS privacy grant required |
| Utilities | No macOS privacy grant required |

If you deny a request, Apple Core turns that service back off. You can change the decision later in System Settings > Privacy & Security and try again.

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
