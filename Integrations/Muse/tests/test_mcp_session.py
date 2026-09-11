"""Regression tests for session handling in _shared/bin/mcp.py.

Two defects are covered.

Session capture: Apple Core (and YNAB) issue an Mcp-Session-Id on initialize
and reject later calls that omit it. The client must capture the id from the
initialize response headers and resend it, and must add no header for servers
that issue none.

Session cleanup (issue #14): every session the client initializes must be
deleted with an HTTP DELETE, on the success path, on an error path, and at
interpreter exit, or the server's 64-session cap is exhausted. A session the
client did not create must never be deleted.

No network, no credentials: requests carry credential=None.
"""
import atexit
import io
import json
import importlib.util
from pathlib import Path
import types
import sys
import unittest
import urllib.error
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
# Record what the module registers for interpreter exit, and keep the test
# process itself free of the hook.
ATEXIT_REGISTERED: list = []
with mock.patch.dict(sys.modules, {"dynamic_credentials": credentials}):
    with mock.patch.object(sys, "path", list(sys.path)):
        with mock.patch.object(atexit, "register", ATEXIT_REGISTERED.append):
            spec.loader.exec_module(mcp_client)


class FakeResp:
    def __init__(self, body, headers=None, status=200):
        self._body = body.encode()
        self.headers = dict(headers or {})
        self.status = status

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


def reset_session():
    mcp_client._session_id = None
    mcp_client._session_key = None
    mcp_client._session_owned = False


class SessionIdTest(unittest.TestCase):
    def tearDown(self):
        reset_session()

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
            reset_session()
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


ENDPOINT = "https://mcp.example.invalid/mcp"


class FakeServer:
    """Records every request and answers initialize with a session id."""

    def __init__(self, session_id="sess-123", fail_on=None, delete_error=None):
        self.session_id = session_id
        self.fail_on = fail_on
        self.delete_error = delete_error
        self.requests = []

    def urlopen(self, req, timeout=60):
        method = req.get_method()
        headers = {k.lower(): v for k, v in req.header_items()}
        rpc = json.loads(req.data)["method"] if req.data else None
        self.requests.append(
            {"http": method, "rpc": rpc, "headers": headers, "url": req.full_url}
        )
        if method == "DELETE":
            if self.delete_error is not None:
                raise self.delete_error
            return FakeResp("", {}, status=202)
        if rpc == self.fail_on:
            raise urllib.error.HTTPError(
                req.full_url, 500, "boom", {}, io.BytesIO(b"")
            )
        if rpc == "initialize":
            headers_out = {"Mcp-Session-Id": self.session_id} if self.session_id else {}
            return FakeResp(sse({"jsonrpc": "2.0", "id": 0, "result": {}}), headers_out)
        return FakeResp(sse({"jsonrpc": "2.0", "id": 1, "result": {"ok": True}}), {})


