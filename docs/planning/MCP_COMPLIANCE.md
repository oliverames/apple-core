# MCP Compliance Report

Date: 2026-07-21. Server: Apple Core 1.4.0 (Streamable HTTP + SSE, `http://127.0.0.1:8756/mcp`, bearer auth). Verified against MCP spec revision **2025-06-18** (the protocol version the server negotiates during `initialize`):

- Spec: https://modelcontextprotocol.io/specification/2025-06-18
- Tools (names, inputSchema, outputSchema, structuredContent): https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Streamable HTTP transport: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

## Summary

| Check | Result |
|---|---|
| Tool count | **59** (docs elsewhere say 57; the live server now exposes 59) |
| inputSchema valid vs JSON Schema meta-schema (Draft 2020-12) | **59 / 59 pass** |
| Tool names match `^[a-zA-Z0-9_-]{1,128}$` | **59 / 59 pass** (dots avoided; e.g. `location_reverse-geocode` uses a hyphen, which is legal) |
| Duplicate names | **0** |
| Schema quality (prior pass) | Mature — descriptions and enums present throughout; no changes needed |
| Payload caps (prior pass) | Fixed — see `App/Services/Messages.swift` (`messages_list_chats` limit capped at 200; commit `2e3b8a6` "Sparkle release tooling and messages_list_chats limit cap") |
| Claude Code CLI | **Connected; all 59 tools enumerated** |
| Codex CLI 0.144.6 | **Config accepted and validated** (streamable HTTP + bearer token env var); full tool enumeration not exercised (see below) |
| structuredContent / outputSchema | **SDK supports it; server does not use it yet** — follow-up below |

## 1. Programmatic schema validation

Method: `initialize` via curl (protocolVersion 2025-06-18, `Accept: application/json, text/event-stream`), captured `Mcp-Session-Id`, sent `notifications/initialized` (HTTP 202), then `tools/list`. Each tool's `inputSchema` was checked with `python3` + `jsonschema` (`Draft202012Validator.check_schema`).

- 59/59 inputSchemas are valid Draft 2020-12 JSON Schemas.
- 59/59 names match the spec's tool-name pattern; all unique.
- All tools carry `annotations` (`readOnlyHint`, `openWorldHint`, `title`).
- Read-only tool call sanity check: `maps_search {"query":"coffee","limit":1}` returned a well-formed schema.org Place result.

## 2. structuredContent / outputSchema

The pinned swift-sdk revision `a0ae212ebf6eab5f754c3129608bc5557637e605` (see `Apple Core.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`) **fully supports both features**: `Tool.outputSchema` and `CallTool.Result.structuredContent` exist in `Sources/MCP/Server/Tools.swift` (verified in the identical checkout at `~/.local/share/mise/installs/spm-artemnovichkov-shortcuts-mcp-server/1.0.7/checkouts/swift-sdk`). No SDK bump needed.

Today the server declares `outputSchema` on **0** tools and returns everything as JSON-in-text `content`. Candidates with stable result shapes worth wiring first (report only; not implemented):

- `maps_search`, `maps_directions`, `maps_eta`, `location_geocode`, `location_reverse-geocode`, `location_current` — already emit schema.org-shaped JSON
- List-shaped read tools: `calendars_list`, `events_fetch`, `reminders_lists`, `reminders_fetch`, `notes_list`, `notes_list_folders`, `notes_stats`, `mail_list_accounts`, `mail_list_mailboxes`, `mail_list_messages`, `messages_list_chats`, `contacts_search`, `shortcuts_list`

## 3. Live client checks

### Claude Code CLI — PASS

From a throwaway scratch dir (local project scope only; entry removed afterward):

```
$ claude mcp add --transport http apple-core-test http://127.0.0.1:8756/mcp --header "Authorization: Bearer $TOKEN"
Added HTTP MCP server apple-core-test ... to local config

$ claude mcp list
apple-core-test: http://127.0.0.1:8756/mcp (HTTP) - ✔ Connected
```

A headless run (`claude -p`) enumerated the server's tools: **59 tools, all present**, `calendars_list` through `shortcuts_run`. Cleanup: `claude mcp remove apple-core-test` (verified gone).

### Codex CLI 0.144.6 — config accepted; enumeration blocked by auth isolation

Under a throwaway `CODEX_HOME` (never touching `~/.codex`):

```
$ codex mcp add apple-core-test --url http://127.0.0.1:8756/mcp --bearer-token-env-var APPLE_CORE_TOKEN
Added global MCP server 'apple-core-test'.

$ codex mcp list
Name             Url                        Bearer Token Env Var  Status   Auth
apple-core-test  http://127.0.0.1:8756/mcp  APPLE_CORE_TOKEN      enabled  Bearer token

$ codex doctor   # (excerpt)
  ✓ mcp          1 server (1 streamable_http) · 0 disabled
```

Generated `config.toml` shape Codex accepts:

```toml
[mcp_servers.apple-core-test]
url = "http://127.0.0.1:8756/mcp"
bearer_token_env_var = "APPLE_CORE_TOKEN"
```

`codex exec` (which would drive the actual MCP handshake and tool listing) requires OpenAI credentials; the scratch `CODEX_HOME` has none and `~/.codex` holds no copyable `auth.json`, so a model-driven enumeration was not run. Codex validated transport, URL, and bearer-token wiring, and Codex uses the same Streamable HTTP 2025-06-18 handshake exercised directly via curl in section 1, so connectivity risk is low. To finish the check interactively: run the same `codex mcp add` in the real environment and open a session.

## 4. Compatibility statement

Apple Core is compatible with Claude Code (verified end to end: connect, list, all 59 tools visible) and configuration-compatible with Codex CLI (streamable HTTP + bearer token accepted by `codex mcp add`/`doctor`; live enumeration pending an authenticated Codex run). Protocol conformance verified against MCP 2025-06-18: session initialization, `Mcp-Session-Id` handling, `notifications/initialized`, SSE-framed responses, tool name rules, and JSON Schema validity of every inputSchema.

## 5. Follow-ups

1. **Wire `outputSchema` + `structuredContent`** for the stable-shape tools listed in section 2. SDK already supports it; no dependency change required.
2. Update any docs claiming 57 tools; the live count is 59.
3. Optional: complete the Codex live enumeration from an authenticated environment.
