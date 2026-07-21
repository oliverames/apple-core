#!/usr/bin/env python3
"""Opt-in runtime integration checks for Apple Core's live MCP server.

Read-only enumeration is always safe. Write tests require an explicit safety
acknowledgement and named disposable Apple containers. Every created object is
deleted in a best-effort cleanup block.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any


SAFETY_ACK = "I_AM_USING_DISPOSABLE_ACCOUNTS"


class MCPClient:
    def __init__(self, url: str, token: str) -> None:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}:
            raise ValueError("Integration tests only run against a loopback HTTP endpoint")
        self.url = url
        self.token = token
        self.session_id: str | None = None
        self.next_id = 1

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        request_id = self.next_id
        self.next_id += 1
        payload = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        body, headers = self._post(payload)
        self.session_id = headers.get("Mcp-Session-Id") or self.session_id
        data_lines = [line[6:] for line in body.splitlines() if line.startswith("data: ")]
        if not data_lines:
            raise RuntimeError(f"No SSE response for {method}")
        response = json.loads(data_lines[-1])
        if "error" in response:
            raise RuntimeError(f"{method}: {response['error']}")
        return response["result"]

    def notify(self, method: str, params: dict[str, Any]) -> None:
        payload = {"jsonrpc": "2.0", "method": method, "params": params}
        _, headers = self._post(payload)
        self.session_id = headers.get("Mcp-Session-Id") or self.session_id

    def call(self, name: str, arguments: dict[str, Any]) -> Any:
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            text = next(
                (item.get("text", "") for item in result.get("content", []) if item.get("type") == "text"),
                "unknown tool error",
            )
            raise RuntimeError(f"{name}: {text}")
        if "structuredContent" not in result:
            raise RuntimeError(f"{name}: response is missing structuredContent")
        return result["structuredContent"]["result"]

    def _post(self, payload: dict[str, Any]) -> tuple[str, Any]:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "User-Agent": "apple-core-integration-test/1.0",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=90) as response:
            return response.read().decode(), response.headers


def load_token() -> str:
    if token := os.environ.get("APPLE_CORE_TOKEN"):
        return token
    config_path = Path.home() / ".config/apple-core/config.json"
    config = json.loads(config_path.read_text())
    token = config.get("token")
    if not token:
        raise RuntimeError(f"No bearer token found in {config_path}")
    return token


def find_identifier(value: Any) -> str:
    if isinstance(value, dict):
        for key in ("id", "identifier"):
            identifier = value.get(key)
            if isinstance(identifier, str) and identifier:
                return identifier
        for child in value.values():
            try:
                return find_identifier(child)
            except RuntimeError:
                pass
    if isinstance(value, list):
        for child in value:
            try:
                return find_identifier(child)
            except RuntimeError:
                pass
    raise RuntimeError(f"No id or identifier in result: {value!r}")


def verify_enumeration(client: MCPClient) -> None:
    initialized = client.request(
        "initialize",
        {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "apple-core-integration-test", "version": "1.0"},
        },
    )
    client.notify("notifications/initialized", {})
    tools = client.request("tools/list", {})["tools"]
    names = [tool["name"] for tool in tools]
    if len(tools) != 77 or len(set(names)) != 77:
        raise RuntimeError(f"Expected 77 unique tools, got {len(tools)} tools and {len(set(names))} names")
    missing_output_schema = [tool["name"] for tool in tools if "outputSchema" not in tool]
    if missing_output_schema:
        raise RuntimeError(f"Tools missing outputSchema: {missing_output_schema}")
    print(
        f"PASS enumeration: {len(tools)} unique tools, {len(tools) - len(missing_output_schema)} output schemas, "
        f"server {initialized['serverInfo']['version']}"
    )


def test_mail_templates(client: MCPClient, suffix: str) -> None:
    name = f"Apple Core Integration {suffix}"
    try:
        client.call("mail_save_template", {"name": name, "subject": "Integration {{name}}", "body": "Hello {{name}}"})
        template = client.call("mail_get_template", {"name": name})
        if template.get("subject") != "Integration {{name}}":
            raise RuntimeError("Saved mail template did not round-trip")
        print("PASS mail template create/read")
    finally:
        try:
            client.call("mail_delete_template", {"name": name})
            print("PASS mail template cleanup")
        except RuntimeError as error:
            print(f"WARN mail template cleanup: {error}", file=sys.stderr)


def test_calendar(client: MCPClient, calendar: str, suffix: str) -> None:
    event_id: str | None = None
    start = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30)).replace(microsecond=0)
    end = start + dt.timedelta(minutes=30)
    try:
        created = client.call(
            "events_create",
            {
                "title": f"Apple Core Integration {suffix}",
                "start": start.isoformat().replace("+00:00", "Z"),
                "end": end.isoformat().replace("+00:00", "Z"),
                "calendar": calendar,
                "notes": "Disposable Apple Core integration fixture",
            },
        )
        event_id = find_identifier(created)
        client.call("events_update", {"id": event_id, "title": f"Apple Core Integration Updated {suffix}"})
        print("PASS Calendar create/update")
    finally:
        if event_id:
            try:
                client.call("events_delete", {"id": event_id})
                print("PASS Calendar cleanup")
            except RuntimeError as error:
                print(f"WARN Calendar cleanup: {error}", file=sys.stderr)


def test_reminders(client: MCPClient, reminder_list: str, suffix: str) -> None:
    reminder_id: str | None = None
    try:
        created = client.call(
            "reminders_create",
            {
                "title": f"Apple Core Integration {suffix}",
                "list": reminder_list,
                "notes": "Disposable Apple Core integration fixture",
            },
        )
        reminder_id = find_identifier(created)
        client.call("reminders_update", {"id": reminder_id, "title": f"Apple Core Integration Updated {suffix}"})
        client.call("reminders_complete", {"id": reminder_id, "completed": True})
        print("PASS Reminders create/update/complete")
    finally:
        if reminder_id:
            try:
                client.call("reminders_delete", {"id": reminder_id})
                print("PASS Reminders cleanup")
            except RuntimeError as error:
                print(f"WARN Reminders cleanup: {error}", file=sys.stderr)


def test_notes(client: MCPClient, account: str, suffix: str) -> None:
    source_folder = f"Apple Core Integration A {suffix}"
    destination_folder = f"Apple Core Integration B {suffix}"
    note_id: str | None = None
    created_folders: list[str] = []
    try:
        client.call("notes_create_folder", {"name": source_folder, "account": account})
        created_folders.append(source_folder)
        client.call("notes_create_folder", {"name": destination_folder, "account": account})
        created_folders.append(destination_folder)
        created = client.call(
            "notes_create",
            {"title": f"Apple Core Integration {suffix}", "body": "Created", "folder": source_folder},
        )
        note_id = find_identifier(created)
        client.call("notes_append", {"id": note_id, "text": "Appended"})
        client.call(
            "notes_update",
            {"id": note_id, "title": f"Apple Core Integration Updated {suffix}", "body": "Updated"},
        )
        client.call("notes_move", {"id": note_id, "folder": destination_folder, "account": account})
        print("PASS Notes folder/create/append/update/move")
    finally:
        if note_id:
            try:
                client.call("notes_delete", {"id": note_id})
                print("PASS Notes note cleanup")
            except RuntimeError as error:
                print(f"WARN Notes note cleanup: {error}", file=sys.stderr)
        for folder in reversed(created_folders):
            try:
                client.call("notes_delete_folder", {"name": folder, "account": account})
            except RuntimeError as error:
                print(f"WARN Notes folder cleanup ({folder}): {error}", file=sys.stderr)
        if created_folders:
            print("PASS Notes folder cleanup")


def test_mailbox(client: MCPClient, account: str, suffix: str) -> None:
    original = f"Apple Core Integration {suffix}"
    renamed = f"Apple Core Integration Renamed {suffix}"
    active_name: str | None = None
    try:
        client.call("mail_create_mailbox", {"account": account, "name": original})
        active_name = original
        client.call("mail_rename_mailbox", {"account": account, "name": original, "new_name": renamed})
        active_name = renamed
        print("PASS Mail mailbox create/rename")
    finally:
        if active_name:
            try:
                client.call("mail_delete_mailbox", {"account": account, "name": active_name})
                print("PASS Mail mailbox cleanup")
            except RuntimeError as error:
                print(f"WARN Mail mailbox cleanup: {error}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8756/mcp")
    parser.add_argument("--writes", action="store_true", help="Run opted-in write and cleanup checks")
    args = parser.parse_args()

    client = MCPClient(args.url, load_token())
    verify_enumeration(client)
    if not args.writes:
        return 0

    if os.environ.get("APPLE_CORE_INTEGRATION_ACK") != SAFETY_ACK:
        raise RuntimeError(f"Set APPLE_CORE_INTEGRATION_ACK={SAFETY_ACK} before running write tests")

    suffix = uuid.uuid4().hex[:8]
    test_mail_templates(client, suffix)

    configured = 0
    if calendar := os.environ.get("APPLE_CORE_TEST_CALENDAR"):
        configured += 1
        test_calendar(client, calendar, suffix)
    if reminder_list := os.environ.get("APPLE_CORE_TEST_REMINDER_LIST"):
        configured += 1
        test_reminders(client, reminder_list, suffix)
    if notes_account := os.environ.get("APPLE_CORE_TEST_NOTES_ACCOUNT"):
        configured += 1
        test_notes(client, notes_account, suffix)
    if mail_account := os.environ.get("APPLE_CORE_TEST_MAIL_ACCOUNT"):
        configured += 1
        test_mailbox(client, mail_account, suffix)

    if configured == 0:
        print("PASS local template writes; no disposable Apple containers were configured")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