class SessionCleanupTest(unittest.TestCase):
    """Issue #14: sessions the client opens must always be deleted."""

    def setUp(self):
        reset_session()

    def tearDown(self):
        reset_session()

    def run_main(self, server, argv=None):
        argv = argv or ["mcp.py", "--no-auth", "--endpoint", ENDPOINT, "tools/list"]
        with mock.patch.object(mcp_client.urllib.request, "urlopen", server.urlopen):
            with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                return mcp_client.main(argv)

    def deletes(self, server):
        return [r for r in server.requests if r["http"] == "DELETE"]

    def test_session_deleted_on_success_path(self):
        server = FakeServer()
        self.assertEqual(self.run_main(server), 0)
        deletes = self.deletes(server)
        self.assertEqual(len(deletes), 1)
        self.assertEqual(deletes[0]["headers"].get("mcp-session-id"), "sess-123")
        self.assertEqual(deletes[0]["url"], ENDPOINT)
        # Delete is last: it happens after the tool call, not before.
        self.assertEqual(server.requests[-1]["http"], "DELETE")

    def test_session_deleted_when_initialize_returns_rpc_error(self):
        server = FakeServer()

        def urlopen(req, timeout=60):
            if req.data and json.loads(req.data)["method"] == "initialize":
                server.requests.append({"http": "POST", "rpc": "initialize",
                                        "headers": {}, "url": req.full_url})
                return FakeResp(
                    sse({"jsonrpc": "2.0", "id": 0, "error": {"code": -32000}}),
                    {"Mcp-Session-Id": "sess-123"},
                )
            return server.urlopen(req, timeout)

        with mock.patch.object(mcp_client.urllib.request, "urlopen", urlopen):
            with mock.patch("sys.stdout"), mock.patch("sys.stderr"):
                rc = mcp_client.main(
                    ["mcp.py", "--no-auth", "--endpoint", ENDPOINT, "tools/list"]
                )
        self.assertEqual(rc, 1)
        self.assertEqual(len(self.deletes(server)), 1)

    def test_session_deleted_when_tool_call_raises(self):
        server = FakeServer(fail_on="tools/list")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.run_main(server)
        caught.exception.close()  # keeps the HTTPError body from warning on GC
        deletes = self.deletes(server)
        self.assertEqual(len(deletes), 1)
        self.assertEqual(deletes[0]["headers"].get("mcp-session-id"), "sess-123")

    def test_close_session_registered_for_interpreter_exit(self):
        # atexit covers paths main's finally cannot reach, such as an os-level
        # exit from an importing host or a caller that uses post() directly.
        self.assertIn(mcp_client.close_session, ATEXIT_REGISTERED)

    def test_atexit_delete_runs_when_main_is_not_used(self):
        server = FakeServer()
        with mock.patch.object(mcp_client.urllib.request, "urlopen", server.urlopen):
            with mock.patch("sys.stderr"):
                mcp_client.post(
                    None,
                    ENDPOINT,
                    {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}},
                )
                # Simulate interpreter exit running the registered hook.
                mcp_client.close_session()
        self.assertEqual(len(self.deletes(server)), 1)

    def test_unowned_session_is_never_deleted(self):
        # A server that hands out a session id on a call we did not initialize
        # does not make that session ours. Deleting it would break another
        # client's live connection.
        server = FakeServer()

        def urlopen(req, timeout=60):
            rpc = json.loads(req.data)["method"] if req.data else None
            server.requests.append({"http": req.get_method(), "rpc": rpc,
                                    "headers": {k.lower(): v for k, v in
                                                req.header_items()},
                                    "url": req.full_url})
            return FakeResp(
                sse({"jsonrpc": "2.0", "id": 1, "result": {}}),
                {"Mcp-Session-Id": "someone-elses"},
            )

        with mock.patch.object(mcp_client.urllib.request, "urlopen", urlopen):
            with mock.patch("sys.stderr"):
                mcp_client.post(
                    None,
                    ENDPOINT,
                    {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
                )
                self.assertEqual(mcp_client._session_id, "someone-elses")
                self.assertFalse(mcp_client._session_owned)
                self.assertFalse(mcp_client.close_session())
        self.assertEqual(self.deletes(server), [])

    def test_close_session_is_a_no_op_without_a_session(self):
        called = []
        with mock.patch.object(
            mcp_client.urllib.request, "urlopen", lambda *a, **k: called.append(1)
        ):
            self.assertFalse(mcp_client.close_session())
        self.assertEqual(called, [])

    def test_delete_failure_does_not_crash_the_caller(self):
        server = FakeServer(delete_error=urllib.error.URLError("offline"))
        # main still returns the tool result's exit code despite a failed delete.
        self.assertEqual(self.run_main(server), 0)
        self.assertEqual(len(self.deletes(server)), 1)
        # State is cleared, so the atexit hook does not retry.
        self.assertIsNone(mcp_client._session_id)
        self.assertFalse(mcp_client.close_session())
        self.assertEqual(len(self.deletes(server)), 1)

    def test_session_not_sent_to_a_different_endpoint(self):
        server = FakeServer()
        other = "https://other.example.invalid/mcp"
        with mock.patch.object(mcp_client.urllib.request, "urlopen", server.urlopen):
            with mock.patch("sys.stderr"):
                mcp_client.post(
                    None,
                    ENDPOINT,
                    {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}},
                )
                mcp_client.post(
                    None,
                    other,
                    {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}},
                )
        cross = [r for r in server.requests if r["url"] == other][0]
        self.assertNotIn("mcp-session-id", cross["headers"])

    def test_sse_framed_tool_call_is_unwrapped(self):
        # The server frames tools/call responses as SSE; a raw-HTTP client has
        # to read the data: lines rather than parsing the envelope as JSON.
        server = FakeServer()
        with mock.patch.object(mcp_client.urllib.request, "urlopen", server.urlopen):
            with mock.patch("sys.stderr"):
                mcp_client.post(
                    None,
                    ENDPOINT,
                    {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}},
                )
                result = mcp_client.post(
                    None,
                    ENDPOINT,
                    {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {}},
                )
                mcp_client.close_session()
        self.assertEqual(result, {"jsonrpc": "2.0", "id": 1, "result": {"ok": True}})

    def test_delete_is_not_sent_when_server_issues_no_session(self):
        server = FakeServer(session_id=None)
        self.assertEqual(self.run_main(server), 0)
        self.assertEqual(self.deletes(server), [])



if __name__ == "__main__":
    unittest.main()
