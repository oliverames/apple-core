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
| Public endpoint with authentication, all compiled surfaces exposed | **77 tools** |
| Claude Code | **Previously verified end to end**; the earlier run covered the then-current 59-tool surface |
| Codex CLI 0.144.6 | **Streamable HTTP + bearer configuration accepted**; direct live handshake enumerates 77 tools. Model-driven enumeration awaits post-disclosure confirmation before sending the inventory to an external model session. |

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
- Public: 77 tools with all 11 compiled services explicitly remote-enabled. The same endpoint returns 401 without authentication. Remote read-only Location and Maps calls pass using public test inputs.
- Read-only local calls pass for Calendar, Capture, Contacts, Location, Mail, Maps, Messages, Notes, Reminders, and Shortcuts. Utilities is remotely enumerated but has no read-only tool.
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

1. Run the model-driven Codex enumeration only after post-disclosure confirmation to share the live tool names, descriptions, and schemas with that external model session.
2. Apple-account write probes remain optional future coverage and require named disposable containers plus a fresh instruction permitting writes. The current verification was intentionally read-only.

The first release remains parked until Oliver explicitly says to cut it.
