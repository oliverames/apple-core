# Muse MCP client

Apple Core owns this Muse integration helper at Oliver Ames's direction. It is
source tooling, separate from the Mac application and hosted OAuth server.

`bin/mcp.py` was retrieved from Muse's live `_shared/bin/mcp.py` on September 10,
2026. It preserves the working session-header fix: capture `Mcp-Session-Id`
from the response and resend it on subsequent requests in the same process.
The credential handling matches the retrieved file.

## Session lifecycle

Servers that issue a session on `initialize` cap how many can be open at once.
Apple Core allows 64 and reaps idle sessions only after 600 seconds, so a
wrapper that initializes and exits without closing its session leaves it held
for the full idle window. Repeated invocations then exhaust the cap and
`initialize` starts returning HTTP 503 `Too many active sessions`, which is what
the September 10 acceptance sweep hit ([issue #14][issue14]).

This client sends an HTTP DELETE for the session it opened, from `main`'s
`finally` block on the success path, the initialize-error path, and an
exception path, and again from an `atexit` hook for callers that import the
module and use `post` directly. `close_session` clears its state before it
sends, so the delete is never retried or repeated.

Only sessions this process created are deleted. The id is marked owned solely
when it arrives on this process's own `initialize` response, and it is tracked
with the endpoint and credential it was issued for, so it is neither resent nor
deleted for another server. A session id a server volunteers on some other
response is used for later calls but never deleted: that session may belong to
another client's live connection.

A DELETE that fails is logged to stderr and otherwise ignored. Cleanup must not
turn a successful tool call into a failure.

`initialize` runs once per process and the session is reused for the call that
follows, so the session is not created per call within a process. Sessions are
not shared across processes, because Muse starts a fresh process per invocation
and a persisted session id would be unsafe to reuse blind. Cleanup at exit, not
cross-process reuse, is the fix for the leak.

Streamable HTTP responses may be SSE framed (`event:` / `data:` lines). This
client is a raw-HTTP client, so `post` unwraps the last `data:` line before
parsing JSON. That applies to `tools/call` responses, which Apple Core frames
as SSE.

[issue14]: https://github.com/oliverames/apple-core/issues/14

## Runtime and scope

Run with Python 3.10 or later inside Muse. Muse supplies `dynamic_credentials`
at `/opt/hatch/skills/skill-creator/bin`. That platform module is intentionally
not copied into this repository. It supplies the credential-surrogate exchange
and response reader. Even `--no-auth` currently requires that module to import.

Use a fresh process for each invocation, as Muse's connector wrappers do. The
module-global session is for one endpoint and credential per process. This is
not a reusable multi-server SDK. Session expiry recovery and broader protocol
features are outside this preserved fix.

## Verify

From this directory:

```sh
python3 -m py_compile bin/mcp.py
python3 -m unittest tests.test_mcp_session -v
```

The tests stub network transport and the Muse platform module. They verify
session capture and resend, a server that omits the session header, deletion on
the success, initialize-error, and exception paths, the `atexit` registration,
that an unowned session is never deleted, that a failed delete does not fail the
caller and is not retried, that a session is not sent to another endpoint, and
that an SSE-framed `tools/call` response is unwrapped. No network or stored
credentials are used. CI runs these tests on changes to the repository.

## Install in Muse

Use a checkout of a reviewed Apple Core commit on the Muse VM. Compare this file
with `~/workspace/skills/_shared/bin/mcp.py` first and reconcile any newer local
changes. From the checkout, after review:

```sh
install -m 755 Integrations/Muse/bin/mcp.py "$HOME/workspace/skills/_shared/bin/mcp.py"
```

This copies only the Python client. Leave connector definitions, credentials,
platform modules, and individual skill wrappers intact. The `_shared` directory
is not part of the ames-plugins mirror, so a marketplace update does not install
this helper. Distribution is through this source repository, without a Mac app
version bump or binary release.

For live acceptance, use the existing Apple Core wrapper in a fresh process to
list tools and run `notes_health_check`. Do not print credentials or read note
bodies. Earlier live acceptance and installed Mac build evidence are recorded in
[the OAuth report](../../docs/oauth-connection-id-2026-09-10.md).
