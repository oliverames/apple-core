"""Regression test: Mcp-Session-Id capture and resend in _shared/bin/mcp.py.

Apple Core (and YNAB) issue an Mcp-Session-Id on initialize and reject later
calls that omit it. This test stubs the transport and asserts the client
captures the id from the initialize response headers and resends it, and
that servers without sessions see no header change.

No network, no credentials: requests carry credential=None.
"""
import json
import importlib.util
from pathlib import Path
import types
import sys
import unittest
from unittest import mock

# Muse provides this module at runtime. Keep local tests credential-free.
credentials = types.ModuleType("dynamic_credentials")
credentials.add_surrogate_to_request = mock.Mock(
    side_effect=AssertionError("Tests must not request credentials")
)
credentials.read_response_body = lambda response: response.read()
spec = importlib.util.spec_from_file_location(
    "muse_mcp_client", Path(__file__).resolve().parents[1] / "bin" / "mcp.py"
)
mcp_client = importlib.util.module_from_spec(spec)
with mock.patch.dict(sys.modules, {"dynamic_credentials": credentials}):
    with mock.patch.object(sys, "path", list(sys.path)):
        spec.loader.exec_module(mcp_client)


class FakeResp:
    def __init__(self, body, headers=None):
        self._body = body.encode()
        self.headers = dict(headers or {})

    def read(self, size=-1):
        if size is None or size < 0:
            chunk, self._body = self._body, b""
        else:
            chunk, self._body = self._body[:size], self._body[size:]
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def sse(payload):
    return "event: message\ndata: " + json.dumps(payload) + "\n\n"


class SessionIdTest(unittest.TestCase):
    def tearDown(self):
        mcp_client._session_id = None

    def run_calls(self, init_headers):
        seen = []

        def fake_urlopen(req, timeout=60):
            seen.append({k.lower(): v for k, v in req.header_items()})
            if json.loads(req.data)["method"] == "initialize":
                body = sse({"jsonrpc": "2.0", "id": 0, "result": {}})
                return FakeResp(body, init_headers)
            body = sse({"jsonrpc": "2.0", "id": 1, "result": {}})
            return FakeResp(body, {})

        with mock.patch.object(mcp_client.urllib.request, "urlopen", fake_urlopen):
            mcp_client._session_id = None
            mcp_client.post(
                None,
                "https://mcp.example.invalid/mcp",
                {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}},
            )
            mcp_client.post(
                None,
                "https://mcp.example.invalid/mcp",
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
            )
        return seen

    def test_session_id_captured_and_resent(self):
        seen = self.run_calls({"Mcp-Session-Id": "sess-123"})
        self.assertNotIn("mcp-session-id", seen[0])
        self.assertEqual(seen[1].get("mcp-session-id"), "sess-123")

    def test_no_session_header_when_server_omits_it(self):
        seen = self.run_calls({})
        self.assertNotIn("mcp-session-id", seen[1])


if __name__ == "__main__":
    unittest.main()
