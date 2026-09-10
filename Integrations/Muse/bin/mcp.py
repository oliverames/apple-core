#!/usr/bin/env python3
"""Generic MCP (Streamable HTTP) client for Muse connector skills.

Usage:
    mcp.py --credential custom.linear --endpoint https://mcp.linear.app/mcp tools/list
    mcp.py --credential custom.linear --endpoint https://mcp.linear.app/mcp tools/call '{"name":"<tool>","arguments":{...}}'
    mcp.py --credential custom.linear --endpoint https://mcp.linear.app/mcp raw '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}'
    mcp.py --no-auth --endpoint https://pubmed.mcp.claude.com/mcp tools/list

Runs initialize first, then the requested call. Prints the JSON-RPC
result to stdout. Auth comes from the named stored credential via the
dynamic-credential surrogate exchange; the host is derived from the
endpoint and enforced as the only allowed egress host. Pass --no-auth
for public endpoints that need no credential.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, "/opt/hatch/skills/skill-creator/bin")
from dynamic_credentials import (
    add_surrogate_to_request,
    read_response_body,
)

PROTOCOL_VERSION = "2025-06-18"

# Some servers (Apple Core, YNAB) issue an Mcp-Session-Id on initialize and
# require it on every later call; without it they 400. Capture it once and
# resend it. Servers that don't use sessions ignore the header.
_session_id: str | None = None


def post(credential: str | None, endpoint: str, payload: dict) -> dict:
    global _session_id
    host = (urllib.parse.urlparse(endpoint).hostname or "").lower()
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(endpoint, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    req.add_header("MCP-Protocol-Version", PROTOCOL_VERSION)
    req.add_header("User-Agent", "muse-mcp-client/1")
    if _session_id is not None:
        req.add_header("Mcp-Session-Id", _session_id)
    if credential is not None:
        add_surrogate_to_request(
            req, credential, entry_name="access_token", allowed_hosts=[host]
        )
    with urllib.request.urlopen(req, timeout=60) as resp:
        sid = resp.headers.get("Mcp-Session-Id")
        if sid:
            _session_id = sid
        raw = read_response_body(resp).decode("utf-8")
    # Streamable HTTP may return SSE; unwrap data: lines if present.
    if raw.startswith("event:") or "\ndata:" in raw:
        chunks = []
        for line in raw.splitlines():
            if line.startswith("data:"):
                text = line[5:].strip()
                if text and text != "[DONE]":
                    chunks.append(text)
        raw = chunks[-1] if chunks else "{}"
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {"_raw": raw[:2000]}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--credential", default=None)
    parser.add_argument("--no-auth", action="store_true")
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("action", choices=["tools/list", "tools/call", "raw"])
    parser.add_argument("payload", nargs="?", default="{}")
    args = parser.parse_args(argv[1:])
    if args.no_auth == (args.credential is not None):
        parser.error("pass exactly one of --credential <name> or --no-auth")
    credential = None if args.no_auth else args.credential

    init = post(
        credential,
        args.endpoint,
        {
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "muse-mcp-client", "version": "1"},
            },
        },
    )
    if "error" in init:
        print(json.dumps({"initialize_error": init}, indent=2))
        return 1

    if args.action == "tools/list":
        result = post(
            credential,
            args.endpoint,
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
        )
    elif args.action == "tools/call":
        params = json.loads(args.payload)
        result = post(
            credential,
            args.endpoint,
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params},
        )
    else:
        result = post(credential, args.endpoint, json.loads(args.payload))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
