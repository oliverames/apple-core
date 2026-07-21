# MCP Compliance Report

Date: 2026-07-21. Installed server: Apple Core 1.0.0 (Streamable HTTP + SSE, bearer authentication). Verified against MCP revision **2025-06-18**, which the server negotiates during `initialize`:

- Specification: https://modelcontextprotocol.io/specification/2025-06-18
- Tools: https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- Streamable HTTP: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports

## Current result

| Check | Result |
|---|---|
| Local tool count | **77** |
| Unique tool names | **77 / 77** |
| `outputSchema` declarations | **77 / 77** |
| Successful calls with `structuredContent` | **Pass**; legacy text/image/audio `content` is preserved |
| Protocol negotiation | **2025-06-18** |
| Server identity | **Apple Core 1.0.0** |
| Public endpoint without authentication | **401** |
| Public endpoint with authentication, no surfaces exposed | **0 tools** (default deny) |
| Claude Code | **Previously verified end to end**; the earlier run covered the then-current 59-tool surface |
| Codex CLI 0.144.6 | **Streamable HTTP + bearer configuration accepted**; direct live handshake enumerates 77 tools. Model-driven enumeration awaits explicit approval to disclose the tool inventory to an external model session. |

The source defines 81 tools. Four WeatherKit tools are excluded from the current Release build because `WEATHERKIT_AVAILABLE` is not set, leaving 77 runtime tools.

## Verification method

The live installed app at `/Applications/Apple Core.app` was exercised over `http://127.0.0.1:8756/mcp`:

1. Send `initialize` with protocol 2025-06-18 and a trusted test client name.
2. Capture `Mcp-Session-Id` and send `notifications/initialized`.
3. Send `tools/list` and verify count, uniqueness, and `outputSchema` presence.
4. Call read-only service tools and require a successful `structuredContent.result` alongside legacy `content`.
5. Repeat the authenticated handshake through `https://applecore.amesvt.com/mcp`.

Results:

- Local: 77 tools, 77 unique names, 77 output schemas.
- Public: zero tools while `serviceSettings` is absent, confirming that remote access fails closed until individual surfaces are explicitly exposed.
- Read-only live calls pass for Mail, Notes, Messages, Shortcuts, Maps, Reminders, and Contacts. Calendar still requires the user-controlled macOS Privacy & Security toggle.
- The opt-in harness at `Scripts/integration_test.py` passes enumeration and the reversible local Mail template create/read/delete path. Apple-account mutations remain gated behind an exact acknowledgement plus named disposable Calendar, Reminders, Notes, or Mail containers.

## Output contract

Every declared MCP tool now has the same conservative output schema:

```json
{
  "type": "object",
  "properties": {
    "result": {}
  },
  "required": ["result"],
  "additionalProperties": false
}
```

Successful tool calls populate `structuredContent.result` with the native encoded value. Existing clients continue to receive the prior text, image, or audio content. Error results remain MCP errors and do not claim conformance to the successful output schema.

## Remote policy

Remote classification fails closed. A request is remote when its host is not loopback or when `X-Forwarded-For` or `CF-Connecting-IP` is present, even if a reverse proxy rewrites `Host` to `127.0.0.1`. A session records its access surface at creation and rejects later requests that attempt to change it.

Local visibility requires the service toggle. Remote visibility requires both the local service toggle and that service's explicit **Remote** toggle. Bearer or OAuth authentication remains mandatory in either case.

## Remaining external gates

1. Enable Apple Core in macOS Privacy & Security > Calendars, then rerun the read-only Calendar probe.
2. Supply named disposable Apple containers and run `APPLE_CORE_INTEGRATION_ACK=I_AM_USING_DISPOSABLE_ACCOUNTS Scripts/integration_test.py --writes` for Calendar, Reminders, Notes, and Mail mailbox CRUD.
3. Install a valid Developer ID Application identity and configure a `notarytool` keychain profile before archive, export, notarization, and Gatekeeper validation.
4. Run the model-driven Codex enumeration only after explicit approval to share the live tool names and schemas with that external model session.

The first release remains parked until Oliver explicitly says to cut it.
